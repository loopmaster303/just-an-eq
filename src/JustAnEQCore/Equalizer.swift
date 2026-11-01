import Foundation

/// Graphic: ten octave sliders. Mixer: four DJ-mixer bands (LF, Lo-Mid, Hi-Mid, HF).
public enum EQMode: String, Codable, Sendable, CaseIterable {
    case mixer, graphic
}

public struct EQSettings: Equatable, Sendable, Codable {
    public var balance: Float = 0
    public var boostDB: Float = 0
    public var bandDB = SIMD16<Float>(repeating: 0)
    public var mode = EQMode.graphic
    /// LF, Lo-Mid, Hi-Mid, HF gains in dB.
    public var mixerDB = SIMD4<Float>(repeating: 0)
    public static let mixerRange: ClosedRange<Float> = -26...6
    /// Graphic bands use filter slots 0-9, mixer bands slots 10-13.
    public static let filterCount = 14
    public init() {}

    private enum CodingKeys: String, CodingKey { case balance, boostDB, bandDB, mode, mixerDB }

    /// Tolerant decoding: stored values are clamped, non-finite values become 0,
    /// and the band list is padded or truncated to ten.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func clean(_ value: Float?, _ range: ClosedRange<Float>) -> Float {
            guard let value, value.isFinite else { return 0 }
            return min(range.upperBound, max(range.lowerBound, value))
        }
        balance = clean(try? container.decode(Float.self, forKey: .balance), -1...1)
        boostDB = clean(try? container.decode(Float.self, forKey: .boostDB), 0...12)
        let bands = (try? container.decode([Float].self, forKey: .bandDB)) ?? []
        for index in 0..<10 { bandDB[index] = clean(index < bands.count ? bands[index] : nil, -12...12) }
        mode = (try? container.decode(EQMode.self, forKey: .mode)) ?? .graphic
        let mixer = (try? container.decode([Float].self, forKey: .mixerDB)) ?? []
        for index in 0..<4 { mixerDB[index] = clean(index < mixer.count ? mixer[index] : nil, Self.mixerRange) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(balance, forKey: .balance)
        try container.encode(boostDB, forKey: .boostDB)
        try container.encode((0..<10).map { bandDB[$0] }, forKey: .bandDB)
        try container.encode(mode, forKey: .mode)
        try container.encode((0..<4).map { mixerDB[$0] }, forKey: .mixerDB)
    }

    /// Gains per filter slot; the inactive mode's slots are flat (identity).
    public var effectiveBands: SIMD16<Float> {
        var bands = SIMD16<Float>(repeating: 0)
        switch mode {
        case .graphic:
            for index in 0..<10 { bands[index] = bandDB[index] }
        case .mixer:
            for index in 0..<4 { bands[10 + index] = mixerDB[index] }
        }
        return bands
    }

    public static func frequency(_ index: Int) -> Double {
        switch index {
        case 0: 31.25
        case 1: 62.5
        case 2: 125
        case 3: 250
        case 4: 500
        case 5: 1000
        case 6: 2000
        case 7: 4000
        case 8: 8000
        default: 16000
        }
    }
}

/// Fixed-size, stereo biquad history. Only the audio callback mutates this value.
public struct EQState {
    private let sampleRate: Double
    private var previousBands = SIMD16<Float>(repeating: 0)
    private var previous = EQSettings()
    private var b0 = SIMD16<Double>(repeating: 1)
    private var b1 = SIMD16<Double>(repeating: 0)
    private var b2 = SIMD16<Double>(repeating: 0)
    private var a1 = SIMD16<Double>(repeating: 0)
    private var a2 = SIMD16<Double>(repeating: 0)
    private var z1L = SIMD16<Double>(repeating: 0)
    private var z2L = SIMD16<Double>(repeating: 0)
    private var z1R = SIMD16<Double>(repeating: 0)
    private var z2R = SIMD16<Double>(repeating: 0)
    private var leftGain = GainRamp(gain: 1)
    private var rightGain = GainRamp(gain: 1)
    private var limiter: PeakLimiter
    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        limiter = PeakLimiter(sampleRate: sampleRate)
    }

    mutating func limit(_ frame: SIMD2<Float>) -> SIMD2<Float> { limiter.process(frame) }

    mutating func configure(_ settings: EQSettings) {
        if settings.balance != previous.balance || settings.boostDB != previous.boostDB {
            let boost = pow(Float(10), min(12, max(0, settings.boostDB)) / 20)
            let balance = min(1, max(-1, settings.balance))
            let frames = max(2, Int(sampleRate * 0.01))
            leftGain.setTarget(boost * (1 - max(0, balance)), frames: frames)
            rightGain.setTarget(boost * (1 + min(0, balance)), frames: frames)
        }
        let bands = settings.effectiveBands
        for band in 0..<EQSettings.filterCount where bands[band] != previousBands[band] {
            setCoefficients(band, gain: Double(bands[band]))
        }
        previousBands = bands
        previous = settings
    }

    /// RBJ cookbook biquads. Slots 0-9: octave peaks (Q = sqrt(2), +-12 dB).
    /// Slots 10-13: LF 100 Hz low shelf, 400 Hz and 2.5 kHz peaks (Q = 0.7),
    /// HF 8 kHz high shelf, all -26...+6 dB.
    private mutating func setCoefficients(_ band: Int, gain: Double) {
        let mixer = band >= 10
        let range = mixer ? EQSettings.mixerRange : -12...12
        let db = min(Double(range.upperBound), max(Double(range.lowerBound), gain))
        let frequency: Double = switch band { // no array literal on the audio thread
        case 10: 100
        case 11: 400
        case 12: 2500
        case 13: 8000
        default: EQSettings.frequency(band)
        }
        let omega = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let amplitude = pow(10, db / 40)
        let cosine = cos(omega)
        var n0, n1, n2, d0, d1, d2: Double
        if band == 10 || band == 13 {
            let shelf = 2 * sqrt(amplitude) * sin(omega) / 2 * sqrt(2.0)
            let ap = amplitude + 1, am = amplitude - 1
            if band == 10 {
                n0 = amplitude * (ap - am * cosine + shelf)
                n1 = 2 * amplitude * (am - ap * cosine)
                n2 = amplitude * (ap - am * cosine - shelf)
                d0 = ap + am * cosine + shelf
                d1 = -2 * (am + ap * cosine)
                d2 = ap + am * cosine - shelf
            } else {
                n0 = amplitude * (ap + am * cosine + shelf)
                n1 = -2 * amplitude * (am + ap * cosine)
                n2 = amplitude * (ap + am * cosine - shelf)
                d0 = ap - am * cosine + shelf
                d1 = 2 * (am - ap * cosine)
                d2 = ap - am * cosine - shelf
            }
        } else {
            let alpha = sin(omega) / (2 * (mixer ? 0.7 : sqrt(2.0)))
            n0 = 1 + alpha * amplitude
            n1 = -2 * cosine
            n2 = 1 - alpha * amplitude
            d0 = 1 + alpha / amplitude
            d1 = n1
            d2 = 1 - alpha / amplitude
        }
        b0[band] = n0 / d0
        b1[band] = n1 / d0
        b2[band] = n2 / d0
        a1[band] = d1 / d0
        a2[band] = d2 / d0
    }

    @inline(__always)
    private func flushTiny(_ value: Double) -> Double {
        abs(value) < 1e-24 ? 0 : value
    }

    @inline(__always)
    mutating func frame(_ input: SIMD2<Float>) -> SIMD2<Float> {
        // Non-finite input would poison the biquad history for good: use silence.
        var left = input[0].isFinite ? Double(input[0]) : 0
        var right = input[1].isFinite ? Double(input[1]) : 0
        for band in 0..<EQSettings.filterCount {
            let outL = b0[band] * left + z1L[band]
            let outR = b0[band] * right + z1R[band]
            z1L[band] = flushTiny(b1[band] * left - a1[band] * outL + z2L[band])
            z2L[band] = flushTiny(b2[band] * left - a2[band] * outL)
            z1R[band] = flushTiny(b1[band] * right - a1[band] * outR + z2R[band])
            z2R[band] = flushTiny(b2[band] * right - a2[band] * outR)
            left = outL; right = outR
        }
        let out = SIMD2(Float(left) * leftGain.next(), Float(right) * rightGain.next())
        // Overflow or a bad state: drop the history so it cannot persist, and
        // output silence rather than letting the limiter turn NaN into DC.
        guard out[0].isFinite, out[1].isFinite else {
            z1L = .zero; z2L = .zero; z1R = .zero; z2R = .zero
            return .zero
        }
        return out
    }
}

/// Pure DSP: no allocation, locks, Core Audio calls or logging. Supports planar
/// buffers through strides, with the same state/ramp once per stereo frame.
public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int,
                    ramp: inout GainRamp, settings: EQSettings, state: inout EQState) {
    processStereo(input, input.advanced(by: 1), output, output.advanced(by: 1),
                  frames: frames, inputStride: 2, outputStride: 2,
                  ramp: &ramp, settings: settings, state: &state)
}

public func processStereo(_ leftIn: UnsafePointer<Float>, _ rightIn: UnsafePointer<Float>,
                          _ leftOut: UnsafeMutablePointer<Float>, _ rightOut: UnsafeMutablePointer<Float>,
                          frames: Int, inputStride: Int, outputStride: Int,
                          ramp: inout GainRamp, settings: EQSettings, state: inout EQState) {
    guard frames > 0 else { return }
    state.configure(settings)
    for frame in 0..<frames {
        let stereo = state.frame(SIMD2(leftIn[frame * inputStride], rightIn[frame * inputStride]))
        let gain = ramp.next()
        let limited = state.limit(stereo * gain)
        leftOut[frame * outputStride] = limited[0]
        rightOut[frame * outputStride] = limited[1]
    }
}

/// Same chain as `processStereo`, but writes the average of both limited
/// channels into one output (Bluetooth headset mode exposes mono output).
public func processDownmix(_ leftIn: UnsafePointer<Float>, _ rightIn: UnsafePointer<Float>,
                           _ output: UnsafeMutablePointer<Float>,
                           frames: Int, inputStride: Int,
                           ramp: inout GainRamp, settings: EQSettings, state: inout EQState) {
    guard frames > 0 else { return }
    state.configure(settings)
    for frame in 0..<frames {
        let stereo = state.frame(SIMD2(leftIn[frame * inputStride], rightIn[frame * inputStride]))
        let gain = ramp.next()
        let limited = state.limit(stereo * gain)
        output[frame] = (limited[0] + limited[1]) * 0.5
    }
}
