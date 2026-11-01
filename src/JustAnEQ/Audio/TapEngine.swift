import CoreAudio
import Foundation
import JustAnEQCore
import JustAnEQRT
import os

private let audioLog = Logger(subsystem: "cloud.hey-hi.just-an-eq", category: "audio")

private struct AudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? { "\(operation) failed (OSStatus \(status))." }
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioFailure(operation: operation, status: status) }
}

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) throws {
    var property = address(selector, scope: scope)
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &value) {
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0), "Read \(selector)")
    }
}

/// Owned by the menu controller; all lifecycle calls run on the main thread.
/// Initialization deliberately performs no Core Audio calls or permission requests.
final class TapEngine: @unchecked Sendable {
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var aggregate: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?

    private var context: RenderContext?
    private var running = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var faultMonitor: DispatchSourceTimer?
    var onOutputChange: (@MainActor () -> Void)?
    var settings = EQSettings() {
        didSet { context?.update(settings) }
    }

    func start() throws {
        guard tap == kAudioObjectUnknown else { return }
        guard #available(macOS 14.2, *) else {
            throw AudioFailure(operation: "Process taps require macOS 14.2", status: kAudioHardwareUnsupportedOperationError)
        }
        do {
            var output = AudioDeviceID(kAudioObjectUnknown)
            try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &output)
            guard output != kAudioObjectUnknown else {
                throw AudioFailure(operation: "Find default output", status: kAudioHardwareBadDeviceError)
            }
            var outputUID: CFString = "" as CFString
            try read(output, kAudioDevicePropertyDeviceUID, into: &outputUID)

            var pid = getpid()
            var ownProcess = AudioObjectID(kAudioObjectUnknown)
            var property = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess),
                      "Find own audio process")
            guard ownProcess != kAudioObjectUnknown else {
                throw AudioFailure(operation: "Find own audio process", status: kAudioHardwareBadObjectError)
            }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            description.name = "JustAnEQ passthrough"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tap), "Create process tap")

            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "JustAnEQ passthrough",
                kAudioAggregateDeviceUIDKey: "cloud.hey-hi.just-an-eq.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Create aggregate")
            let initial = try configuration()
            guard initial.outputID == output, initial.isAlive else {
                throw AudioFailure(operation: "Output changed during setup", status: kAudioHardwareBadDeviceError)
            }
            let layout = try IOLayout(device: aggregate)
            let context = try RenderContext(sampleRate: layout.sampleRate)
            context.update(settings)
            self.context = context
            try installListeners(initial: initial, context: context)
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, output, _ in
                context.handle.render(layout, input, output)
            }, "Create IOProc")
            try check(AudioDeviceStart(aggregate, ioProc), "Start aggregate")
            context.markStarted()
            running = true
            audioLog.info("Engine On")
        } catch {
            stop()
            throw error
        }
    }

    private func configuration() throws -> AudioConfiguration {
        var output = AudioDeviceID(kAudioObjectUnknown)
        var sampleRate = Double(0)
        var alive = UInt32(0)
        try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &output)
        try read(aggregate, kAudioDevicePropertyNominalSampleRate, into: &sampleRate)
        try read(aggregate, kAudioDevicePropertyDeviceIsAlive, into: &alive)
        func snapshot(_ format: AudioStreamBasicDescription) -> StreamFormat {
            StreamFormat(sampleRate: format.mSampleRate, channels: format.mChannelsPerFrame,
                         formatID: format.mFormatID, flags: format.mFormatFlags,
                         bytesPerPacket: format.mBytesPerPacket, framesPerPacket: format.mFramesPerPacket,
                         bytesPerFrame: format.mBytesPerFrame, bitsPerChannel: format.mBitsPerChannel)
        }
        return try AudioConfiguration(outputID: output, nominalSampleRate: sampleRate,
            inputs: IOLayout.formats(aggregate, scope: kAudioObjectPropertyScopeInput).map(snapshot),
            outputs: IOLayout.formats(aggregate, scope: kAudioObjectPropertyScopeOutput).map(snapshot),
            isAlive: alive != 0)
    }

    private func installListeners(initial: AudioConfiguration, context: RenderContext) throws {
        // Listener callbacks only enqueue work. Removing registrations happens
        // after the callback returns, including notifications from the main queue.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.context === context else { return }
                do {
                    guard try self.configuration().requiresStop(comparedTo: initial) else { return }
                } catch { /* Unknown configuration must stop safely and visibly. */ }
                self.stop()
                self.onOutputChange?()
            }
        }
        let registrations: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice)),
            (aggregate, address(kAudioDevicePropertyNominalSampleRate)),
            (aggregate, address(kAudioDevicePropertyDeviceIsAlive)),
            (aggregate, address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)),
            (aggregate, address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput))
        ]
        for (object, property) in registrations {
            var property = property
            try check(AudioObjectAddPropertyListenerBlock(object, &property, .main, listener), "Watch audio configuration")
            listeners.append((object, property, listener))
        }
        // A malformed callback buffer must also stop visibly if no HAL property
        // notification arrives. RT only sets an atomic bit; this main-queue timer
        // performs teardown without allocating or dispatching from the callback.
        let monitor = DispatchSource.makeTimerSource(queue: .main)
        monitor.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        monitor.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.context === context, eq_has_fault(context.control) else { return }
                self.stop()
                self.onOutputChange?()
            }
        }
        faultMonitor = monitor
        monitor.resume()
        guard try !configuration().requiresStop(comparedTo: initial) else {
            throw AudioFailure(operation: "Default output changed during start", status: kAudioHardwareBadDeviceError)
        }
    }

    func stop() {
        faultMonitor?.cancel()
        faultMonitor = nil
        for (object, property, listener) in listeners {
            var property = property
            report(AudioObjectRemovePropertyListenerBlock(object, &property, .main, listener), "Remove audio watcher")
        }
        listeners.removeAll()
        if running, let context, !eq_has_fault(context.control), !context.waitForFade() {
            audioLog.warning("Fade wait reached 20 ms; tearing down inactive or slow callback")
        }
        running = false
        if let ioProc {
            report(AudioDeviceStop(aggregate, ioProc), "Stop aggregate")
            report(AudioDeviceDestroyIOProcID(aggregate, ioProc), "Destroy IOProc")
            self.ioProc = nil
        }
        context = nil
        if aggregate != kAudioObjectUnknown {
            report(AudioHardwareDestroyAggregateDevice(aggregate), "Destroy aggregate")
            aggregate = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                report(AudioHardwareDestroyProcessTap(tap), "Destroy process tap")
            }
            tap = kAudioObjectUnknown
        }
    }

    private func report(_ status: OSStatus, _ operation: String) {
        if status != noErr { audioLog.error("\(operation): OSStatus \(status)") }
    }

    deinit { stop() }
}

/// Immutable callback configuration. No engine capture, locks, logging or heap
/// buffers on the audio thread. Physical input streams precede the appended tap.
struct IOLayout: Sendable {
    let sampleRate: Double
    let inputOffset: Int
    let inputPlanar: Bool
    let outputPlanar: Bool
    /// One output channel (Bluetooth headset mode); both channels are downmixed.
    let outputMono: Bool

    init(sampleRate: Double, inputOffset: Int = 0, inputPlanar: Bool = false, outputPlanar: Bool = false,
         outputMono: Bool = false) {
        self.sampleRate = sampleRate
        self.inputOffset = inputOffset
        self.inputPlanar = inputPlanar
        self.outputPlanar = outputPlanar
        self.outputMono = outputMono
    }

    init(device: AudioDeviceID) throws {
        let inputs = try Self.formats(device, scope: kAudioObjectPropertyScopeInput)
        let outputs = try Self.formats(device, scope: kAudioObjectPropertyScopeOutput)
        guard let input = inputs.last, let output = outputs.first,
              Self.isStereoFloat(input), Self.isStereoFloat(output) || Self.isMonoFloat(output),
              // The tap reports the system mix rate (often 48 kHz) even when the
              // output runs at 44.1 kHz; drift compensation clocks it to the
              // device. A real frame-count mismatch still faults in `copy`.
              output.mSampleRate.isFinite, output.mSampleRate > 0 else {
            func describe(_ f: AudioStreamBasicDescription) -> String {
                "\(Int(f.mSampleRate))Hz/\(f.mChannelsPerFrame)ch/\(f.mBitsPerChannel)bit/flags \(f.mFormatFlags)"
            }
            let found = "in [\(inputs.map(describe).joined(separator: ", "))] out [\(outputs.map(describe).joined(separator: ", "))]"
            audioLog.error("Unsupported aggregate format: \(found, privacy: .public)")
            throw AudioFailure(operation: "Require matching stereo Float32 streams (\(found))",
                               status: kAudioDeviceUnsupportedFormatError)
        }
        sampleRate = output.mSampleRate
        inputOffset = inputs.dropLast().reduce(0) { $0 + (Self.isPlanar($1) ? Int($1.mChannelsPerFrame) : 1) }
        inputPlanar = Self.isPlanar(input)
        outputMono = output.mChannelsPerFrame == 1
        outputPlanar = !outputMono && Self.isPlanar(output)
    }

    fileprivate static func formats(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> [AudioStreamBasicDescription] {
        var property = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Read stream count")
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        try streams.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!), "Read streams")
        }
        return try streams.map { stream in
            var format = AudioStreamBasicDescription()
            try read(stream, kAudioStreamPropertyVirtualFormat, into: &format)
            return format
        }
    }

    private static func isPlanar(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    }

    private static func isStereoFloat(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mChannelsPerFrame == 2 &&
        format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
        format.mBytesPerFrame == (isPlanar(format) ? 4 : 8)
    }

    private static func isMonoFloat(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mChannelsPerFrame == 1 &&
        format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && format.mBytesPerFrame == 4
    }

    func hasEmptyTapBuffer(_ inputList: UnsafePointer<AudioBufferList>) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        if buffers.count == 0 { return true }
        guard buffers.count > inputOffset else { return false }
        return (inputOffset..<buffers.count).allSatisfy { buffers[$0].mDataByteSize == 0 }
    }

    func copy(_ inputList: UnsafePointer<AudioBufferList>, _ outputList: UnsafeMutablePointer<AudioBufferList>,
              ramp: inout GainRamp, settings: EQSettings, state: inout EQState) -> Bool {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        // Zero unused channels. A mismatch returns false and triggers a visible stop.
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let inputCount = inputPlanar ? 2 : 1
        let outputCount = outputPlanar ? 2 : 1
        guard inputs.count == inputOffset + inputCount, outputs.count >= outputCount else { return false }
        let leftIn = inputs[inputOffset]
        let rightIn = inputs[inputOffset + (inputPlanar ? 1 : 0)]
        if outputMono {
            return copyDownmix(leftIn, rightIn, outputs[0], ramp: &ramp, settings: settings, state: &state)
        }
        let leftOut = outputs[0]
        let rightOut = outputs[outputPlanar ? 1 : 0]
        guard leftIn.mNumberChannels == (inputPlanar ? 1 : 2),
              rightIn.mNumberChannels == (inputPlanar ? 1 : 2),
              leftOut.mNumberChannels == (outputPlanar ? 1 : 2),
              rightOut.mNumberChannels == (outputPlanar ? 1 : 2),
              let inL = leftIn.mData?.assumingMemoryBound(to: Float.self),
              let inR = rightIn.mData?.assumingMemoryBound(to: Float.self),
              let outL = leftOut.mData?.assumingMemoryBound(to: Float.self),
              let outR = rightOut.mData?.assumingMemoryBound(to: Float.self) else { return false }
        let inStride = inputPlanar ? 1 : 2
        let outStride = outputPlanar ? 1 : 2
        let frames = Int(leftIn.mDataByteSize) / (4 * inStride)
        guard frames == Int(rightIn.mDataByteSize) / (4 * inStride),
              frames == Int(leftOut.mDataByteSize) / (4 * outStride),
              frames == Int(rightOut.mDataByteSize) / (4 * outStride) else { return false }
        guard frames > 0,
              Int(leftIn.mDataByteSize) % (4 * inStride) == 0,
              Int(rightIn.mDataByteSize) % (4 * inStride) == 0,
              Int(leftOut.mDataByteSize) % (4 * outStride) == 0,
              Int(rightOut.mDataByteSize) % (4 * outStride) == 0 else { return false }
        processStereo(inL, inR.advanced(by: inputPlanar ? 0 : 1),
                      outL, outR.advanced(by: outputPlanar ? 0 : 1),
                      frames: frames, inputStride: inStride, outputStride: outStride,
                      ramp: &ramp, settings: settings, state: &state)
        return true
    }

    private func copyDownmix(_ leftIn: AudioBuffer, _ rightIn: AudioBuffer, _ out: AudioBuffer,
                             ramp: inout GainRamp, settings: EQSettings, state: inout EQState) -> Bool {
        let inStride = inputPlanar ? 1 : 2
        guard leftIn.mNumberChannels == (inputPlanar ? 1 : 2),
              rightIn.mNumberChannels == (inputPlanar ? 1 : 2),
              out.mNumberChannels == 1,
              let inL = leftIn.mData?.assumingMemoryBound(to: Float.self),
              let inR = rightIn.mData?.assumingMemoryBound(to: Float.self),
              let outM = out.mData?.assumingMemoryBound(to: Float.self) else { return false }
        let frames = Int(leftIn.mDataByteSize) / (4 * inStride)
        guard frames > 0,
              frames == Int(rightIn.mDataByteSize) / (4 * inStride),
              frames == Int(out.mDataByteSize) / 4,
              Int(leftIn.mDataByteSize) % (4 * inStride) == 0,
              Int(rightIn.mDataByteSize) % (4 * inStride) == 0,
              Int(out.mDataByteSize) % 4 == 0 else { return false }
        processDownmix(inL, inR.advanced(by: inputPlanar ? 0 : 1), outM,
                       frames: frames, inputStride: inStride,
                       ramp: &ramp, settings: settings, state: &state)
        return true
    }
}
