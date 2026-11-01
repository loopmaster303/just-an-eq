import Foundation
import Testing
import JustAnEQCore

private func render(_ input: [Float], ramp: inout GainRamp) -> [Float] {
    var output = [Float](repeating: 0, count: input.count)
    var state = EQState(sampleRate: 48000)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            process(source.baseAddress!, destination.baseAddress!, frames: input.count / 2, ramp: &ramp, settings: EQSettings(), state: &state)
        }
    }
    return output
}

@Test func rampIsMonotonicAndReachesUnityAcrossBlocks() {
    var ramp = GainRamp(gain: 0)
    ramp.setTarget(1, frames: 480)
    let a = render([Float](repeating: 0.5, count: 254), ramp: &ramp)
    let b = render([Float](repeating: 0.5, count: 706), ramp: &ramp)
    let samples = a + b
    #expect(samples.first == 0)
    #expect(samples.last == 0.5)
    #expect(ramp.gain == 1)
    #expect(ramp.isComplete)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(stride(from: 0, to: samples.count, by: 2).allSatisfy { samples[$0] == samples[$0 + 1] })
    #expect(render([0.5, 0.5], ramp: &ramp) == [0.5, 0.5])
}

@Test func sineOnOffHasNoStepAboveThreshold() {
    // 100 Hz, amplitude 0.8; phase deliberately starts near the peak.
    // The ordinary adjacent-sample delta is <0.011; allow 0.014 including ramp.
    for rate in [44100.0, 48000.0, 96000.0] {
        let count = Int(rate * 0.01)
        let input = (0..<(count * 3)).flatMap { frame -> [Float] in
            let value = Float(0.8 * cos(2 * .pi * 100 * Double(frame) / rate))
            return [value, value]
        }
        var ramp = GainRamp(gain: 0)
        ramp.setTarget(1, frames: count)
        var samples = render(Array(input[..<(count * 2)]), ramp: &ramp)
        samples += render(Array(input[(count * 2)..<(count * 4)]), ramp: &ramp)
        ramp.setTarget(0, frames: count)
        samples += render(Array(input[(count * 4)...]), ramp: &ramp)
        let left = [Float(0)] + stride(from: 0, to: samples.count, by: 2).map { samples[$0] } + [0]
        let maximumStep = zip(left, left.dropFirst()).map { abs($1 - $0) }.max()!
        #expect(maximumStep < 0.014)
        #expect(samples.last == 0)
        #expect(ramp.isComplete)
    }
}

@Test func interruptedRampAndZeroFramesAreSafe() {
    var ramp = GainRamp(gain: 0)
    ramp.setTarget(1, frames: 480)
    _ = render([Float](repeating: 1, count: 100), ramp: &ramp)
    let before = ramp.gain
    ramp.setTarget(0, frames: 480)
    var value: Float = 9
    var destination: Float = 42
    var state = EQState(sampleRate: 48000)
    process(&value, &destination, frames: 0, ramp: &ramp, settings: EQSettings(), state: &state)
    #expect(destination == 42)
    #expect(ramp.gain == before)
    let tail = render([Float](repeating: 1, count: 1000), ramp: &ramp)
    #expect(tail.first == before)
    #expect(tail.last == 0)
    #expect(zip(tail, tail.dropFirst()).allSatisfy { $0 >= $1 })
}
