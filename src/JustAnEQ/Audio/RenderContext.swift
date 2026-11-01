import CoreAudio
import Foundation
import JustAnEQCore
import JustAnEQRT

/// Mutable RT state has one writer, accessed through an owned pointer rather
/// than class stored-property inout access (no dynamic exclusivity checks).
private struct RenderState {
    var ramp = GainRamp(gain: 0)
    var equalizer: EQState
    let fadeFrames: Int
    var fadingOut = false

    init(sampleRate: Double) {
        equalizer = EQState(sampleRate: sampleRate)
        fadeFrames = max(2, Int(sampleRate * 0.01))
        ramp.setTarget(1, frames: fadeFrames)
    }

    mutating func render(_ layout: IOLayout, _ input: UnsafePointer<AudioBufferList>,
                         _ output: UnsafeMutablePointer<AudioBufferList>, control: OpaquePointer) {
        if ignoreStartupEmptyBuffer(isEmpty: layout.hasEmptyTapBuffer(input),
                                    startedAt: eq_started_at(control), now: DispatchTime.now().uptimeNanoseconds) {
            let outputs = UnsafeMutableAudioBufferListPointer(output)
            for buffer in outputs {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }
        if eq_stop_requested(control), !fadingOut {
            fadingOut = true
            ramp.setTarget(0, frames: fadeFrames)
        }
        var settings = EQSettings()
        settings.balance = eq_get_parameter(control, 0)
        settings.boostDB = eq_get_parameter(control, 1)
        for index in 0..<10 { settings.bandDB[index] = eq_get_parameter(control, Int32(index + 2)) }
        for index in 0..<4 { settings.mixerDB[index] = eq_get_parameter(control, Int32(index + 12)) }
        settings.mode = eq_get_parameter(control, 16) > 0.5 ? .mixer : .graphic
        if !layout.copy(input, output, ramp: &ramp, settings: settings, state: &equalizer) {
            eq_mark_fault(control)
        }
        if fadingOut, ramp.isComplete { eq_mark_silent(control) }
    }
}

/// Value-only render handle. The IOProc retains its owning RenderContext for
/// lifetime safety, including a failed IOProc destruction; rendering accesses
/// immutable pointers and single-writer struct state.
struct RenderHandle: @unchecked Sendable {
    let control: OpaquePointer
    fileprivate let state: UnsafeMutablePointer<RenderState>

    func render(_ layout: IOLayout, _ input: UnsafePointer<AudioBufferList>,
                _ output: UnsafeMutablePointer<AudioBufferList>) {
        state.pointee.render(layout, input, output, control: control)
    }
}

final class RenderContext: @unchecked Sendable {
    let handle: RenderHandle
    var control: OpaquePointer { handle.control }

    init(sampleRate: Double) throws {
        guard let control = eq_control_create() else { throw CocoaError(.fileReadUnknown) }
        let state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        state.initialize(to: RenderState(sampleRate: sampleRate))
        handle = RenderHandle(control: control, state: state)
    }

    func markStarted(at nanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        eq_set_started_at(control, nanoseconds)
    }

    func update(_ settings: EQSettings) {
        eq_set_parameter(control, 0, settings.balance)
        eq_set_parameter(control, 1, settings.boostDB)
        for index in 0..<10 { eq_set_parameter(control, Int32(index + 2), settings.bandDB[index]) }
        for index in 0..<4 { eq_set_parameter(control, Int32(index + 12), settings.mixerDB[index]) }
        eq_set_parameter(control, 16, settings.mode == .mixer ? 1 : 0)
    }

    /// Main thread only; bounded by 20 ms plus OS scheduling.
    @discardableResult
    func waitForFade() -> Bool {
        eq_request_stop(control)
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000
        while !eq_is_silent(control), DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.0005)
        }
        return eq_is_silent(control)
    }

    deinit {
        handle.state.deinitialize(count: 1)
        handle.state.deallocate()
        eq_control_destroy(control)
    }
}
