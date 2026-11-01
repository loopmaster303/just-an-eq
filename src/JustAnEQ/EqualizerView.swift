import AppKit
import JustAnEQCore
import SwiftUI

struct EqualizerView: View {
    @ObservedObject var controller: AppController

    private let bandNames = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    /// Channel-strip order, top to bottom: HF, Hi-Mid, Lo-Mid, LF (mixerDB indices 3...0).
    private let mixerKnobs = [(3, "HF"), (2, "HI MID"), (1, "LO MID"), (0, "LF")]

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("just an eq").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(controller.isOn ? "Listening" : "Off")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("On", isOn: Binding(get: { controller.isOn }, set: { controller.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().accessibilityLabel("Engine On")
            }
            VStack(spacing: 12) {
                HStack {
                    Text("Balance")
                    Spacer()
                    Text(balanceLabel).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 10) {
                    Text("L").foregroundStyle(.secondary)
                    Slider(value: $controller.settings.balance, in: -1...1)
                        .accessibilityLabel("Left-right balance")
                    Text("R").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Boost")
                    Spacer()
                    Text(String(format: "+%.1f dB", controller.settings.boostDB))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $controller.settings.boostDB, in: 0...12, step: 0.5)
                    .accessibilityLabel("Volume boost in decibels")
            }
            Picker("EQ mode", selection: Binding(get: { controller.settings.mode },
                                                 set: { controller.settings.mode = $0 })) {
                Text("Mixer").tag(EQMode.mixer)
                Text("Graphic").tag(EQMode.graphic)
            }
            .pickerStyle(.segmented).labelsHidden()
            if controller.settings.mode == .mixer {
                Grid(horizontalSpacing: 28, verticalSpacing: 14) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(mixerKnobs[(row * 2)..<(row * 2 + 2)], id: \.0) { index, name in
                                RotaryKnob(label: name, value: Binding(get: { controller.settings.mixerDB[index] },
                                                                      set: { controller.setMixer(index, $0) }))
                            }
                        }
                    }
                }
            } else {
                graphicControls
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Audio error: \(error)")
            }
            HStack {
                Button("Reset") {
                    let mode = controller.settings.mode
                    controller.settings = EQSettings()
                    controller.settings.mode = mode
                    controller.select(.flat)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 340)
        .modifier(IslandBackground())
        .padding(18)
        .preferredColorScheme(.dark)
    }

    /// Presets and the ten-band sliders (graphic mode).
    private var graphicControls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                ForEach(EQPreset.allCases, id: \.self) { preset in
                    Button { controller.select(preset) } label: {
                        Text(preset.rawValue).font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(controller.preset == preset ? Color.white.opacity(0.17) : .clear,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(controller.preset == preset ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.white.opacity(0.045), in: Capsule())
            DisclosureGroup("Custom EQ", isExpanded: Binding(get: { controller.expanded }, set: { controller.expanded = $0 })) {
                VStack(spacing: 10) {
                    ForEach(0..<10, id: \.self) { index in
                        HStack(spacing: 8) {
                            Text(bandNames[index]).frame(width: 28, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(get: { controller.settings.bandDB[index] },
                                                  set: { controller.setBand(index, $0) }), in: -12...12, step: 0.5)
                                .accessibilityLabel("\(bandNames[index]) hertz gain in decibels")
                            Text(String(format: "%+.1f", controller.settings.bandDB[index]))
                                .monospacedDigit().frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                .font(.caption).padding(.top, 12)
            }
            .font(.caption)
        }
    }

    private var balanceLabel: String {
        let balance = controller.settings.balance
        if abs(balance) < 0.01 { return "Center" }
        return String(format: "%@ %.0f%%", balance < 0 ? "L" : "R", abs(balance) * 100)
    }
}

/// Rounded island chrome: Liquid Glass on macOS 26+, material elsewhere.
private struct IslandBackground: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay { stroke }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .overlay { stroke }
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var stroke: some View {
        shape.strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false)
    }
}
