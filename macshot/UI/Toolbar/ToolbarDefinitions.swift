import Cocoa

extension Notification.Name {
    static let toolbarColorsDidChange = Notification.Name("toolbarColorsDidChange")
}

// Toolbar buttons drawn directly in the OverlayView (not a separate window).
// This avoids window-level z-order issues and matches Flameshot's look.

enum ToolbarButtonAction {
    case tool(AnnotationTool)
    case color
    case sizeDisplay
    case undo
    case redo
    case copy
    case save
    case pin
    case ocr
    case autoRedact
    case beautify
    case beautifyStyle
    case cancel
    case moveSelection
    case delayCapture
    case upload
    case share
    case removeBackground
    case invertColors
    case loupe
    case translate
    case record  // enters recording mode (shows recording toolbar)
    case startRecord  // actually starts recording
    case stopRecord
    case mouseHighlight
    case systemAudio
    case micAudio
    case detach
    case scrollCapture
    case addCapture  // editor only: capture a new region and append to the canvas
    case recordSettings  // recording mode: open format/FPS/when-done popover
    case effects  // image effects (CIFilter adjustments + presets)
}

struct ToolbarButton {
    let action: ToolbarButtonAction
    let sfSymbol: String?
    let label: String?
    let tooltip: String
    var rect: NSRect = .zero
    var isSelected: Bool = false
    var isHovered: Bool = false
    var isPressed: Bool = false
    var tintColor: NSColor = ToolbarLayout.iconColor
    var bgColor: NSColor? = nil  // for color swatches
    var hasContextMenu: Bool = false  // draw small corner triangle to indicate right-click options
}

class ToolbarLayout {

    // Default theme colors (Flameshot purple style)
    static let defaultAccentColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
    static let defaultIconColor = NSColor.white

    // User-customizable colors — read from UserDefaults with defaults matching the original look
    static var accentColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarAccentColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultAccentColor
    }
    static var iconColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarIconColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultIconColor
    }
    static var handleColor: NSColor { accentColor }
    static var bgColor = NSColor(white: 0.12, alpha: 1.0)
    static var selectedBg: NSColor { accentColor }
    static let buttonSize: CGFloat = 32
    static let buttonSpacing: CGFloat = 2
    static let toolbarPadding: CGFloat = 4
    static let cornerRadius: CGFloat = 6

    /// Save accent color to UserDefaults.
    static func saveAccentColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarAccentColor")
        }
    }

    /// Save icon color to UserDefaults.
    static func saveIconColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarIconColor")
        }
    }

    /// Reset both colors to defaults.
    static func resetColors() {
        UserDefaults.standard.removeObject(forKey: "toolbarAccentColor")
        UserDefaults.standard.removeObject(forKey: "toolbarIconColor")
    }

    // Bottom toolbar items (drawing tools + colors + undo/redo + processing actions)
    static func bottomButtons(
        selectedTool: AnnotationTool, selectedColor: NSColor, beautifyEnabled: Bool = false,
        beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false, isRecording: Bool = false,
        effectsActive: Bool = false
    ) -> [ToolbarButton] {
        // Hide the bottom bar entirely while recording
        if isRecording { return [] }

        var buttons: [ToolbarButton] = []

        // Get enabled tools from UserDefaults — migrate: only add tools that are brand-new.
        // Track introduced tools in `knownToolRawValues` so user-disabled tools are never re-enabled.
        let allKnownToolRawValues = AnnotationTool.allCases
            .filter { $0 != .select && $0 != .translateOverlay }
            .map { $0.rawValue }
        var enabledRawValues = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]
        let knownToolRawValues = UserDefaults.standard.array(forKey: "knownToolRawValues") as? [Int]
        let newToolRaws = allKnownToolRawValues.filter { !(knownToolRawValues ?? []).contains($0) }
        if !newToolRaws.isEmpty {
            if enabledRawValues == nil {
                // Fresh install: enable everything.
                enabledRawValues = allKnownToolRawValues
            } else if knownToolRawValues == nil {
                // Upgrading from a version before knownToolRawValues tracking was added.
                // Respect the existing enabledTools as-is; just mark all current tools as known.
            } else {
                // Normal upgrade: new tools introduced — add them enabled by default.
                enabledRawValues = (enabledRawValues! + newToolRaws)
            }
            UserDefaults.standard.set(enabledRawValues, forKey: "enabledTools")
            UserDefaults.standard.set(allKnownToolRawValues, forKey: "knownToolRawValues")
        }

        let tools: [(AnnotationTool, String, String)] = [
            (.pencil, "scribble", "Pencil (Draw)"),
            (.line, "line.diagonal", "Line"),
            (.arrow, "arrow.up.right", "Arrow"),
            (.rectangle, "rectangle", "Rectangle"),
            (.ellipse, "oval", "Ellipse"),
            (.marker, "paintbrush.pointed.fill", "Marker"),
            (.text, "textformat", "Text"),
            (.number, "1.circle.fill", "Number"),
            (.pixelate, "squareshape.split.2x2", "Censor (Pixelate / Blur / Solid)"),
            (.loupe, "magnifyingglass", "Magnify (Loupe)"),
            (.stamp, "face.smiling", "Stamp / Emoji"),
            (.colorSampler, "eyedropper", "Color Picker"),
            (.measure, "ruler", "Measure (px)"),
        ]

        for (tool, symbol, tip) in tools {
            // Skip if disabled
            if let enabledRawValues = enabledRawValues, !enabledRawValues.contains(tool.rawValue) {
                continue
            }
            var btn = ToolbarButton(action: .tool(tool), sfSymbol: symbol, label: nil, tooltip: tip)
            btn.isSelected = (tool == selectedTool)
            switch tool {
            case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe:
                break  // options shown in the tool options row, not via right-click
            default:
                break
            }
            buttons.append(btn)
        }

        // Color button
        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, label: nil, tooltip: "Color")
        colorBtn.bgColor = selectedColor
        buttons.append(colorBtn)

        // Undo / Redo
        buttons.append(
            ToolbarButton(
                action: .undo, sfSymbol: "arrow.uturn.backward", label: nil, tooltip: "Undo"))
        buttons.append(
            ToolbarButton(
                action: .redo, sfSymbol: "arrow.uturn.forward", label: nil, tooltip: "Redo"))

        // Processing actions (moved from right bar) — respect enabledActions toggles
        let enabledActions = UserDefaults.standard.array(forKey: "enabledActions") as? [Int]
        func actionEnabled(_ tag: Int) -> Bool {
            return enabledActions == nil || enabledActions!.contains(tag)
        }

        // Auto-redact moved to blur/pixelate options row

        // Invert colors (tag 1011)
        if !isRecording && actionEnabled(1011) {
            buttons.append(
                ToolbarButton(
                    action: .invertColors, sfSymbol: "circle.righthalf.filled.inverse", label: nil,
                    tooltip: "Invert Colors"))
        }

        if !isRecording && actionEnabled(1013) {
            var effectsBtn = ToolbarButton(
                action: .effects, sfSymbol: "slider.horizontal.3", label: nil,
                tooltip: "Adjust")
            if effectsActive {
                effectsBtn.tintColor = NSColor(
                    calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            buttons.append(effectsBtn)
        }

        if !isRecording && actionEnabled(1004) {
            var beautifyBtn = ToolbarButton(
                action: .beautify, sfSymbol: "sparkles", label: nil, tooltip: "Beautify")
            if beautifyEnabled {
                beautifyBtn.tintColor = NSColor(
                    calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            buttons.append(beautifyBtn)
        }

        if !isRecording, #available(macOS 14.0, *), actionEnabled(1005) {
            buttons.append(
                ToolbarButton(
                    action: .removeBackground, sfSymbol: "person.crop.circle.dashed", label: nil,
                    tooltip: "Remove Background"))
        }

        return buttons
    }

    // Right toolbar items (output actions + cancel + delay)
    static func rightButtons(
        beautifyEnabled: Bool = false, beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false,
        translateEnabled: Bool = false, isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []

        // Recording setup mode — show start button + toggles, then return early
        if isRecording {
            var startBtn = ToolbarButton(
                action: .startRecord, sfSymbol: "record.circle", label: nil,
                tooltip: "Start Recording")
            startBtn.tintColor = .systemRed
            buttons.append(startBtn)

            // Stop/cancel button to exit recording mode without starting
            buttons.append(
                ToolbarButton(action: .stopRecord, sfSymbol: "xmark", label: nil, tooltip: "Cancel Recording"))

            let mouseHighlightOn = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            var mouseBtn = ToolbarButton(
                action: .mouseHighlight, sfSymbol: "cursorarrow.click.2", label: nil,
                tooltip: "Highlight Mouse Clicks")
            mouseBtn.isSelected = mouseHighlightOn
            buttons.append(mouseBtn)

            let audioOn = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            var audioBtn = ToolbarButton(
                action: .systemAudio, sfSymbol: audioOn ? "speaker.wave.2.fill" : "speaker.slash",
                label: nil, tooltip: "Record System Audio")
            audioBtn.isSelected = audioOn
            buttons.append(audioBtn)

            let micOn = UserDefaults.standard.bool(forKey: "recordMicAudio")
            var micBtn = ToolbarButton(
                action: .micAudio, sfSymbol: micOn ? "mic.fill" : "mic.slash", label: nil,
                tooltip: "Record Microphone")
            micBtn.isSelected = micOn
            buttons.append(micBtn)

            // Recording settings gear
            buttons.append(
                ToolbarButton(
                    action: .recordSettings, sfSymbol: "gearshape", label: nil,
                    tooltip: "Recording Settings"))

            // Allow moving the selection before starting
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    label: nil, tooltip: "Move Selection"))

            return buttons
        }

        let allKnownActionTags: [Int] = [
            1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013,
        ]
        // Migrate: only add action tags that are brand-new (never seen before).
        // knownActionTags tracks which tags have been introduced so user-disabled tags are
        // never silently re-enabled when future versions add new action tags.
        var enabledActions = UserDefaults.standard.array(forKey: "enabledActions") as? [Int]
        let knownActionTags = UserDefaults.standard.array(forKey: "knownActionTags") as? [Int]
        let newTags = allKnownActionTags.filter { !(knownActionTags ?? []).contains($0) }
        if !newTags.isEmpty {
            if enabledActions == nil {
                // Fresh install: enable everything.
                enabledActions = allKnownActionTags
            } else if knownActionTags == nil {
                // Upgrading from a version before knownActionTags tracking was added.
                // Respect existing enabledActions as-is; just mark all current tags as known.
            } else {
                // Normal upgrade path: newly added tags — enable by default.
                enabledActions = (enabledActions! + newTags)
            }
            UserDefaults.standard.set(enabledActions, forKey: "enabledActions")
            UserDefaults.standard.set(allKnownActionTags, forKey: "knownActionTags")
        }
        func actionEnabled(_ tag: Int) -> Bool {
            return enabledActions == nil || enabledActions!.contains(tag)
        }

        // Cancel, move-selection, editor — not shown in editor window
        if !isEditorMode {
            buttons.append(
                ToolbarButton(action: .cancel, sfSymbol: "xmark", label: nil, tooltip: "Cancel"))
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    label: nil, tooltip: "Move Selection"))
            buttons.append(
                ToolbarButton(
                    action: .detach, sfSymbol: "arrow.up.forward.app", label: nil,
                    tooltip: "Open in Editor Window"))
        }
        // Copy and save are always present
        buttons.append(
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", label: nil, tooltip: "Copy"))
        var saveBtn = ToolbarButton(
            action: .save, sfSymbol: "square.and.arrow.down.fill", label: nil,
            tooltip:
                "Save to \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
        )
        saveBtn.hasContextMenu = true
        buttons.append(saveBtn)

        // Share (tag 1012)
        if actionEnabled(1012) {
            buttons.append(
                ToolbarButton(
                    action: .share, sfSymbol: "square.and.arrow.up", label: nil, tooltip: "Share"))
        }

        // Upload (tag 1001)
        if actionEnabled(1001) {
            var uploadBtn = ToolbarButton(
                action: .upload, sfSymbol: "icloud.and.arrow.up", label: nil, tooltip: "Upload")
            uploadBtn.hasContextMenu = true
            buttons.append(uploadBtn)
        }

        // Pin (tag 1002)
        if actionEnabled(1002) {
            buttons.append(
                ToolbarButton(action: .pin, sfSymbol: "pin.fill", label: nil, tooltip: "Pin"))
        }

        // OCR (tag 1003)
        if actionEnabled(1003) {
            buttons.append(
                ToolbarButton(
                    action: .ocr, sfSymbol: "doc.text.viewfinder", label: nil, tooltip: "OCR Text"))
        }

        // Translate (tag 1008)
        if actionEnabled(1008) {
            var translateBtn = ToolbarButton(
                action: .translate, sfSymbol: "translate", label: nil, tooltip: "Translate")
            translateBtn.isSelected = translateEnabled
            translateBtn.hasContextMenu = true
            buttons.append(translateBtn)
        }

        // Scroll Capture (tag 1010) — hidden when recording or in editor mode
        if !isRecording && !isEditorMode && actionEnabled(1010) {
            buttons.append(
                ToolbarButton(
                    action: .scrollCapture, sfSymbol: "scroll", label: nil,
                    tooltip: "Scroll Capture"))
        }

        // Record (tag 1009) — hidden in editor mode. Right-click for options.
        if !isEditorMode && actionEnabled(1009) {
            var recordBtn = ToolbarButton(
                action: .record, sfSymbol: "video.fill", label: nil, tooltip: "Record")
            recordBtn.tintColor = ToolbarLayout.iconColor
            buttons.append(recordBtn)
        }

        return buttons
    }

    // Layout bottom toolbar rects    // Layout bottom toolbar inside the selection (for full-screen selections)    // Layout right toolbar inside the selection (for full-screen selections)    // Layout right toolbar rects    // Icon cache: [symbolName: [isSelected: tintedImage]]
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
}
