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
}

struct ToolbarButton {
    let action: ToolbarButtonAction
    let sfSymbol: String?
    let label: String?
    let tooltip: String
    var rect: NSRect = .zero
    var isSelected: Bool = false
    var isHovered: Bool = false
    var tintColor: NSColor = .white
    var bgColor: NSColor? = nil  // for color swatches
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

    // Bottom toolbar items (drawing tools + colors + undo/redo + size)
    static func bottomButtons(selectedTool: AnnotationTool, selectedColor: NSColor, beautifyEnabled: Bool = false, beautifyStyleIndex: Int = 0) -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []

        let tools: [(AnnotationTool, String, String)] = [
            (.pencil,          "scribble",                "Pencil (Draw)"),
            (.line,            "line.diagonal",            "Line"),
            (.arrow,           "arrow.up.right",           "Arrow"),
            (.rectangle,       "rectangle",                "Rectangle"),
            (.filledRectangle, "rectangle.fill",           "Filled Rect"),
            (.ellipse,         "oval",                     "Ellipse"),
            (.marker,          "paintbrush.pointed.fill",  "Marker"),
            (.text,            "character.textbox",         "Text"),
            (.number,          "1.circle.fill",             "Number"),
            (.pixelate,        "squareshape.split.2x2",    "Pixelate"),
            (.blur,            "aqi.medium",               "Blur"),
            (.measure,         "ruler",                    "Measure (px)"),
        ]

        for (tool, symbol, tip) in tools {
            var btn = ToolbarButton(action: .tool(tool), sfSymbol: symbol, label: nil, tooltip: tip)
            btn.isSelected = (tool == selectedTool)
            buttons.append(btn)
        }

        // Color button
        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, label: nil, tooltip: "Color")
        colorBtn.bgColor = selectedColor
        buttons.append(colorBtn)

        // Undo / Redo / Pin
        buttons.append(ToolbarButton(action: .undo, sfSymbol: "arrow.uturn.backward", label: nil, tooltip: "Undo"))
        buttons.append(ToolbarButton(action: .redo, sfSymbol: "arrow.uturn.forward", label: nil, tooltip: "Redo"))
        buttons.append(ToolbarButton(action: .pin, sfSymbol: "pin.fill", label: nil, tooltip: "Pin"))
        buttons.append(ToolbarButton(action: .ocr, sfSymbol: "doc.text.viewfinder", label: nil, tooltip: "OCR Text"))
        buttons.append(ToolbarButton(action: .autoRedact, sfSymbol: "eye.slash.fill", label: nil, tooltip: "Auto-Redact sensitive data"))

        // Beautify toggle
        var beautifyBtn = ToolbarButton(action: .beautify, sfSymbol: "sparkles", label: nil, tooltip: "Beautify — wrap in window frame")
        beautifyBtn.isSelected = beautifyEnabled
        buttons.append(beautifyBtn)

        // Beautify style picker (only shown when beautify is on)
        if beautifyEnabled {
            let style = BeautifyRenderer.styles[beautifyStyleIndex % BeautifyRenderer.styles.count]
            var styleBtn = ToolbarButton(action: .beautifyStyle, sfSymbol: "paintpalette.fill", label: nil, tooltip: "Style: \(style.name)")
            // Use the brighter of the two gradient colors, and lighten if still too dark
            let c1 = style.colors.0
            let c2 = style.colors.1
            let b1 = c1.redComponent * 0.299 + c1.greenComponent * 0.587 + c1.blueComponent * 0.114
            let b2 = c2.redComponent * 0.299 + c2.greenComponent * 0.587 + c2.blueComponent * 0.114
            var color = b2 > b1 ? c2 : c1
            let brightness = max(b1, b2)
            if brightness < 0.35 {
                // Lighten: blend toward white
                let factor: CGFloat = 0.5
                color = NSColor(
                    calibratedRed: color.redComponent + (1 - color.redComponent) * factor,
                    green: color.greenComponent + (1 - color.greenComponent) * factor,
                    blue: color.blueComponent + (1 - color.blueComponent) * factor,
                    alpha: 1.0
                )
            }
            styleBtn.tintColor = color
            buttons.append(styleBtn)
        }

        // Upload / Copy / Save
        buttons.append(ToolbarButton(action: .upload, sfSymbol: "icloud.and.arrow.up", label: nil, tooltip: "Upload"))
        buttons.append(ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", label: nil, tooltip: "Copy"))
        buttons.append(ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down", label: nil, tooltip: "Save"))

        return buttons
    }

    // Right toolbar items (actions)
    static func rightButtons(delaySeconds: Int = 0) -> [ToolbarButton] {
        let delaySymbol: String
        let delayTooltip: String
        switch delaySeconds {
        case 3: delaySymbol = "3.circle.fill"; delayTooltip = "Delay: 3s (click to change)"
        case 5: delaySymbol = "5.circle.fill"; delayTooltip = "Delay: 5s (click to change)"
        case 10: delaySymbol = "10.circle.fill"; delayTooltip = "Delay: 10s (click to change)"
        default: delaySymbol = "timer"; delayTooltip = "Delay capture (click to set)"
        }
        return [
            ToolbarButton(action: .cancel, sfSymbol: "xmark", label: nil, tooltip: "Cancel"),
            ToolbarButton(action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right", label: nil, tooltip: "Move Selection"),
            ToolbarButton(action: .delayCapture, sfSymbol: delaySymbol, label: nil, tooltip: delayTooltip),
        ]
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

        // Avoid overlapping with bottom toolbar
        if bottomBarRect.width > 0 {
            let rightBarRect = NSRect(x: barX, y: barY, width: totalWidth, height: totalHeight)
            if rightBarRect.intersects(bottomBarRect) {
                barY = bottomBarRect.maxY + 4
            }
        }

        // Clamp vertical
        barY = max(viewBounds.minY + 4, min(barY, viewBounds.maxY - totalHeight - 4))

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

        var barX = selectionRect.maxX + 6
        var barY = selectionRect.maxY - totalHeight

        // If right of screen, put left
        if barX + totalWidth > viewBounds.maxX - 4 {
            barX = selectionRect.minX - totalWidth - 6
        }

        // Avoid overlapping with bottom toolbar
        if bottomBarRect.width > 0 {
            let rightBarRect = NSRect(x: barX, y: barY, width: totalWidth, height: totalHeight)
            if rightBarRect.intersects(bottomBarRect) {
                barY = bottomBarRect.maxY + 4
            }
        }

        // Clamp vertical
        barY = max(viewBounds.minY + 4, min(barY, viewBounds.maxY - totalHeight - 4))

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
        let tintedImg = NSImage(size: imgSize)
        tintedImg.lockFocus()
        baseImg.draw(in: NSRect(origin: .zero, size: imgSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        tint.setFill()
        NSRect(origin: .zero, size: imgSize).fill(using: .sourceAtop)
        tintedImg.unlockFocus()
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
        let tintedImg = NSImage(size: imgSize)
        tintedImg.lockFocus()
        baseImg.draw(in: NSRect(origin: .zero, size: imgSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        tint.setFill()
        NSRect(origin: .zero, size: imgSize).fill(using: .sourceAtop)
        tintedImg.unlockFocus()

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

        // Selected highlight
        if btn.isSelected {
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
