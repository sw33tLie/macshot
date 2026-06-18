import Cocoa

/// Manages single-key overlay/editor tool shortcuts.
/// Stored in UserDefaults as a dictionary of action ID → key character.
/// An empty string means the shortcut is disabled (None).
enum ToolShortcutManager {

    /// All configurable overlay shortcut actions with their default keys.
    enum Action: String, CaseIterable {
        case pencil
        case arrow
        case line
        case rectangle
        case ellipse
        case marker
        case text
        case number
        case censor       // pixelate/blur tool
        case highlight    // spotlight tool
        case colorSampler
        case stamp
        case measure
        case loupe
        case openInEditor
        case pin
        case upload
        case copy
        case save
        case ocr
        case scrollCapture
        case beautify
        case invertColors
        case removeBackground
        case translate
        case undo
        case redo

        var label: String {
            switch self {
            case .pencil: return L("Pencil")
            case .arrow: return L("Arrow")
            case .line: return L("Line")
            case .rectangle: return L("Rectangle")
            case .ellipse: return L("Ellipse")
            case .marker: return L("Marker")
            case .text: return L("Text")
            case .number: return L("Number")
            case .censor: return L("Censor")
            case .highlight: return L("Highlight")
            case .colorSampler: return L("Color Picker")
            case .stamp: return L("Stamp")
            case .measure: return L("Measure")
            case .loupe: return L("Loupe")
            case .openInEditor: return L("Open in Editor")
            case .pin: return L("Pin")
            case .upload: return L("Upload")
            case .copy: return L("Copy")
            case .save: return L("Save")
            case .ocr: return L("OCR & QR")
            case .scrollCapture: return L("Scroll Capture")
            case .beautify: return L("Beautify")
            case .invertColors: return L("Invert Colors")
            case .removeBackground: return L("Remove Background")
            case .translate: return L("Translate")
            case .undo: return L("Undo")
            case .redo: return L("Redo")
            }
        }

        var defaultKey: String {
            switch self {
            case .pencil: return "p"
            case .arrow: return "a"
            case .line: return "l"
            case .rectangle: return "r"
            case .ellipse: return "o"
            case .marker: return "m"
            case .text: return "t"
            case .number: return "n"
            case .censor: return "b"
            case .highlight: return "h"
            case .colorSampler: return "i"
            case .stamp: return "g"
            case .measure: return ""
            case .loupe: return ""
            case .openInEditor: return "e"
            case .pin: return "f"
            case .upload: return "u"
            case .copy: return ""
            case .save: return ""
            case .ocr: return ""
            case .scrollCapture: return ""
            case .beautify: return ""
            case .invertColors: return ""
            case .removeBackground: return ""
            case .translate: return ""
            case .undo: return ""
            case .redo: return ""
            }
        }
    }

    private static let defaultsKey = "overlayToolShortcuts"

    /// Get the key character for an action. Empty string = disabled.
    static func key(for action: Action) -> String {
        if let dict = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String],
           let key = dict[action.rawValue] {
            return key
        }
        return action.defaultKey
    }

    /// Set the key character for an action. Pass empty string to disable.
    static func setKey(_ key: String, for action: Action) {
        var dict = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
        dict[action.rawValue] = key
        UserDefaults.standard.set(dict, forKey: defaultsKey)
        // Rebuild the lookup cache
        _cachedLookup = nil
    }

    /// Build a reverse lookup: character → ToolbarButtonAction.
    /// Cached and invalidated when shortcuts change.
    static func lookupAction(for character: String) -> ToolbarButtonAction? {
        if _cachedLookup == nil { rebuildCache() }
        return _cachedLookup?[character]
    }

    private static var _cachedLookup: [String: ToolbarButtonAction]?

    private static func rebuildCache() {
        var lookup: [String: ToolbarButtonAction] = [:]
        for action in Action.allCases {
            let k = key(for: action)
            guard !k.isEmpty else { continue }
            switch action {
            case .pencil: lookup[k] = .tool(.pencil)
            case .arrow: lookup[k] = .tool(.arrow)
            case .line: lookup[k] = .tool(.line)
            case .rectangle: lookup[k] = .tool(.rectangle)
            case .ellipse: lookup[k] = .tool(.ellipse)
            case .marker: lookup[k] = .tool(.marker)
            case .text: lookup[k] = .tool(.text)
            case .number: lookup[k] = .tool(.number)
            case .censor: lookup[k] = .tool(.pixelate)
            case .highlight: lookup[k] = .tool(.highlight)
            case .colorSampler: lookup[k] = .tool(.colorSampler)
            case .stamp: lookup[k] = .tool(.stamp)
            case .measure: lookup[k] = .tool(.measure)
            case .loupe: lookup[k] = .tool(.loupe)
            case .openInEditor: lookup[k] = .detach
            case .pin: lookup[k] = .pin
            case .upload: lookup[k] = .upload
            case .copy: lookup[k] = .copy
            case .save: lookup[k] = .save
            case .ocr: lookup[k] = .ocr
            case .scrollCapture: lookup[k] = .scrollCapture
            case .beautify: lookup[k] = .beautify
            case .invertColors: lookup[k] = .invertColors
            case .removeBackground: lookup[k] = .removeBackground
            case .translate: lookup[k] = .translate
            case .undo: lookup[k] = .undo
            case .redo: lookup[k] = .redo
            }
        }
        _cachedLookup = lookup
    }

    /// Display string for a key (for UI).
    static func displayString(for action: Action) -> String {
        let k = key(for: action)
        return k.isEmpty ? L("None") : k.uppercased()
    }

    /// Raw configured shortcut text for toolbar tooltip suffixes.
    /// Empty string means no shortcut should be shown.
    static func tooltipShortcut(for toolbarAction: ToolbarButtonAction) -> String? {
        let action: Action?
        switch toolbarAction {
        case .tool(let tool):
            switch tool {
            case .pencil: action = .pencil
            case .arrow: action = .arrow
            case .line: action = .line
            case .rectangle: action = .rectangle
            case .ellipse: action = .ellipse
            case .marker: action = .marker
            case .text: action = .text
            case .number: action = .number
            case .pixelate: action = .censor
            case .highlight: action = .highlight
            case .colorSampler: action = .colorSampler
            case .stamp: action = .stamp
            case .measure: action = .measure
            case .loupe: action = .loupe
            default: action = nil
            }
        case .detach: action = .openInEditor
        case .pin: action = .pin
        case .upload: action = .upload
        case .copy: action = .copy
        case .save: action = .save
        case .ocr: action = .ocr
        case .scrollCapture: action = .scrollCapture
        case .beautify: action = .beautify
        case .invertColors: action = .invertColors
        case .removeBackground: action = .removeBackground
        case .translate: action = .translate
        case .undo: action = .undo
        case .redo: action = .redo
        case .loupe: action = .loupe
        default: action = nil
        }

        guard let action else { return nil }
        let shortcut = key(for: action).trimmingCharacters(in: .whitespacesAndNewlines)
        return shortcut.isEmpty ? nil : shortcut
    }
}
