import AppKit
import Combine
import SwiftUI

/// Borderless panel that can take key focus so sliders and the switch work.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Own status item + borderless panel, so no system popover chrome is drawn.
@MainActor
final class StatusPanelController: NSObject {
    private let controller: AppController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: KeyPanel
    private let hosting: NSHostingView<EqualizerView>
    private var cancellables = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(controller: AppController) {
        self.controller = controller
        hosting = NSHostingView(rootView: EqualizerView(controller: controller))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = hosting

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        Publishers.CombineLatest(controller.$isOn, controller.$errorMessage)
            .sink { [weak self] isOn, error in self?.updateIcon(isOn: isOn, hasError: error != nil) }
            .store(in: &cancellables)
        // Content height changes with the custom-EQ disclosure, the EQ mode and the error line.
        Publishers.Merge3(controller.$expanded.map { _ in () }, controller.$errorMessage.map { _ in () },
                          controller.$settings.map(\.mode).removeDuplicates().map { _ in () })
            .sink { [weak self] in DispatchQueue.main.async { self?.resizeKeepingTop() } }
            .store(in: &cancellables)
    }

    private func updateIcon(isOn: Bool, hasError: Bool) {
        let image = NSImage(systemSymbolName: menuIconName(isOn: isOn, hasError: hasError),
                            accessibilityDescription: "just-an-eq")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePanel() {
        panel.isVisible ? closePanel() : openPanel()
    }

    /// Opens the panel unless it is already visible (launch and Finder re-open).
    /// At launch the status item is placed a moment later: wait up to `attempts` x 0.1 s
    /// for it, then fall back to the top-right position.
    func show(waitForIcon attempts: Int = 0) {
        guard !panel.isVisible else { return }
        if attempts > 0, !iconPlaced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.show(waitForIcon: attempts - 1)
            }
            return
        }
        openPanel()
    }

    private var iconPlaced: Bool {
        guard let window = statusItem.button?.window, let screen = window.screen else { return false }
        return window.frame.minY >= screen.visibleFrame.maxY - 1
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let size = hosting.fittingSize
        var anchor = buttonWindow.frame
        var visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        // A crowded menu bar (notch) hides the icon at y = 0: drop in at the top right
        // of the menu-bar screen instead.
        if anchor.minY < visible.maxY - 1 {
            visible = NSScreen.screens.first?.visibleFrame ?? visible
            anchor = NSRect(x: visible.maxX - size.width / 2 - 40, y: visible.maxY, width: 0, height: 0)
        }
        // Panel includes 18pt shadow padding; sit the island just under the menu bar.
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX), visible.maxX - size.width)
        let y = anchor.minY + 12 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        installMonitors(buttonWindow: buttonWindow)
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func resizeKeepingTop() {
        guard panel.isVisible else { return }
        let size = hosting.fittingSize
        var frame = panel.frame
        guard frame.size != size else { return }
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func installMonitors(buttonWindow: NSWindow) {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
            [weak self] event in
            let swallow = MainActor.assumeIsolated { self?.handleLocal(event, buttonWindow: buttonWindow) ?? false }
            return swallow ? nil : event
        }
    }

    /// Returns true when the event is consumed (Esc).
    private func handleLocal(_ event: NSEvent, buttonWindow: NSWindow) -> Bool {
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            closePanel()
            return true
        }
        // The status button handles its own click (toggle); clicks in other windows close the panel.
        if event.window !== panel, event.window !== buttonWindow { closePanel() }
        return false
    }
}
