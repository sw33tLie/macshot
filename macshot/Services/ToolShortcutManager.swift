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
        case colorSampler
        case stamp
        case measure
        case loupe
        case openInEditor

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
            case .colorSampler: return L("Color Picker")
            case .stamp: return L("Stamp")
            case .measure: return L("Measure")
            case .loupe: return L("Loupe")
            case .openInEditor: return L("Open in Editor")
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
            case .colorSampler: return "i"
            case .stamp: return "g"
            case .measure: return ""
            case .loupe: return ""
            case .openInEditor: return "e"
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
            case .colorSampler: lookup[k] = .tool(.colorSampler)
            case .stamp: lookup[k] = .tool(.stamp)
            case .measure: lookup[k] = .tool(.measure)
            case .loupe: lookup[k] = .tool(.loupe)
            case .openInEditor: lookup[k] = .detach
            }
        }
        _cachedLookup = lookup
    }

    /// Invalidate cache (call when shortcuts change).
    static func invalidateCache() {
        _cachedLookup = nil
    }

    /// Display string for a key (for UI).
    static func displayString(for action: Action) -> String {
        let k = key(for: action)
        return k.isEmpty ? L("None") : k.uppercased()
    }
}
