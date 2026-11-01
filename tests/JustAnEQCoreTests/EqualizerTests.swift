import Foundation
import Testing
import JustAnEQCore

func renderTone(frequency: Double, settings: EQSettings, rate: Double = 48000) -> (Double, Double) {
    let frames = Int(rate / 4)
    let input = (0..<frames).flatMap { frame -> [Float] in
        let sample = Float(0.1 * sin(2 * .pi * frequency * Double(frame) / rate))
        return [sample, sample]
    }
    var output = [Float](repeating: 0, count: input.count)
    var state = EQState(sampleRate: rate)
    var ramp = GainRamp(gain: 1)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            process(source.baseAddress!, destination.baseAddress!, frames: frames,
                    ramp: &ramp, settings: settings, state: &state)
        }
    }
    var left = 0.0, right = 0.0
    for frame in (frames / 2)..<frames {
        left += Double(output[frame * 2] * output[frame * 2])
        right += Double(output[frame * 2 + 1] * output[frame * 2 + 1])
    }
    return (sqrt(left / Double(frames / 2)), sqrt(right / Double(frames / 2)))
}

@Test func balanceAttenuatesOppositeChannelAndBoostIsDecibels() {
    let flat = renderTone(frequency: 1000, settings: EQSettings())
    var settings = EQSettings()
    settings.balance = 1
    settings.boostDB = 6
    let right = renderTone(frequency: 1000, settings: settings)
    #expect(right.0 == 0)
    #expect(abs(right.1 / flat.1 - pow(10, 6.0 / 20)) < 0.001)
    settings.balance = -1
    let left = renderTone(frequency: 1000, settings: settings)
    #expect(left.1 == 0)
    #expect(abs(left.0 - right.1) < 0.0001)
}

@Test func eachEQBandHasItsRequestedCenterGain() {
    for index in 0..<10 {
        var settings = EQSettings()
        settings.bandDB[index] = 6
        let frequency = EQSettings.frequency(index)
        let flat = renderTone(frequency: frequency, settings: EQSettings())
        let boosted = renderTone(frequency: frequency, settings: settings)
        #expect(abs(20 * log10(boosted.0 / flat.0) - 6) < 0.1)
        #expect(abs(boosted.0 - boosted.1) < 0.0001)
        settings.bandDB[index] = -6
        let cut = renderTone(frequency: frequency, settings: settings)
        #expect(abs(20 * log10(cut.0 / flat.0) + 6) < 0.1)
    }
}

@Test func flatDSPPreservesSamplesAndBounds() {
    let input: [Float] = [0.125, -0.25, 0.5, -0.75]
    var output: [Float] = [42, 42, 42, 42, 42, 42]
    var ramp = GainRamp(gain: 1)
    var state = EQState(sampleRate: 48000)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            process(source.baseAddress!, destination.baseAddress!.advanced(by: 1), frames: 2,
                    ramp: &ramp, settings: EQSettings(), state: &state)
        }
    }
    #expect(Array(output[1...4]) == input)
    #expect(output.first == 42 && output.last == 42)
}

@Test func planarAndInterleavedDSPMatchAcrossUnevenBlocks() {
    let frames = 1024
    let left = (0..<frames).map { Float(sin(Double($0) * 0.07) * 0.1) }
    let right = (0..<frames).map { Float(cos(Double($0) * 0.13) * 0.2) }
    let stereo = (0..<frames).flatMap { [left[$0], right[$0]] }
    var interleaved = [Float](repeating: 42, count: frames * 2 + 2)
    var planarL = [Float](repeating: 42, count: frames + 2)
    var planarR = planarL
    var settings = EQSettings()
    settings.balance = 0.2
    settings.boostDB = 3
    settings.bandDB = EQPreset.bassFocus.bands
    var stateA = EQState(sampleRate: 48000), stateB = EQState(sampleRate: 48000)
    var rampA = GainRamp(gain: 0), rampB = GainRamp(gain: 0)
    rampA.setTarget(1, frames: 480)
    rampB.setTarget(1, frames: 480)
    stereo.withUnsafeBufferPointer { input in
        interleaved.withUnsafeMutableBufferPointer { output in
            process(input.baseAddress!, output.baseAddress!.advanced(by: 1), frames: frames,
                    ramp: &rampA, settings: settings, state: &stateA)
        }
    }
    left.withUnsafeBufferPointer { l in
        right.withUnsafeBufferPointer { r in
            planarL.withUnsafeMutableBufferPointer { outL in
                planarR.withUnsafeMutableBufferPointer { outR in
                    var offset = 0
                    for count in [1, 126, 257, 640] {
                        processStereo(l.baseAddress!.advanced(by: offset), r.baseAddress!.advanced(by: offset),
                                      outL.baseAddress!.advanced(by: offset + 1), outR.baseAddress!.advanced(by: offset + 1),
                                      frames: count, inputStride: 1, outputStride: 1,
                                      ramp: &rampB, settings: settings, state: &stateB)
                        offset += count
                    }
                }
            }
        }
    }
    #expect((0..<frames).allSatisfy { planarL[$0 + 1] == interleaved[$0 * 2 + 1] })
    #expect((0..<frames).allSatisfy { planarR[$0 + 1] == interleaved[$0 * 2 + 2] })
    #expect(planarL.first == 42 && planarL.last == 42)
    #expect(planarR.first == 42 && planarR.last == 42)
    #expect(interleaved.first == 42 && interleaved.last == 42)
}

@Test func presetsEmphasizeTheirNamedFrequencyRange() {
    var settings = EQSettings()
    settings.bandDB = EQPreset.bassFocus.bands
    let bass = renderTone(frequency: 62.5, settings: settings).0
    let treble = renderTone(frequency: 4000, settings: settings).0
    #expect(bass > treble * 1.4)
    settings.bandDB = EQPreset.midsTrebleFocus.bands
    let mids = renderTone(frequency: 2000, settings: settings).0
    let low = renderTone(frequency: 62.5, settings: settings).0
    #expect(mids > low * 1.4)
    #expect(EQPreset.flat.bands == SIMD16<Float>(repeating: 0))
}

@Test func fullScaleBoostIsLimitedToMinusPointThreeDBFS() {
    let input: [Float] = (0..<2048).flatMap { frame in
        [frame % 2 == 0 ? Float(1) : -1, Float(0.5)]
    }
    var output = [Float](repeating: 0, count: input.count)
    var settings = EQSettings()
    settings.boostDB = 12
    var state = EQState(sampleRate: 48000)
    var ramp = GainRamp(gain: 1)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            process(source.baseAddress!, destination.baseAddress!, frames: input.count / 2,
                    ramp: &ramp, settings: settings, state: &state)
        }
    }
    let ceiling = pow(10.0, -0.3 / 20)
    #expect(output.allSatisfy { $0.isFinite && Double(abs($0)) <= ceiling })
    #expect(output.suffix(100).map { abs($0) }.max()! > 0.96)
    // Linked limiting preserves the stereo ratio instead of clipping each channel.
    #expect(stride(from: 0, to: output.count, by: 2).allSatisfy {
        abs(abs(output[$0]) - output[$0 + 1] * 2) < 0.00001
    })
}

@Test func tinyBiquadHistoryIsFlushedToZero() {
    let input: [Float] = [1e-30, -1e-30, 0, 0, 0, 0, 0, 0]
    var output = [Float](repeating: 42, count: input.count)
    var settings = EQSettings()
    settings.bandDB[5] = 6
    var state = EQState(sampleRate: 48000)
    var ramp = GainRamp(gain: 1)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            process(source.baseAddress!, destination.baseAddress!, frames: 4,
                    ramp: &ramp, settings: settings, state: &state)
        }
    }
    #expect(output[0] != 0)
    #expect(output.dropFirst(2).allSatisfy { $0 == 0 })
}

@Test func limiterReleaseFollowsSixtyMillisecondEnvelopeAcrossBlocks() {
    for rate in [44100.0, 48000.0, 96000.0] {
        var state = EQState(sampleRate: rate)
        var ramp = GainRamp(gain: 1)
        func render(_ value: Float, frames: Int) -> [Float] {
            let input = [Float](repeating: value, count: frames * 2)
            var output = input
            input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { destination in
                    process(source.baseAddress!, destination.baseAddress!, frames: frames,
                            ramp: &ramp, settings: EQSettings(), state: &state)
                }
            }
            return output
        }
        let ceiling = 0.96605086
        _ = render(1, frames: 1)
        let initialGain = ceiling
        let frames = Int(rate * 0.06)
        let a = render(0.25, frames: 127)
        let b = render(0.25, frames: frames - 127)
        let samples = a + b
        #expect(Double(samples[0]) < 0.25)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        let expected = 1 - (1 - initialGain) * exp(-Double(frames) / (rate * 0.06))
        #expect(abs(Double(samples.last!) / 0.25 - expected) < 0.00001)
        #expect(Double(samples.last!) < 0.25)
        let recovered = render(0.25, frames: Int(rate * 0.6))
        #expect(abs(recovered.last! - 0.25) < 0.000001)
    }
}

private func runStereo(_ input: [Float], settings: EQSettings, state: inout EQState) -> [Float] {
    var output = [Float](repeating: 42, count: input.count)
    var ramp = GainRamp(gain: 1)
    input.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            process(source.baseAddress!, destination.baseAddress!, frames: input.count / 2,
                    ramp: &ramp, settings: settings, state: &state)
        }
    }
    return output
}

private func sineBlock(frames: Int = 512) -> [Float] {
    (0..<frames).flatMap { frame -> [Float] in
        let sample = Float(0.3 * sin(2 * .pi * 1000 * Double(frame) / 48000))
        return [sample, sample]
    }
}

/// Bad frames give finite silence, and the next clean block matches a fresh
/// state, so nothing non-finite lingered in the biquad history.
private func expectRecovery(bad: Float, settings: EQSettings) {
    var poisoned = [Float](repeating: 0, count: 64)
    poisoned[10] = bad; poisoned[11] = -bad     // frame 5
    poisoned[40] = bad                          // frame 20, left only
    var state = EQState(sampleRate: 48000)
    let first = runStereo(poisoned, settings: settings, state: &state)
    let ceiling = pow(10.0, -0.3 / 20)
    #expect(first.allSatisfy { $0.isFinite && Double(abs($0)) <= ceiling })
    #expect(first[10] == 0 && first[11] == 0)
    #expect(first[40] == 0)

    let clean = sineBlock()
    let after = runStereo(clean, settings: settings, state: &state)
    var fresh = EQState(sampleRate: 48000)
    let reference = runStereo(clean, settings: settings, state: &fresh)
    #expect(after.allSatisfy { $0.isFinite })
    #expect(zip(after, reference).allSatisfy { abs($0 - $1) < 1e-4 })
}

@Test func nanInputYieldsSilenceThenRecovers() {
    var settings = EQSettings()
    settings.bandDB[5] = 6
    expectRecovery(bad: .nan, settings: settings)
}

@Test func infInputYieldsSilenceThenRecovers() {
    var settings = EQSettings()
    settings.bandDB[5] = 6
    expectRecovery(bad: .infinity, settings: settings)
}

@Test func overflowingBoostResetsStateAndStaysFinite() {
    var settings = EQSettings()
    settings.boostDB = 12
    settings.bandDB[5] = 12
    // Silence completes the gain ramp and keeps the filter history at zero,
    // so a fresh state is a valid reference after the reset.
    let silence = [Float](repeating: 0, count: 2048)
    var state = EQState(sampleRate: 48000)
    _ = runStereo(silence, settings: settings, state: &state)
    let huge = [Float](repeating: 3e38, count: 32)
    let first = runStereo(huge, settings: settings, state: &state)
    let ceiling = pow(10.0, -0.3 / 20)
    #expect(first.allSatisfy { $0.isFinite && Double(abs($0)) <= ceiling })

    let clean = sineBlock()
    let after = runStereo(clean, settings: settings, state: &state)
    var fresh = EQState(sampleRate: 48000)
    _ = runStereo(silence, settings: settings, state: &fresh)
    let reference = runStereo(clean, settings: settings, state: &fresh)
    #expect(after.allSatisfy { $0.isFinite })
    #expect(zip(after, reference).allSatisfy { abs($0 - $1) < 1e-4 })
}
