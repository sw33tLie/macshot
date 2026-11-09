import Cocoa
import Carbon

/// Resolves shortcuts by the character produced by the active keyboard layout,
/// while retaining a Latin fallback for non-Latin input sources.
enum KeyboardShortcutMatcher {
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    static func modifiers(in event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(relevantModifiers)
    }

    static func matches(
        _ event: NSEvent,
        character: String,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard self.modifiers(in: event) == modifiers.intersection(relevantModifiers) else { return false }
        // Both sides must resolve to a real character. Comparing the optionals
        // directly would treat "no character on either side" as a match, so a
        // non-character key (Return, Escape, Tab) would fire any binding whose
        // stored character doesn't normalize.
        guard let expected = normalize(character),
              let actual = semanticCharacter(for: event) else { return false }
        return actual == expected
    }

    /// The logical character for a command shortcut. Latin layouts use the
    /// character they actually produce (so QWERTZ/AZERTY/Dvorak behave
    /// naturally). Non-Latin layouts fall back through the user's most recent
    /// ASCII-capable layout, as macOS does for common command shortcuts.
    static func semanticCharacter(for event: NSEvent) -> String? {
        if let direct = directCharacter(for: event), isSingleASCIICharacter(direct) {
            return direct
        }
        if let fallback = character(for: UInt32(event.keyCode), usingASCIICapableLayout: true),
           let normalized = normalize(fallback) {
            return normalized
        }
        return directCharacter(for: event)
    }

    /// Candidate characters for modifier-free tool shortcuts. The native
    /// character wins; the ASCII fallback lets Latin defaults keep working
    /// while a Cyrillic, Arabic, or other non-Latin input source is active.
    static func toolCharacters(for event: NSEvent) -> [String] {
        var result: [String] = []
        if let direct = directCharacter(for: event) { result.append(direct) }
        if !result.contains(where: { isSingleASCIICharacter($0) }),
           let fallback = character(for: UInt32(event.keyCode), usingASCIICapableLayout: true),
           let normalized = normalize(fallback),
           !result.contains(normalized) {
            result.append(normalized)
        }
        return result
    }

    static func currentLayoutCharacter(for keyCode: UInt32) -> String? {
        character(for: keyCode, usingASCIICapableLayout: false)
    }

    private static func directCharacter(for event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers else { return nil }
        return normalize(characters)
    }

    private static func normalize(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.count == 1,
              normalized != "\0",
              normalized.rangeOfCharacter(from: .controlCharacters) == nil,
              normalized.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return normalized
    }

    private static func isSingleASCIICharacter(_ value: String) -> Bool {
        value.unicodeScalars.count == 1 && value.unicodeScalars.first?.isASCII == true
    }

    private static func character(for keyCode: UInt32, usingASCIICapableLayout: Bool) -> String? {
        let source: TISInputSource?
        if usingASCIICapableLayout {
            source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        } else {
            source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        }
        guard let source,
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status: OSStatus = layoutData.withUnsafeBytes { bytes in
            guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                pointer,
                UInt16(keyCode),
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return normalize(String(utf16CodeUnits: characters, count: length))
    }
}
