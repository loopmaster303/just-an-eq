import AppKit
import JustAnEQCore
import SwiftUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var expanded = false
    @Published private(set) var isOn = false
    @Published private(set) var errorMessage: String?
    @Published var settings = EQSettings() {
        didSet { engine.settings = settings; scheduleSave() }
    }
    @Published private(set) var preset: EQPreset? = .flat {
        didSet { scheduleSave() }
    }
    private let engine = TapEngine()
    private let store = SettingsStore()
    private var saveTask: Task<Void, Never>?
    private var hotKey: HotKey?
    private var statusPanel: StatusPanelController?

    override init() {
        super.init()
        // Restore saved EQ values only; the engine always starts Off.
        let saved = store.load()
        settings = saved.settings
        preset = saved.preset
        hotKey = HotKey { [weak self] in self?.toggle() }
        engine.onOutputChange = { [weak self] in
            self?.isOn = false
            self?.errorMessage = "Audio device or format changed. Engine stopped. Turn On to retry."
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.store.save(self.settings, preset: self.preset)
        }
    }

    func select(_ preset: EQPreset) {
        self.preset = preset
        settings.bandDB = preset.bands
    }

    func setMixer(_ index: Int, _ value: Float) {
        settings.mixerDB[index] = value
    }

    func setBand(_ index: Int, _ value: Float) {
        preset = nil
        settings.bandDB[index] = value
    }

    /// Same path as the UI switch.
    func toggle() { setEnabled(!isOn) }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        if enabled {
            do {
                try engine.start()
                isOn = true
            } catch {
                errorMessage = error.localizedDescription
                isOn = false
            }
        } else {
            engine.stop()
            isOn = false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusPanel = StatusPanelController(controller: self)
        // Menu-bar-only app: show the panel so a launch from Finder visibly does something.
        statusPanel?.show(waitForIcon: 10)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusPanel?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveTask?.cancel()
        store.save(settings, preset: preset)
        engine.stop()
    }
}

@main
enum JustAnEQMain {
    // AppKit entry point: no SwiftUI scene, so no Settings window (and no Cmd+, handler).
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppController()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run() // never returns, which keeps `delegate` alive
    }
}
