import Carbon.HIToolbox

/// Global hotkey via RegisterEventHotKey (no accessibility permission needed).
/// Default chord: Control-Option-Command-E.
@MainActor
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: Int = kVK_ANSI_E, modifiers: Int = controlKey | optionKey | cmdKey,
          action: @escaping @MainActor () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D45_5131), id: id) // 'MEQ1'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil } // e.g. chord already taken: UI still works
        Self.handlers[id] = { Task { @MainActor in action() } }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
