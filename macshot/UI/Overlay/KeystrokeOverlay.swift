import Cocoa
import Carbon.HIToolbox

/// Transparent fullscreen overlay that shows pressed keys during recording.
/// Displays a pill-shaped HUD at the bottom center of the recording area.
class KeystrokeOverlay: NSPanel {

    private let keystrokeView: KeystrokeView
    private var recordingRect: NSRect = .zero

    init(screen: NSScreen) {
        keystrokeView = KeystrokeView()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 1  // above normal windows, captured by SCStream
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        keystrokeView.frame = NSRect(origin: .zero, size: screen.frame.size)
        keystrokeView.autoresizingMask = [.width, .height]
        contentView = keystrokeView
    }

    func setRecordingRect(_ rect: NSRect) {
        recordingRect = rect
        keystrokeView.recordingRect = NSRect(
            x: rect.minX - frame.minX,
            y: rect.minY - frame.minY,
            width: rect.width,
            height: rect.height)
    }

    /// Receives every key press (key code, device-independent modifier
    /// flags, display text) for the editor's keystroke track. Called on the
    /// main thread.
    var onKey: ((UInt16, UInt32, String) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Check if Input Monitoring permission is granted.
    static var hasInputMonitoringPermission: Bool {
        return CGPreflightListenEventAccess()
    }

    /// Request Input Monitoring permission (shows system dialog).
    static func requestInputMonitoringPermission() {
        CGRequestListenEventAccess()
    }

    func startMonitoring() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // Store a weak reference via a helper so the C callback can access self
        let context = Unmanaged.passRetained(EventTapContext(overlay: self)).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let ctx = Unmanaged<EventTapContext>.fromOpaque(refcon).takeUnretainedValue()
                ctx.overlay?.handleCGEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else { return }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stopMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        keystrokeView.clear()
    }

    nonisolated private func handleCGEvent(type: CGEventType, event: CGEvent) {
        if type == .flagsChanged {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            let showAll = UserDefaults.standard.bool(forKey: "keystrokeShowAll")
            if !showAll { return }
            let mods = Self.modifierSymbols(for: flags)
            DispatchQueue.main.async { [weak self] in
                self?.keystrokeView.updateModifiers(mods)
            }
            return
        }

        guard type == .keyDown else { return }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat { return }

        // Get the key code and flags directly from CGEvent
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))

        // Recorded keystrokes keep the typed case; the live overlay shows
        // key caps. Both skip bare modifier presses.
        let recorded = Self.typedText(keyCode, event: event)
        if !recorded.isEmpty {
            let mods = UInt32(truncatingIfNeeded: flags.intersection([.command, .control, .option, .shift]).rawValue)
            DispatchQueue.main.async { [weak self] in self?.onKey?(keyCode, mods, recorded) }
        }

        let showAll = UserDefaults.standard.bool(forKey: "keystrokeShowAll")
        let hasModifier = !flags.intersection([.command, .control, .option]).isEmpty
        if !showAll && !hasModifier { return }

        // Build display string from CGEvent fields (avoid NSEvent(cgEvent:) which can crash off main thread)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        let keyStr = Self.keyNameFromCode(keyCode, event: event)
        if !keyStr.isEmpty { parts.append(keyStr) }
        let display = parts.joined(separator: " ")
        guard !display.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.keystrokeView.showKeystroke(display)
        }
    }

    // MARK: - Key Display Formatting

    nonisolated private static func modifierSymbols(for flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.capsLock) { parts.append("⇪") }
        return parts.joined(separator: " ")
    }

    /// Display text for a recorded key: symbols for special keys, the typed
    /// character (with its case) otherwise.
    nonisolated private static func typedText(_ keyCode: UInt16, event: CGEvent) -> String {
        let name = keyNameFromCode(keyCode, event: event)
        guard name.count == 1 else { return name }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        let typed = length > 0 ? String(utf16CodeUnits: chars, count: length) : name
        // Control characters (from ⌃-combinations) fall back to the key cap.
        return typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) ? typed : name
    }

    /// Convert a key code to a display name. For printable keys, uses CGEvent's
    /// Unicode string which works safely from any thread (unlike NSEvent.characters).
    nonisolated private static func keyNameFromCode(_ keyCode: UInt16, event: CGEvent) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Shift, kVK_RightShift,
             kVK_Command, kVK_RightCommand,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_CapsLock, kVK_Function:
            return ""
        default:
            // Get the character from CGEvent (thread-safe, unlike NSEvent.characters)
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
            if length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
            return ""
        }
    }
}

// MARK: - Event Tap Context

/// Prevents retain cycle between the C callback and the overlay.
private class EventTapContext {
    weak var overlay: KeystrokeOverlay?
    init(overlay: KeystrokeOverlay) { self.overlay = overlay }
}

// MARK: - Keystroke View

private class KeystrokeView: NSView {

    var recordingRect: NSRect = .zero
    private var currentText: String = ""
    private var modifierText: String = ""
    private var fadeTimer: Timer?
    private var opacity: CGFloat = 0

    override var isFlipped: Bool { false }

    func showKeystroke(_ text: String) {
        guard !text.isEmpty else { return }
        currentText = text
        modifierText = ""
        opacity = 1.0
        needsDisplay = true

        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    func updateModifiers(_ mods: String) {
        // Only show modifiers when no key combo is visible
        if currentText.isEmpty || opacity < 0.1 {
            if mods.isEmpty {
                modifierText = ""
                opacity = 0
            } else {
                modifierText = mods
                currentText = ""
                opacity = 1.0
                fadeTimer?.invalidate()
            }
            needsDisplay = true
        }
    }

    func clear() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        currentText = ""
        modifierText = ""
        opacity = 0
        needsDisplay = true
    }

    private func fadeOut() {
        fadeTimer?.invalidate()
        // Animate opacity down
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.opacity -= 0.05
            if self.opacity <= 0 {
                self.opacity = 0
                self.currentText = ""
                self.modifierText = ""
                timer.invalidate()
                self.fadeTimer = nil
            }
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard opacity > 0 else { return }

        let text = currentText.isEmpty ? modifierText : currentText
        guard !text.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 28, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
        ]

        let str = text as NSString
        let textSize = str.size(withAttributes: attrs)
        let padH: CGFloat = 24
        let padV: CGFloat = 14
        let pillW = textSize.width + padH * 2
        let pillH = textSize.height + padV * 2
        let cornerRadius: CGFloat = 14

        // Position at bottom center of recording rect
        let area = recordingRect.isEmpty ? bounds : recordingRect
        let pillX = area.midX - pillW / 2
        let pillY = area.minY + 40

        let pillRect = NSRect(x: pillX, y: pillY, width: pillW, height: pillH)

        // Background pill
        NSColor.black.withAlphaComponent(0.65 * opacity).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        // Subtle border
        NSColor.white.withAlphaComponent(0.15 * opacity).setStroke()
        let border = NSBezierPath(roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1
        border.stroke()

        // Text
        let textX = pillRect.midX - textSize.width / 2
        let textY = pillRect.midY - textSize.height / 2
        str.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
    }
}
