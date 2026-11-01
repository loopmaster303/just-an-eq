public enum EQPreset: String, CaseIterable, Sendable {
    case flat = "Flat"
    case bassFocus = "Bass Focus"
    case midsTrebleFocus = "Mids-Treble Focus"

    public var bands: SIMD16<Float> {
        switch self {
        case .flat:
            SIMD16<Float>(repeating: 0)
        case .bassFocus:
            SIMD16<Float>(4, 4, 3, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        case .midsTrebleFocus:
            SIMD16<Float>(0, 0, 0, 0, 1, 3, 4, 4, 3, 2, 0, 0, 0, 0, 0, 0)
        }
    }
}
