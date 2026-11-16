import AppKit

/// Text editing that happens in a window other than the one handling a key
/// equivalent: the hex field in a color picker popover, the emoji search
/// field, both shown over the capture overlay or an editor.
///
/// While such a popover is key, AppKit still offers Command shortcuts to the
/// main window behind it. Handling them there would copy the capture on ⌘C,
/// paste annotations on ⌘V or undo the last annotation on ⌘Z while the user
/// is typing a color code. Canvas windows step aside instead, so the Edit
/// menu sends cut, copy, paste and select all to the focused field.
enum ForeignTextEditing {
    /// True while an editable text view in the key window, which isn't
    /// `window`, has keyboard focus.
    static func isActive(outside window: NSWindow?) -> Bool {
        guard let key = NSApp.keyWindow, key !== window,
              let textView = key.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }

    /// What a canvas window returns from `performKeyEquivalent` while
    /// `isActive`: undo and redo are swallowed (the field has nothing to
    /// undo, and the canvas behind it must not change), everything else is
    /// left to the Edit menu and the key window.
    static func keyEquivalentResult(for event: NSEvent) -> Bool {
        EditorCommandShortcutManager.action(for: event) != nil
    }
}
