import Cocoa

/// Custom color picker view for use inside an NSPopover.
/// Features: preset swatches, custom saveable slots, opacity slider, HSB gradient, brightness slider, hex display.
class ColorPickerView: NSView {

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

    func setColor(_ color: NSColor, opacity: CGFloat) {
        self.selectedColor = color
        self.opacity = opacity
        syncHSBFromColor(color)
        needsDisplay = true
    }

    // MARK: - Constants

    private static let presetColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .systemPink, .white, .lightGray, .gray, .darkGray, .black,
    ]

    private let cols = 6
    private let swatchSize: CGFloat = 24
    private let padding: CGFloat = 6
    private let customSlotSize: CGFloat = 20
    private let customSlotSpacing: CGFloat = 6
    private let opacityBarHeight: CGFloat = 12
    private let gradientSize: CGFloat = 140
    private let brightnessBarHeight: CGFloat = 16
    private let hexRowHeight: CGFloat = 22

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
    private var hexDisplayRect: NSRect = .zero
    private var customSlotRects: [NSRect] = []

    // MARK: - Drag state

    private var isDraggingOpacity = false
    private var isDraggingGradient = false
    private var isDraggingBrightness = false

    // MARK: - Preferred size

    var preferredSize: NSSize {
        let pickerWidth = CGFloat(cols) * (swatchSize + padding) + padding
        let presetH = CGFloat(2) * (swatchSize + padding)
        let pickerHeight = padding + presetH + padding + customSlotSize + padding
            + opacityBarHeight + padding + gradientSize + padding + brightnessBarHeight
            + padding + hexRowHeight + padding
        return NSSize(width: pickerWidth, height: pickerHeight)
    }

    // MARK: - Init

    init() {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 180, height: 400)))
        let size = preferredSize
        frame.size = size
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let pickerWidth = bounds.width
        var cursorY = bounds.maxY

        // --- 1. Preset color swatches ---
        cursorY -= padding
        for (i, color) in Self.presetColors.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = padding + CGFloat(col) * (swatchSize + padding)
            let y = cursorY - swatchSize - CGFloat(row) * (swatchSize + padding)
            let r = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)

            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()

            if colorsMatch(selectedColor, color) {
                ToolbarLayout.iconColor.setStroke()
                let border = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
                border.lineWidth = 2
                border.stroke()
            }
        }
        cursorY -= CGFloat(2) * (swatchSize + padding)

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
        let hRect = NSRect(x: padding, y: cursorY - hexRowHeight, width: pickerWidth - padding * 2, height: hexRowHeight)
        hexDisplayRect = hRect
        drawHexDisplay(in: hRect)
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

    private func drawHexDisplay(in rect: NSRect) {
        NSColor(white: 0.2, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        // Preview circle
        let circleSize: CGFloat = 12
        let circleRect = NSRect(x: rect.minX + 6, y: rect.midY - circleSize / 2, width: circleSize, height: circleSize)
        selectedColor.withAlphaComponent(opacity).setFill()
        NSBezierPath(ovalIn: circleRect).fill()
        ToolbarLayout.iconColor.withAlphaComponent(0.3).setStroke()
        NSBezierPath(ovalIn: circleRect).stroke()

        // Hex text
        let hashAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.5),
        ]
        let hexAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.9),
        ]
        let hashSize = ("#" as NSString).size(withAttributes: hashAttrs)
        let hashX = circleRect.maxX + 6
        ("#" as NSString).draw(at: NSPoint(x: hashX, y: rect.midY - hashSize.height / 2), withAttributes: hashAttrs)
        let hex = colorToHex(selectedColor)
        (hex as NSString).draw(at: NSPoint(x: hashX + hashSize.width, y: rect.midY - hashSize.height / 2), withAttributes: hexAttrs)
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Preset swatches
        for (i, color) in Self.presetColors.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = padding + CGFloat(col) * (swatchSize + padding)
            let y = bounds.maxY - padding - swatchSize - CGFloat(row) * (swatchSize + padding)
            if NSRect(x: x, y: y, width: swatchSize, height: swatchSize).contains(point) {
                selectedColor = color
                syncHSBFromColor(color)
                onColorChanged?(color)
                needsDisplay = true
                return
            }
        }

        // Custom slots
        for (i, r) in customSlotRects.enumerated() {
            if r.contains(point) {
                selectedColorSlot = i
                if let saved = customColors[i] {
                    selectedColor = saved
                    syncHSBFromColor(saved)
                    onColorChanged?(saved)
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
        needsDisplay = true
    }

    private func updateBrightness(at point: NSPoint) {
        brightness = max(0, min(1, (point.x - brightnessSliderRect.minX) / brightnessSliderRect.width))
        cachedGradientImage = nil
        let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        selectedColor = color
        onColorChanged?(color)
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

    /// Save the current color into the selected custom slot.
    func saveToSelectedSlot(_ color: NSColor) {
        guard selectedColorSlot >= 0, selectedColorSlot < customColors.count else { return }
        customColors[selectedColorSlot] = color.withAlphaComponent(1)
        onCustomColorsChanged?(customColors)
        needsDisplay = true
    }
}
