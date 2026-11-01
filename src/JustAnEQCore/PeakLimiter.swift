import Foundation

/// Stereo-linked gain envelope: instantaneous attack, 60 ms exponential release
/// toward unity. Coefficient and state are fixed scalars; no RT allocations.
struct PeakLimiter {
    private let ceiling: Float = 0.96605086 // Float rounded below -0.3 dBFS
    private let release: Double
    private var gain = 1.0

    init(sampleRate: Double) { release = exp(-1 / (sampleRate * 0.060)) }

    mutating func process(_ frame: SIMD2<Float>) -> SIMD2<Float> {
        let peak = Double(max(abs(frame[0]), abs(frame[1])))
        let target = peak > Double(ceiling) ? Double(ceiling) / peak : 1
        gain = target < gain ? target : min(target, 1 - (1 - gain) * release)
        let left = Float(Double(frame[0]) * gain)
        let right = Float(Double(frame[1]) * gain)
        // Protect the exact ceiling against final Float rounding.
        return SIMD2(min(ceiling, max(-ceiling, left)), min(ceiling, max(-ceiling, right)))
    }
}
