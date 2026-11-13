import Cocoa

/// Custom color picker view for use inside an NSPopover.
/// Features: preset swatches, custom saveable slots, opacity slider, HSB gradient, brightness slider, hex entry.
class ColorPickerView: NSView, NSTextFieldDelegate {

    // MARK: - Public interface

    /// Called whenever the user picks a color (from swatches, gradient, or brightness).
    var onColorChanged: ((NSColor) -> Void)?
    /// Called whenever opacity changes.
    var onOpacityChanged: ((CGFloat) -> Void)?

    private(set) var selectedColor: NSColor = .systemRed
    private(set) var opacity: CGFloat = 1.0

    var customColors: [NSColor?] = Array(repeating: nil, count: 7) {
        didSet { needsDisplay = true }
    }
    var selectedColorSlot: Int = 0 {
        didSet { needsDisplay = true }
    }
    /// Called when a custom slot is clicked (to select it) or filled.
    var onCustomSlotSelected: ((Int) -> Void)?
    /// Called when custom colors change (for persistence).
    var onCustomColorsChanged: (([NSColor?]) -> Void)?

    /// Swatch list above the custom slots; the picker height follows its row count.
    var presetColors: [NSColor] = PresetColorPalette.colors {
        didSet {
            frame.size = preferredSize
            needsDisplay = true
        }
    }

    func setColor(_ color: NSColor, opacity: CGFloat) {
        self.selectedColor = color
        self.opacity = opacity
        syncHSBFromColor(color)
        syncHexField()
        needsDisplay = true
    }

    // MARK: - Constants

    private let cols = 6
    private let swatchSize: CGFloat = 24
    private let padding: CGFloat = 6
    private let customSlotSize: CGFloat = 20
    private let customSlotSpacing: CGFloat = 6
    private let opacityBarHeight: CGFloat = 12
    private let gradientSize: CGFloat = 140
    private let brightnessBarHeight: CGFloat = 16
    private let hexRowHeight: CGFloat = 22
    private let hexPreviewSize: CGFloat = 12
    private let hexBubbleInset: CGFloat = 6
    private let hexBubbleGap: CGFloat = 6

    // MARK: - HSB state

    private var hue: CGFloat = 0
    private var saturation: CGFloat = 1
    private var brightness: CGFloat = 1
    private var cachedGradientImage: NSImage?
    private var cachedBrightness: CGFloat = -1

    // MARK: - Layout rects (computed during draw)

    private var opacitySliderRect: NSRect = .zero
    private var gradientRect: NSRect = .zero
    private var brightnessSliderRect: NSRect = .zero
    private var customSlotRects: [NSRect] = []
    private var presetSwatchRects: [NSRect] = []

    private let hexField = HexField()

    // MARK: - Drag state

    private var isDraggingOpacity = false
    private var isDraggingGradient = false
    private var isDraggingBrightness = false

    // MARK: - Preferred size

    private var presetRows: Int {
        Int(ceil(Double(presetColors.count) / Double(cols)))
    }

    private var presetSectionHeight: CGFloat {
        // 0 when the user removed every default color, so the picker sheds the whole band
        guard presetRows > 0 else { return 0 }
        return padding + CGFloat(presetRows) * (swatchSize + padding)
    }

    var preferredSize: NSSize {
        let pickerWidth = CGFloat(cols) * (swatchSize + padding) + padding
        let pickerHeight = presetSectionHeight + padding + customSlotSize + padding
            + opacityBarHeight + padding + gradientSize + padding + brightnessBarHeight
            + padding + hexRowHeight + padding
        return NSSize(width: pickerWidth, height: pickerHeight)
    }

    // MARK: - Init

    init() {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 180, height: 400)))
        let size = preferredSize
        frame.size = size

        hexField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        hexField.isBordered = false
        hexField.drawsBackground = false
        // The bubble behind the field is always dark, whatever the toolbar theme, so the
        // field (text, caret, selection, placeholder) is drawn for a dark background too.
        hexField.appearance = NSAppearance(named: .darkAqua)
        hexField.textColor = NSColor(white: 1, alpha: 0.9)
        hexField.focusRingType = .none
        hexField.placeholderString = "#RRGGBB"
        hexField.delegate = self
        hexField.target = self
        hexField.action = #selector(hexFieldCommitted)
        hexField.setAccessibilityLabel(L("Color"))
        addSubview(hexField)
        syncHexField()
        layoutHexField()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // The popover can close (outside click, another popover) before Return is pressed;
        // keep a complete code the user typed instead of discarding it with the window.
        if let window, newWindow !== window {
            commitTypedHexIfEditing()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Prevent auto focusing on editing the hex code input
        window.makeFirstResponder(self)
        // Closing the popover resigns its window's key status first.
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowDidResignKey(_ note: Notification) {
        commitTypedHexIfEditing()
    }

    override var acceptsFirstResponder: Bool { true }

    private var hexRowRect: NSRect {
        NSRect(x: padding, y: padding, width: bounds.width - padding * 2, height: hexRowHeight)
    }

    private var hexBubbleRect: NSRect {
        let row = hexRowRect
        let left = row.minX + hexBubbleInset + hexPreviewSize + hexBubbleGap
        return NSRect(x: left, y: row.minY, width: row.maxX - left, height: row.height)
    }

    private func layoutHexField() {
        let bubble = hexBubbleRect
        hexField.frame = NSRect(x: bubble.minX + hexBubbleInset, y: bubble.midY - 8,
                                width: bubble.width - hexBubbleInset * 2, height: 16)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutHexField()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let pickerWidth = bounds.width
        var cursorY = bounds.maxY

        // --- 1. Preset color swatches ---
        presetSwatchRects = []
        if !presetColors.isEmpty {
            cursorY -= padding
            for (i, color) in presetColors.enumerated() {
                let col = i % cols
                let row = i / cols
                let x = padding + CGFloat(col) * (swatchSize + padding)
                let y = cursorY - swatchSize - CGFloat(row) * (swatchSize + padding)
                let r = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)
                presetSwatchRects.append(r)

                color.setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()

                if colorsMatch(selectedColor, color) {
                    ToolbarLayout.iconColor.setStroke()
                    let border = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
                    border.lineWidth = 2
                    border.stroke()
                }
            }
            cursorY -= CGFloat(presetRows) * (swatchSize + padding)
        }

        // --- 2. Custom color slots ---
        cursorY -= padding
        customSlotRects = []
        let totalCustomW = CGFloat(customColors.count) * customSlotSize + CGFloat(customColors.count - 1) * customSlotSpacing
        let customStartX = (pickerWidth - totalCustomW) / 2
        for i in 0..<customColors.count {
            let x = customStartX + CGFloat(i) * (customSlotSize + customSlotSpacing)
            let y = cursorY - customSlotSize
            let r = NSRect(x: x, y: y, width: customSlotSize, height: customSlotSize)
            customSlotRects.append(r)

            if let saved = customColors[i] {
                saved.setFill()
                NSBezierPath(ovalIn: r).fill()
                if selectedColorSlot == i {
                    ToolbarLayout.iconColor.setStroke()
                    let b = NSBezierPath(ovalIn: r.insetBy(dx: -2, dy: -2))
                    b.lineWidth = 2.5
                    b.stroke()
                }
            } else {
                if selectedColorSlot == i {
                    ToolbarLayout.iconColor.withAlphaComponent(0.5).setStroke()
                    let b = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                    b.lineWidth = 2
                    b.stroke()
                } else {
                    ToolbarLayout.iconColor.withAlphaComponent(0.2).setStroke()
                    let dash = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                    dash.lineWidth = 1
                    dash.setLineDash([3, 3], count: 2, phase: 0)
                    dash.stroke()
                }
            }
        }
        cursorY -= customSlotSize

        // --- 3. Opacity slider ---
        cursorY -= padding
        let oRect = NSRect(x: padding, y: cursorY - opacityBarHeight, width: pickerWidth - padding * 2, height: opacityBarHeight)
        opacitySliderRect = oRect
        drawOpacitySlider(in: oRect)
        cursorY -= opacityBarHeight

        // --- 4. HSB gradient ---
        cursorY -= padding
        let gRect = NSRect(x: padding, y: cursorY - gradientSize, width: pickerWidth - padding * 2, height: gradientSize)
        gradientRect = gRect
        drawHSBGradient(in: gRect)

        // Crosshair
        let cx = gRect.minX + hue * gRect.width
        let cy = gRect.minY + saturation * gRect.height
        NSColor.black.withAlphaComponent(0.6).setStroke()
        NSBezierPath(ovalIn: NSRect(x: cx - 5, y: cy - 5, width: 10, height: 10)).stroke()
        NSColor.white.setStroke()
        let inner = NSBezierPath(ovalIn: NSRect(x: cx - 4, y: cy - 4, width: 8, height: 8))
        inner.lineWidth = 1.5
        inner.stroke()
        cursorY -= gradientSize

        // --- 5. Brightness slider ---
        cursorY -= padding
        let bRect = NSRect(x: padding, y: cursorY - brightnessBarHeight, width: pickerWidth - padding * 2, height: brightnessBarHeight)
        brightnessSliderRect = bRect
        drawBrightnessSlider(in: bRect)
        cursorY -= brightnessBarHeight

        // --- 6. Hex display ---
        cursorY -= padding
        drawHexRow(in: hexRowRect)
    }

    // MARK: - Sub-draw helpers

    private func drawOpacitySlider(in rect: NSRect) {
        // Checkerboard
        let checkSize = rect.height / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        let cols = Int(ceil(rect.width / checkSize))
        for ci in 0...cols {
            for ri in 0...1 {
                ((ci + ri) % 2 == 0 ? NSColor(white: 0.5, alpha: 1) : NSColor(white: 0.7, alpha: 1)).setFill()
                NSRect(x: rect.minX + CGFloat(ci) * checkSize, y: rect.minY + CGFloat(ri) * checkSize,
                       width: checkSize, height: checkSize).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // Gradient overlay
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSGradient(starting: selectedColor.withAlphaComponent(0), ending: selectedColor.withAlphaComponent(1))?.draw(in: path, angle: 0)

        // Border
        ToolbarLayout.iconColor.withAlphaComponent(0.3).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        border.lineWidth = 0.5
        border.stroke()

        // Thumb
        let thumbX = rect.minX + opacity * rect.width
        let thumbH = rect.height + 4
        let thumbRect = NSRect(x: thumbX - 4, y: rect.midY - thumbH / 2, width: 8, height: thumbH)
        ToolbarLayout.iconColor.setFill()
        NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).fill()
        NSColor.black.withAlphaComponent(0.3).setStroke()
        NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).stroke()

        // Label
        let label = "\(Int(opacity * 100))%" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.8),
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: rect.maxX - size.width - 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawHSBGradient(in rect: NSRect) {
        let scale: CGFloat = 2
        let w = Int(rect.width / scale)
        let h = Int(rect.height / scale)
        guard w > 0, h > 0 else { return }

        if cachedGradientImage == nil || cachedBrightness != brightness {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
            for px in 0..<w {
                for py in 0..<h {
                    let h2 = CGFloat(px) / CGFloat(w)
                    let s2 = CGFloat(py) / CGFloat(h)
                    let c = NSColor(calibratedHue: h2, saturation: s2, brightness: brightness, alpha: 1)
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    c.getRed(&r, green: &g, blue: &b, alpha: &a)
                    rep.setColor(NSColor(calibratedRed: r, green: g, blue: b, alpha: 1), atX: px, y: h - 1 - py)
                }
            }
            let img = NSImage(size: NSSize(width: w, height: h))
            img.addRepresentation(rep)
            cachedGradientImage = img
            cachedBrightness = brightness
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        cachedGradientImage!.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBrightnessSlider(in rect: NSRect) {
        let currentHS = NSColor(calibratedHue: hue, saturation: saturation, brightness: 1, alpha: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSGradient(starting: .black, ending: currentHS)?.draw(in: path, angle: 0)

        let bx = rect.minX + brightness * rect.width
        let thumbH = rect.height + 4
        let thumbRect = NSRect(x: bx - 4, y: rect.midY - thumbH / 2, width: 8, height: thumbH)
        ToolbarLayout.iconColor.setFill()
        NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).fill()
        NSColor.black.withAlphaComponent(0.3).setStroke()
        NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).stroke()
    }

    private func drawHexRow(in rect: NSRect) {
        let bubble = hexBubbleRect
        // Always a dark chip: the hex field's text is fixed light, so this
        // stays readable with the light toolbar appearance too.
        NSColor(white: 0.2, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 4, yRadius: 4).fill()

        // Preview circle
        let circleRect = NSRect(x: rect.minX + hexBubbleInset, y: rect.midY - hexPreviewSize / 2,
                                width: hexPreviewSize, height: hexPreviewSize)
        selectedColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(ovalIn: circleRect).fill()
        ToolbarLayout.iconColor.withAlphaComponent(0.3).setStroke()
        NSBezierPath(ovalIn: circleRect).stroke()
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if hexRowRect.contains(point) {
            if hexField.currentEditor() == nil {
                window?.makeFirstResponder(hexField)
                hexField.selectText(nil)
            }
            return
        }
        // A click elsewhere commits a half-typed code before changing the color.
        if hexField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }

        // Preset swatches
        for (i, rect) in presetSwatchRects.enumerated() where rect.contains(point) {
            let color = presetColors[i]
            selectedColor = color
            syncHSBFromColor(color)
            onColorChanged?(color)
            syncHexField()
            needsDisplay = true
            return
        }

        // Custom slots
        for (i, r) in customSlotRects.enumerated() {
            if r.contains(point) {
                selectedColorSlot = i
                if let saved = customColors[i] {
                    selectedColor = saved
                    syncHSBFromColor(saved)
                    onColorChanged?(saved)
                    syncHexField()
                }
                onCustomSlotSelected?(i)
                needsDisplay = true
                return
            }
        }

        // Opacity
        if opacitySliderRect.contains(point) {
            isDraggingOpacity = true
            updateOpacity(at: point)
            return
        }

        // Gradient
        if gradientRect.contains(point) {
            isDraggingGradient = true
            updateGradient(at: point)
            return
        }

        // Brightness
        if brightnessSliderRect.contains(point) {
            isDraggingBrightness = true
            updateBrightness(at: point)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDraggingOpacity { updateOpacity(at: point) }
        if isDraggingGradient { updateGradient(at: point) }
        if isDraggingBrightness { updateBrightness(at: point) }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingOpacity = false
        isDraggingGradient = false
        isDraggingBrightness = false
    }

    // MARK: - Update helpers

    private func updateOpacity(at point: NSPoint) {
        opacity = max(0.05, min(1, (point.x - opacitySliderRect.minX) / opacitySliderRect.width))
        onOpacityChanged?(opacity)
        needsDisplay = true
    }

    private func updateGradient(at point: NSPoint) {
        hue = max(0, min(1, (point.x - gradientRect.minX) / gradientRect.width))
        saturation = max(0, min(1, (point.y - gradientRect.minY) / gradientRect.height))
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        selectedColor = color
        onColorChanged?(color)
        syncHexField()
        needsDisplay = true
    }

    private func updateBrightness(at point: NSPoint) {
        brightness = max(0, min(1, (point.x - brightnessSliderRect.minX) / brightnessSliderRect.width))
        cachedGradientImage = nil
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        selectedColor = color
        onColorChanged?(color)
        syncHexField()
        needsDisplay = true
    }

    // MARK: - Helpers

    private func syncHSBFromColor(_ color: NSColor) {
        guard let hsb = color.usingColorSpace(.deviceRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h
        saturation = s
        brightness = b
        cachedGradientImage = nil
    }

    private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ac = a.usingColorSpace(.deviceRGB), let bc = b.usingColorSpace(.deviceRGB) else { return a == b }
        let t: CGFloat = 0.01
        return abs(ac.redComponent - bc.redComponent) < t
            && abs(ac.greenComponent - bc.greenComponent) < t
            && abs(ac.blueComponent - bc.blueComponent) < t
    }

    private func colorToHex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "000000" }
        return String(format: "%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }

    // MARK: - Hex field

    private func syncHexField(force: Bool = false) {
        let editor = hexField.currentEditor()
        guard force || editor == nil else { return }
        let text = "#" + colorToHex(selectedColor)
        hexField.stringValue = text
        editor?.string = text
    }

    @objc private func hexFieldCommitted() {
        commitHexField()
    }

    /// Applies the typed code. An unreadable entry restores the current color's code unless
    /// `revertingInvalid` is false (the window losing focus mid-edit keeps the partial text).
    func commitHexField(revertingInvalid: Bool = true) {
        let text = hexField.currentEditor()?.string ?? hexField.stringValue
        guard let color = ColorCode.color(from: text) else {
            if revertingInvalid { syncHexField(force: true) }
            return
        }
        // Return and end-of-editing both commit, and focusing the field then clicking away
        // commits its unchanged text: only an actual change may recolor the selection.
        if colorToHex(color) == colorToHex(selectedColor) {
            syncHexField(force: true)
            return
        }
        selectedColor = color
        syncHSBFromColor(color)
        onColorChanged?(color)
        syncHexField(force: true)
        needsDisplay = true
    }

    private func commitTypedHexIfEditing() {
        guard hexField.currentEditor() != nil else { return }
        commitHexField(revertingInvalid: false)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitHexField()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = hexField.textColor ?? .white
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Escape abandons the typed code and leaves the field; a second Escape closes the popover.
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            syncHexField(force: true)
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    /// Save the current color into the selected custom slot.
    func saveToSelectedSlot(_ color: NSColor) {
        guard selectedColorSlot >= 0, selectedColorSlot < customColors.count else { return }
        customColors[selectedColorSlot] = color.withAlphaComponent(1)
        onCustomColorsChanged?(customColors)
        needsDisplay = true
    }
}

private final class HexField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        (currentEditor() as? NSTextView)?.selectAll(nil)
    }
}

/// Accepts `#RRGGBB` and bare `RRGGBB`; anything else returns `nil`.
enum ColorCode {

    static func color(from text: String) -> NSColor? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy(\.isHexDigit),
              let number = UInt32(value, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
                       green: CGFloat((number >> 8) & 0xFF) / 255,
                       blue: CGFloat(number & 0xFF) / 255,
                       alpha: 1)
    }
}
