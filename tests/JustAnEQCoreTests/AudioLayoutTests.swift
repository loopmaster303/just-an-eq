import CoreAudio
import JustAnEQCore
import JustAnEQRT
import Testing
@testable import JustAnEQ

@Test func malformedBuffersSignalFaultInsteadOfStayingSilentlyMuted() throws {
    // No HAL calls or device activation: synthetic AudioBufferLists only.
    for fault in 0..<4 {
        let context = try RenderContext(sampleRate: 48000)
        let layout = IOLayout(sampleRate: 48000)
        var inputSamples: [Float] = [0.1, -0.1, 0.2, -0.2]
        var outputSamples = [Float](repeating: 42, count: 4)
        inputSamples.withUnsafeMutableBytes { source in
            outputSamples.withUnsafeMutableBytes { destination in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: fault == 0 ? 1 : 2,
                    mDataByteSize: fault == 1 ? 15 : 16,
                    mData: fault == 2 ? nil : source.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: fault == 3 ? 8 : 16, mData: destination.baseAddress))
                context.handle.render(layout, &input, &output)
            }
        }
        #expect(eq_has_fault(context.control))
        #expect(outputSamples.allSatisfy { $0 == 0 || $0 == 42 })
    }
}

@Test func validBuffersRenderAndFadeAcknowledgesWithoutHAL() throws {
    let context = try RenderContext(sampleRate: 48000)
    let layout = IOLayout(sampleRate: 48000)
    var inputSamples = [Float](repeating: 0.1, count: 960)
    var outputSamples = [Float](repeating: 42, count: 960)
    inputSamples.withUnsafeMutableBytes { source in
        outputSamples.withUnsafeMutableBytes { destination in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: 3840, mData: source.baseAddress))
            var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: 3840, mData: destination.baseAddress))
            context.handle.render(layout, &input, &output)
            #expect(!eq_has_fault(context.control))
            #expect(destination.bindMemory(to: Float.self).last == 0.1)
            eq_request_stop(context.control)
            context.handle.render(layout, &input, &output)
            #expect(eq_is_silent(context.control))
            #expect(destination.bindMemory(to: Float.self).last == 0)
        }
    }
}

@Test func emptyStartupBufferDoesNotFaultButExpiredEmptyBufferDoes() throws {
    let context = try RenderContext(sampleRate: 48000)
    let layout = IOLayout(sampleRate: 48000)
    var input = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
    var output = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
    context.markStarted()
    context.handle.render(layout, &input, &output)
    #expect(!eq_has_fault(context.control))
    // An injected old timestamp avoids sleeping or any HAL lifecycle call.
    context.markStarted(at: 1)
    context.handle.render(layout, &input, &output)
    #expect(eq_has_fault(context.control))
}

@Test func monoOutputReceivesDownmixInsteadOfFault() throws {
    // Bluetooth in headset mode exposes a single output channel.
    let context = try RenderContext(sampleRate: 16000)
    let layout = IOLayout(sampleRate: 16000, outputMono: true)
    var inputSamples = [Float](repeating: 0, count: 640)
    for frame in 0..<320 { inputSamples[frame * 2] = 0.2; inputSamples[frame * 2 + 1] = 0.1 }
    var outputSamples = [Float](repeating: 42, count: 320)
    inputSamples.withUnsafeMutableBytes { source in
        outputSamples.withUnsafeMutableBytes { destination in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: 2560, mData: source.baseAddress))
            var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 1280, mData: destination.baseAddress))
            context.handle.render(layout, &input, &output)
        }
    }
    #expect(!eq_has_fault(context.control))
    #expect(abs(outputSamples.last! - 0.15) < 0.0001)
}

@Test func mixerModeReachesTheRenderThreadThroughControl() throws {
    // 12 kHz tone through HF kill must come out far quieter than flat.
    func rms(_ settings: EQSettings) throws -> Float {
        let context = try RenderContext(sampleRate: 48000)
        context.update(settings)
        let layout = IOLayout(sampleRate: 48000)
        var input = (0..<9600).flatMap { frame -> [Float] in
            let sample = Float(0.1 * sin(2 * Double.pi * 12000 * Double(frame) / 48000))
            return [sample, sample]
        }
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeMutableBytes { source in
            output.withUnsafeMutableBytes { destination in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(source.count), mData: source.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(destination.count), mData: destination.baseAddress))
                context.handle.render(layout, &inList, &outList)
            }
        }
        let tail = output.suffix(9600)
        return sqrt(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))
    }
    var killed = EQSettings()
    killed.mode = .mixer
    killed.mixerDB[3] = -26
    let quiet = try rms(killed)
    let flat = try rms(EQSettings())
    #expect(quiet < flat * 0.1)
}
