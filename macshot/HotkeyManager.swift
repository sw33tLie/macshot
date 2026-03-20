import Cocoa
import Carbon

class HotkeyManager {

    static let shared = HotkeyManager()

    /// Named hotkey slots with UserDefaults keys and defaults.
    enum HotkeySlot: Int, CaseIterable {
        case captureArea = 1
        case captureFullScreen = 2
        case recordArea = 3
        case recordScreen = 4

        var keyCodeKey: String {
            switch self {
            case .captureArea: return "hotkeyKeyCode"
            case .captureFullScreen: return "hotkeyFullScreenKeyCode"
            case .recordArea: return "hotkeyRecordKeyCode"
            case .recordScreen: return "hotkeyRecordFullScreenKeyCode"
            }
        }

        var modifiersKey: String {
            switch self {
            case .captureArea: return "hotkeyModifiers"
            case .captureFullScreen: return "hotkeyFullScreenModifiers"
            case .recordArea: return "hotkeyRecordModifiers"
            case .recordScreen: return "hotkeyRecordFullScreenModifiers"
            }
        }

        var label: String {
            switch self {
            case .captureArea: return "Capture Area"
            case .captureFullScreen: return "Capture Screen"
            case .recordArea: return "Record Area"
            case .recordScreen: return "Record Screen"
            }
        }

        var defaultKeyCode: UInt32 {
            switch self {
            case .captureArea: return UInt32(kVK_ANSI_X)
            case .captureFullScreen: return UInt32(kVK_ANSI_F)
            case .recordArea: return UInt32(kVK_ANSI_R)
            case .recordScreen: return 0
            }
        }

        var defaultModifiers: UInt32 {
            switch self {
            case .recordScreen: return 0  // no default hotkey
            default: return UInt32(cmdKey | shiftKey)
            }
        }
    }

    private var hotKeyRefs: [HotkeySlot: EventHotKeyRef] = [:]
    private var callbacks: [HotkeySlot: () -> Void] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    /// Register a callback for a hotkey slot. Reads keyCode/modifiers from UserDefaults.
    func register(slot: HotkeySlot, callback: @escaping () -> Void) {
        callbacks[slot] = callback

        // Unregister existing hotkey for this slot
        if let ref = hotKeyRefs[slot] {
            UnregisterEventHotKey(ref)
            hotKeyRefs[slot] = nil
        }

        let (keyCode, modifiers) = Self.readHotkey(for: slot)
        guard modifiers != 0 else { return }  // no modifiers = disabled

        installEventHandler()
        var ref: EventHotKeyRef?
        var hotkeyID = EventHotKeyID(signature: OSType(0x4D53_4854), id: UInt32(slot.rawValue))

        let status = RegisterEventHotKey(
            keyCode, modifiers, hotkeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            hotKeyRefs[slot] = ref
        }
    }

    /// Register all hotkeys with their callbacks.
    func registerAll(captureArea: @escaping () -> Void, captureFullScreen: @escaping () -> Void, recordArea: @escaping () -> Void, recordScreen: @escaping () -> Void) {
        unregisterAll()
        register(slot: .captureArea, callback: captureArea)
        register(slot: .captureFullScreen, callback: captureFullScreen)
        register(slot: .recordArea, callback: recordArea)
        register(slot: .recordScreen, callback: recordScreen)
    }

    /// Re-register all hotkeys (e.g., after preferences change).
    func reregisterAll() {
        let savedCallbacks = callbacks
        unregisterAll()
        for (slot, cb) in savedCallbacks {
            register(slot: slot, callback: cb)
        }
    }

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData, let event = event else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotkeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)

                if let slot = HotkeySlot(rawValue: Int(hotkeyID.id)) {
                    mgr.callbacks[slot]?()
                }
                return noErr
            },
            1, &eventType, selfPtr, &eventHandlerRef
        )
    }

    func unregisterAll() {
        for (slot, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    /// Legacy — kept for backward compatibility.
    func unregister() { unregisterAll() }

    deinit { unregisterAll() }

    // MARK: - UserDefaults Helpers

    /// Read the stored (or default) keyCode and modifiers for a slot.
    static func readHotkey(for slot: HotkeySlot) -> (keyCode: UInt32, modifiers: UInt32) {
        let storedKey = UInt32(UserDefaults.standard.integer(forKey: slot.keyCodeKey))
        let storedMods = UInt32(UserDefaults.standard.integer(forKey: slot.modifiersKey))

        if storedKey == 0 && storedMods == 0 {
            return (slot.defaultKeyCode, slot.defaultModifiers)
        }
        return (storedKey, storedMods)
    }

    /// Save a hotkey to UserDefaults.
    static func saveHotkey(for slot: HotkeySlot, keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: slot.keyCodeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: slot.modifiersKey)
    }

    /// Display string for a slot's current hotkey.
    static func displayString(for slot: HotkeySlot) -> String {
        let (keyCode, modifiers) = readHotkey(for: slot)
        return modifierString(from: modifiers) + keyString(from: keyCode)
    }

    /// Legacy display string (for capture area).
    static func shortcutDisplayString() -> String {
        return displayString(for: .captureArea)
    }

    // MARK: - String Helpers

    static func modifierString(from carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        return parts.joined()
    }

    static func keyString(from keyCode: UInt32) -> String {
        let keyMap: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_Space): "Space",
        ]
        return keyMap[keyCode] ?? "?"
    }
}
