/// Processes interleaved stereo Float32 frames. Input and output must each hold
/// at least `frames * 2` samples. Zero frames never accesses either pointer.
@inline(__always)
public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) {
    guard frames > 0 else { return }
    for sample in 0..<(frames * 2) {
        output[sample] = input[sample]
    }
}

public struct GainRamp {
    public private(set) var gain: Float
    private var target: Float
    private var step: Float = 0
    private var remaining = 0
    public var isComplete: Bool { remaining == 0 }

    public init(gain: Float) { self.gain = gain; target = gain }

    public mutating func setTarget(_ target: Float, frames: Int) {
        self.target = target
        remaining = max(0, frames)
        step = frames > 1 ? (target - gain) / Float(frames - 1) : 0
        if frames <= 1 { gain = target }
    }

    @inline(__always)
    public mutating func next() -> Float {
        let value = gain
        if remaining > 0 {
            remaining -= 1
            gain = remaining <= 1 ? target : gain + step
        }
        return value
    }
}
