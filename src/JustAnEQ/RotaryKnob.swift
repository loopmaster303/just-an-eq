import JustAnEQCore
import SwiftUI

/// DJ-mixer style rotary: 270° sweep, 0 dB at 12 o'clock (cut on the left half,
/// boost on the right). Drag up/right to turn, double-click for 0 dB.
struct RotaryKnob: View {
    let label: String
    @Binding var value: Float
    var range: ClosedRange<Float> = EQSettings.mixerRange
    var size: CGFloat = 104

    // @State is a macro the Command Line Tools toolchain cannot expand.
    @StateObject private var drag = DragAnchor()

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                arc(from: 0, to: 1).stroke(.white.opacity(0.09), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                arc(from: min(0.5, fraction), to: max(0.5, fraction))
                    .stroke(value < 0 ? Color.cyan : Color.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.13)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 4)
                    .padding(13)
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.27)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(size * 0.26)
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: size * 0.17)
                    .offset(y: -(size / 2 - 13 - size * 0.12))
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(turn)
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(1.2)
            Text(valueText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) gain")
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            value = clamp(value + (direction == .increment ? 1 : -1))
        }
    }

    private var turn: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let start = drag.start ?? fraction
                drag.start = start
                let delta = Double(gesture.translation.width - gesture.translation.height) / 220
                value = Self.value(at: min(1, max(0, start + delta)), range: range)
            }
            .onEnded { _ in drag.start = nil }
    }

    private var fraction: Double { Self.fraction(of: value, range: range) }

    private var valueText: String {
        value <= range.lowerBound ? "KILL" : String(format: "%+.1f dB", value)
    }

    private func clamp(_ v: Float) -> Float { min(range.upperBound, max(range.lowerBound, v)) }

    private func arc(from start: Double, to end: Double) -> some Shape {
        Circle().inset(by: 3).trim(from: start * 0.75, to: end * 0.75).rotation(.degrees(135))
    }

    /// Piecewise: lower...0 maps to the left half, 0...upper to the right half.
    static func fraction(of value: Float, range: ClosedRange<Float>) -> Double {
        let v = Double(min(range.upperBound, max(range.lowerBound, value)))
        return v < 0 ? 0.5 * (1 - v / Double(range.lowerBound)) : 0.5 + 0.5 * v / Double(range.upperBound)
    }

    /// Inverse of `fraction`, rounded to 0.5 dB with a detent around 0 dB.
    static func value(at fraction: Double, range: ClosedRange<Float>) -> Float {
        let raw = fraction < 0.5 ? Double(range.lowerBound) * (1 - fraction * 2)
                                 : Double(range.upperBound) * (fraction - 0.5) * 2
        let rounded = Float((raw * 2).rounded() / 2)
        return abs(rounded) < 0.75 ? 0 : min(range.upperBound, max(range.lowerBound, rounded))
    }
}

/// Knob value at drag start; not published, it never drives rendering.
private final class DragAnchor: ObservableObject {
    var start: Double?
}
