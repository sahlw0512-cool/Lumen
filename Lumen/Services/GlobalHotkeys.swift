import Carbon.HIToolbox

/// System-wide keyboard shortcuts through Carbon's `RegisterEventHotKey`,
/// which works in the sandbox and needs no Accessibility permission.
@MainActor
final class GlobalHotkeys {
    enum Action: UInt32, CaseIterable {
        case togglePause = 1
        case nextWallpaper = 2
        case showLumen = 3

        var title: String {
            switch self {
            case .togglePause: "Pause or Resume Wallpaper"
            case .nextWallpaper: "Next Wallpaper"
            case .showLumen: "Show Lumen"
            }
        }

        var keyCode: UInt32 {
            switch self {
            case .togglePause: UInt32(kVK_ANSI_P)
            case .nextWallpaper: UInt32(kVK_RightArrow)
            case .showLumen: UInt32(kVK_ANSI_L)
            }
        }

        /// ⌃⌥⌘ plus a key: unlikely to collide with app shortcuts.
        static let modifiers = UInt32(controlKey | optionKey | cmdKey)

        var displayString: String {
            switch self {
            case .togglePause: "⌃⌥⌘P"
            case .nextWallpaper: "⌃⌥⌘→"
            case .showLumen: "⌃⌥⌘L"
            }
        }
    }

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var handler: ((Action) -> Void)?
    private static let signature: OSType = 0x4C4D_4E48   // "LMNH"

    func register(_ handler: @escaping (Action) -> Void) {
        unregisterAll()
        self.handler = handler
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let action = Action(rawValue: hotKeyID.id) { hotkeys.handler?(action) }
            }
            return noErr
        }, 1, &eventType, context, &handlerRef)

        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(action.keyCode, Action.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                Log.warning("Shortcut \(action.displayString) is already used by another app", category: "app")
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        handler = nil
    }
}
