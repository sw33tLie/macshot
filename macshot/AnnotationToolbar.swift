import Cocoa

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
    case removeBackground
    case invertColors
    case loupe
    case translate
    case record          // enters recording mode (shows recording toolbar)
    case startRecord     // actually starts recording
    case stopRecord
    case annotationMode
    case mouseHighlight
    case systemAudio
    case detach
    case scrollCapture
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
    var tintColor: NSColor = .white
    var bgColor: NSColor? = nil  // for color swatches
    var hasContextMenu: Bool = false  // draw small corner triangle to indicate right-click options
}

class ToolbarLayout {

    // Theme colors matching Flameshot purple style
    static let accentColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
    static let handleColor = accentColor
    static let bgColor = NSColor(white: 0.12, alpha: 0.92)
    static let selectedBg = accentColor
    static let buttonSize: CGFloat = 32
    static let buttonSpacing: CGFloat = 2
    static let toolbarPadding: CGFloat = 4
    static let cornerRadius: CGFloat = 6

    // Bottom toolbar items (drawing tools + colors + undo/redo + processing actions)
    static func bottomButtons(selectedTool: AnnotationTool, selectedColor: NSColor, beautifyEnabled: Bool = false, beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false, isRecording: Bool = false, isAnnotating: Bool = false) -> [ToolbarButton] {
        // Hide the bottom bar entirely while recording outside annotation mode
        if isRecording && !isAnnotating { return [] }

        var buttons: [ToolbarButton] = []

        // Move tool always present (disabled look when no annotations)
        var selectBtn = ToolbarButton(action: .tool(.select), sfSymbol: "cursor.rays", label: nil, tooltip: "Select & Edit")
        selectBtn.isSelected = (selectedTool == .select)
        if !hasAnnotations {
            selectBtn.tintColor = NSColor.white.withAlphaComponent(0.3)
        }
        buttons.append(selectBtn)

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
            (.pencil,          "scribble",                "Pencil (Draw)"),
            (.line,            "line.diagonal",            "Line"),
            (.arrow,           "arrow.up.right",           "Arrow"),
            (.rectangle,       "rectangle",                "Rectangle"),
            (.ellipse,         "oval",                     "Ellipse"),
            (.marker,          "paintbrush.pointed.fill",  "Marker"),
            (.text,            "textformat",               "Text"),
            (.number,          "1.circle.fill",             "Number"),
            (.pixelate,        "squareshape.split.2x2",    "Pixelate"),
            (.blur,            "aqi.medium",               "Blur"),
            (.loupe,           "magnifyingglass",          "Magnify (Loupe)"),
            (.stamp,           "face.smiling",             "Stamp / Emoji"),
            (.colorSampler,    "eyedropper",               "Color Picker"),
            (.measure,         "ruler",                    "Measure (px)"),
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
        buttons.append(ToolbarButton(action: .undo, sfSymbol: "arrow.uturn.backward", label: nil, tooltip: "Undo"))
        buttons.append(ToolbarButton(action: .redo, sfSymbol: "arrow.uturn.forward", label: nil, tooltip: "Redo"))

        // Processing actions (moved from right bar) — respect enabledActions toggles
        let enabledActions = UserDefaults.standard.array(forKey: "enabledActions") as? [Int]
        func actionEnabled(_ tag: Int) -> Bool {
            return enabledActions == nil || enabledActions!.contains(tag)
        }

        // Auto-redact moved to blur/pixelate options row

        // Invert colors (tag 1011)
        if !isRecording && actionEnabled(1011) {
            buttons.append(ToolbarButton(action: .invertColors, sfSymbol: "circle.righthalf.filled.inverse", label: nil, tooltip: "Invert Colors"))
        }

        if !isRecording && actionEnabled(1004) {
            var beautifyBtn = ToolbarButton(action: .beautify, sfSymbol: "sparkles", label: nil, tooltip: "Beautify")
            if beautifyEnabled {
                beautifyBtn.tintColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            buttons.append(beautifyBtn)
        }

        if !isRecording, #available(macOS 14.0, *), actionEnabled(1005) {
            buttons.append(ToolbarButton(action: .removeBackground, sfSymbol: "person.crop.circle.dashed", label: nil, tooltip: "Remove Background"))
        }


        return buttons
    }

    // Right toolbar items (output actions + cancel + delay)
    static func rightButtons(delaySeconds: Int = 0, beautifyEnabled: Bool = false, beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false, translateEnabled: Bool = false, isRecording: Bool = false, isCapturingVideo: Bool = false, isAnnotating: Bool = false, isDetached: Bool = false) -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []

        // If in recording mode (toolbar shown), show recording controls
        if isRecording {
            if isCapturingVideo {
                // Recording is active — show stop button
                var stopBtn = ToolbarButton(action: .stopRecord, sfSymbol: "stop.circle.fill", label: nil, tooltip: "Stop Recording")
                stopBtn.tintColor = .systemRed
                buttons.append(stopBtn)
            } else {
                // Recording mode but not started — show red record button
                var startBtn = ToolbarButton(action: .startRecord, sfSymbol: "record.circle", label: nil, tooltip: "Start Recording")
                startBtn.tintColor = .systemRed
                buttons.append(startBtn)
            }

            var annotateBtn = ToolbarButton(action: .annotationMode, sfSymbol: "pencil.tip", label: nil, tooltip: isAnnotating ? "Stop Annotating" : "Annotate (draw on screen)")
            annotateBtn.tintColor = .white
            annotateBtn.isSelected = isAnnotating
            buttons.append(annotateBtn)

            let mouseHighlightOn = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            var mouseBtn = ToolbarButton(action: .mouseHighlight, sfSymbol: "cursorarrow.click.2", label: nil, tooltip: "Highlight Mouse Clicks")
            mouseBtn.isSelected = mouseHighlightOn
            buttons.append(mouseBtn)

            let audioOn = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            var audioBtn = ToolbarButton(action: .systemAudio, sfSymbol: audioOn ? "speaker.wave.2.fill" : "speaker.slash", label: nil, tooltip: "Record System Audio")
            audioBtn.isSelected = audioOn
            buttons.append(audioBtn)

            return buttons
        }

        let allKnownActionTags: [Int] = [1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 1011]
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
        if !isDetached {
            buttons.append(ToolbarButton(action: .cancel, sfSymbol: "xmark", label: nil, tooltip: "Cancel"))
            buttons.append(ToolbarButton(action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right", label: nil, tooltip: "Move Selection"))
            buttons.append(ToolbarButton(action: .detach, sfSymbol: "arrow.up.forward.app", label: nil, tooltip: "Open in Editor Window"))
        }
        // Delay capture (tag 1007) — hidden when detached
        if !isDetached && actionEnabled(1007) {
            let delaySymbol: String
            let delayTooltip: String
            switch delaySeconds {
            case 1: delaySymbol = "1.circle.fill"; delayTooltip = "Delay: 1s"
            case 2: delaySymbol = "2.circle.fill"; delayTooltip = "Delay: 2s"
            case 3: delaySymbol = "3.circle.fill"; delayTooltip = "Delay: 3s"
            case 5: delaySymbol = "5.circle.fill"; delayTooltip = "Delay: 5s"
            case 10: delaySymbol = "10.circle.fill"; delayTooltip = "Delay: 10s"
            case 30: delaySymbol = "timer"; delayTooltip = "Delay: 30s"
            default: delaySymbol = "timer"; delayTooltip = "Delay capture"
            }
            var delayBtn = ToolbarButton(action: .delayCapture, sfSymbol: delaySymbol, label: nil, tooltip: delayTooltip)
            delayBtn.hasContextMenu = true
            if delaySeconds > 0 { delayBtn.isSelected = true }
            buttons.append(delayBtn)
        }

        // Copy and save are always present
        buttons.append(ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", label: nil, tooltip: "Copy"))
        buttons.append(ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down.fill", label: nil, tooltip: "Save"))

        // Upload (tag 1001)
        if actionEnabled(1001) {
            var uploadBtn = ToolbarButton(action: .upload, sfSymbol: "icloud.and.arrow.up", label: nil, tooltip: "Upload")
            uploadBtn.hasContextMenu = true
            buttons.append(uploadBtn)
        }

        // Pin (tag 1002)
        if actionEnabled(1002) {
            buttons.append(ToolbarButton(action: .pin, sfSymbol: "pin.fill", label: nil, tooltip: "Pin"))
        }

        // OCR (tag 1003)
        if actionEnabled(1003) {
            buttons.append(ToolbarButton(action: .ocr, sfSymbol: "doc.text.viewfinder", label: nil, tooltip: "OCR Text"))
        }

        // Translate (tag 1008)
        if actionEnabled(1008) {
            var translateBtn = ToolbarButton(action: .translate, sfSymbol: "translate", label: nil, tooltip: "Translate")
            translateBtn.isSelected = translateEnabled
            translateBtn.hasContextMenu = true
            buttons.append(translateBtn)
        }

        // Scroll Capture (tag 1010) — hidden when recording or detached
        if !isRecording && !isDetached && actionEnabled(1010) {
            buttons.append(ToolbarButton(action: .scrollCapture, sfSymbol: "scroll", label: nil, tooltip: "Scroll Capture"))
        }

        // Record (tag 1009) — hidden when detached. Right-click for options.
        if !isDetached && actionEnabled(1009) {
            var recordBtn = ToolbarButton(action: .record, sfSymbol: "video.fill", label: nil, tooltip: "Record")
            recordBtn.tintColor = .white
            buttons.append(recordBtn)
        }

        // Delay capture (hidden when detached) is handled above with tag 1007

        return buttons
    }

    // Layout bottom toolbar rects
    static func layoutBottom(buttons: inout [ToolbarButton], selectionRect: NSRect, viewBounds: NSRect) -> NSRect {
        let count = CGFloat(buttons.count)
        let totalWidth = count * buttonSize + (count - 1) * buttonSpacing + toolbarPadding * 2
        let totalHeight = buttonSize + toolbarPadding * 2

        var barX = selectionRect.midX - totalWidth / 2
        var barY = selectionRect.minY - totalHeight - 6

        // If below screen bottom, put above selection
        if barY < viewBounds.minY + 4 {
            barY = selectionRect.maxY + 6
        }

        // Clamp horizontal
        barX = max(viewBounds.minX + 4, min(barX, viewBounds.maxX - totalWidth - 4))

        let barRect = NSRect(x: barX, y: barY, width: totalWidth, height: totalHeight)

        var x = barRect.minX + toolbarPadding
        let y = barRect.minY + toolbarPadding

        for i in 0..<buttons.count {
            buttons[i].rect = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
            x += buttonSize + buttonSpacing
        }

        return barRect
    }

    // Layout bottom toolbar inside the selection (for full-screen selections)
    static func layoutBottomInside(buttons: inout [ToolbarButton], selectionRect: NSRect, viewBounds: NSRect) -> NSRect {
        let count = CGFloat(buttons.count)
        let totalWidth = count * buttonSize + (count - 1) * buttonSpacing + toolbarPadding * 2
        let totalHeight = buttonSize + toolbarPadding * 2

        var barX = selectionRect.midX - totalWidth / 2
        let barY = selectionRect.minY + 10  // inside, near bottom edge

        // Clamp horizontal
        barX = max(viewBounds.minX + 4, min(barX, viewBounds.maxX - totalWidth - 4))

        let barRect = NSRect(x: barX, y: barY, width: totalWidth, height: totalHeight)

        var x = barRect.minX + toolbarPadding
        let y = barRect.minY + toolbarPadding

        for i in 0..<buttons.count {
            buttons[i].rect = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
            x += buttonSize + buttonSpacing
        }

        return barRect
    }

    // Layout right toolbar inside the selection (for full-screen selections)
    static func layoutRightInside(buttons: inout [ToolbarButton], selectionRect: NSRect, viewBounds: NSRect, bottomBarRect: NSRect = .zero) -> NSRect {
        let count = CGFloat(buttons.count)
        let totalWidth = buttonSize + toolbarPadding * 2
        let totalHeight = count * buttonSize + (count - 1) * buttonSpacing + toolbarPadding * 2

        let barX = selectionRect.maxX - totalWidth - 10  // inside, near right edge
        var barY = selectionRect.maxY - totalHeight - 10  // near top-right

        // Clamp vertical first
        barY = max(viewBounds.minY + 4, min(barY, viewBounds.maxY - totalHeight - 4))

        // Avoid overlapping with bottom toolbar — regardless of X position.
        if bottomBarRect.width > 0 {
            let rightTop = barY + totalHeight
            let rightBot = barY
            let bbTop    = bottomBarRect.maxY
            let bbBot    = bottomBarRect.minY

            if bbBot > selectionRect.maxY - 2 && rightTop > bbBot - 4 {
                barY = bbBot - 4 - totalHeight
            } else if bbTop < selectionRect.minY + 2 && rightBot < bbTop + 4 {
                barY = bbTop + 4
            }
            barY = max(viewBounds.minY + 4, min(barY, viewBounds.maxY - totalHeight - 4))
        }

        let barRect = NSRect(x: barX, y: barY, width: totalWidth, height: totalHeight)

        let x = barRect.minX + toolbarPadding
        var y = barRect.maxY - toolbarPadding - buttonSize

        for i in 0..<buttons.count {
            buttons[i].rect = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
            y -= buttonSize + buttonSpacing
        }

        return barRect
    }

    // Layout right toolbar rects
    static func layoutRight(buttons: inout [ToolbarButton], selectionRect: NSRect, viewBounds: NSRect, bottomBarRect: NSRect = .zero) -> NSRect {
        let count = CGFloat(buttons.count)
        let totalWidth = buttonSize + toolbarPadding * 2
        let totalHeight = count * buttonSize + (count - 1) * buttonSpacing + toolbarPadding * 2

        // Determine horizontal position first (right or left of selection)
        var barX = selectionRect.maxX + 6
        if barX + totalWidth > viewBounds.maxX - 4 {
            barX = selectionRect.minX - totalWidth - 6
        }
        // Clamp horizontal to screen bounds
        barX = max(viewBounds.minX + 4, min(barX, viewBounds.maxX - totalWidth - 4))

        // Preferred vertical: top of right bar aligns with top of selection
        var barY = selectionRect.maxY - totalHeight

        // Clamp vertical to screen bounds
        barY = max(viewBounds.minY + 4, min(barY, viewBounds.maxY - totalHeight - 4))

        // Avoid overlapping with bottom toolbar — regardless of X position.
        // Check both directions: bottom bar can be above or below the selection.
        if bottomBarRect.width > 0 {
            let rightTop = barY + totalHeight   // top edge of right bar
            let rightBot = barY                 // bottom edge of right bar
            let bbTop    = bottomBarRect.maxY   // top edge of bottom bar
            let bbBot    = bottomBarRect.minY   // bottom edge of bottom bar

            // Bottom bar is above: right bar top must not exceed bottom bar's bottom
            if bbBot > selectionRect.maxY - 2 && rightTop > bbBot - 4 {
                barY = bbBot - 4 - totalHeight
            }
            // Bottom bar is below: right bar bottom must not go below bottom bar's top
            else if bbTop < selectionRect.minY + 2 && rightBot < bbTop + 4 {
                barY = bbTop + 4
            }
            // Clamp back to screen bounds after adjustment
            barY = max(viewBounds.minY + 4, min(barY, viewBounds.maxY - totalHeight - 4))
        }

        let barRect = NSRect(x: barX, y: barY, width: totalWidth, height: totalHeight)

        let x = barRect.minX + toolbarPadding
        var y = barRect.maxY - toolbarPadding - buttonSize

        for i in 0..<buttons.count {
            buttons[i].rect = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
            y -= buttonSize + buttonSpacing
        }

        return barRect
    }

    // Icon cache: [symbolName: [isSelected: tintedImage]]
    private static var iconCache: [String: [Bool: NSImage]] = [:]
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    static func clearIconCache() {
        iconCache.removeAll()
    }

    private static func tintedIconUncached(symbolName: String, tooltip: String, tint: NSColor) -> NSImage? {
        guard let baseImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?.withSymbolConfiguration(symbolConfig) else {
            return nil
        }
        let imgSize = baseImg.size
        let tintedImg = NSImage(size: imgSize, flipped: false) { rect in
            baseImg.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tintedImg
    }

    private static func tintedIcon(symbolName: String, tooltip: String, selected: Bool) -> NSImage? {
        if let cached = iconCache[symbolName]?[selected] {
            return cached
        }
        guard let baseImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?.withSymbolConfiguration(symbolConfig) else {
            return nil
        }
        let tint: NSColor = selected ? .white : .white.withAlphaComponent(0.85)
        let imgSize = baseImg.size
        let tintedImg = NSImage(size: imgSize, flipped: false) { rect in
            baseImg.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }

        if iconCache[symbolName] == nil {
            iconCache[symbolName] = [:]
        }
        iconCache[symbolName]![selected] = tintedImg
        return tintedImg
    }

    // Draw a toolbar background + buttons
    static func drawToolbar(barRect: NSRect, buttons: [ToolbarButton], selectionSize: NSSize?) {
        // Background
        bgColor.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        for btn in buttons {
            drawButton(btn, selectionSize: selectionSize)
        }
    }

    static func drawButton(_ btn: ToolbarButton, selectionSize: NSSize?) {
        let rect = btn.rect

        // Distinct background for Move Object button
        let isMoveButton: Bool
        if case .tool(let tool) = btn.action, tool == .select { isMoveButton = true } else { isMoveButton = false }

        // Selected highlight
        if btn.isPressed {
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        } else if btn.isSelected {
            selectedBg.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        } else if btn.isHovered {
            NSColor.white.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }

        // Color swatch
        if let bgColor = btn.bgColor {
            let swatchRect = rect.insetBy(dx: 6, dy: 6)
            bgColor.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3).fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let border = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
            border.lineWidth = 1
            border.stroke()
            return
        }

        // Size display
        if case .sizeDisplay = btn.action, let size = selectionSize {
            let text = "\(Int(size.width))\n\(Int(size.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let strSize = str.size()
            let drawPoint = NSPoint(x: rect.midX - strSize.width / 2, y: rect.midY - strSize.height / 2)
            str.draw(at: drawPoint)
            return
        }

        // SF Symbol icon (cached for default tint, uncached for custom)
        if let symbolName = btn.sfSymbol {
            let customTint = btn.tintColor != .white
            let img: NSImage? = customTint
                ? tintedIconUncached(symbolName: symbolName, tooltip: btn.tooltip, tint: btn.tintColor)
                : tintedIcon(symbolName: symbolName, tooltip: btn.tooltip, selected: btn.isSelected)
            if let img = img {
                let imgSize = img.size
                let imgRect = NSRect(
                    x: rect.midX - imgSize.width / 2,
                    y: rect.midY - imgSize.height / 2,
                    width: imgSize.width,
                    height: imgSize.height
                )
                img.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            } else if let label = btn.label ?? btn.tooltip.first.map({ String($0) }) {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: NSColor.white,
                ]
                let str = label as NSString
                let size = str.size(withAttributes: attrs)
                str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            }
        }

        // Right-click context menu indicator (small bottom-right triangle)
        if btn.hasContextMenu {
            let triSize: CGFloat = 4.5
            let tx = rect.maxX - 2
            let ty = rect.minY + 2
            let triPath = NSBezierPath()
            triPath.move(to: NSPoint(x: tx - triSize, y: ty))
            triPath.line(to: NSPoint(x: tx, y: ty + triSize))
            triPath.line(to: NSPoint(x: tx, y: ty))
            triPath.close()
            NSColor.white.withAlphaComponent(0.6).setFill()
            triPath.fill()
        }
    }

    // Hit test: returns action if point is in any button
    static func hitTest(point: NSPoint, buttons: [ToolbarButton]) -> ToolbarButtonAction? {
        for btn in buttons {
            if btn.rect.contains(point) {
                return btn.action
            }
        }
        return nil
    }

    static func hitTestBar(point: NSPoint, barRect: NSRect) -> Bool {
        return barRect.contains(point)
    }
}
