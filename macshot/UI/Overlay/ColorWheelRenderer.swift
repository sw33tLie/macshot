import Cocoa

/// Radial color wheel shown on right-click in drawing mode.
/// Manages its own state — OverlayView calls show(), draw(), updateHover(), selectHovered(), dismiss().
class ColorWheelRenderer {

    var isVisible: Bool = false
    var isSticky: Bool = false  // true when wheel stays open for click-to-pick (iPad/Sidecar)
    var center: NSPoint = .zero
    var hoveredIndex: Int = -1

    private let radius: CGFloat = 72
    private let swatchRadius: CGFloat = 12
    /// Rainbow hue spectrum + neutrals, all on one ring.
    /// 12 hues evenly spaced + 4 neutrals = 16 swatches around the circle.
    let colors: [NSColor] = [
        NSColor(calibratedHue: 0.0,   saturation: 0.85, brightness: 1.0, alpha: 1),  // red
        NSColor(calibratedHue: 1/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // orange
        NSColor(calibratedHue: 2/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // yellow
        NSColor(calibratedHue: 3/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // lime
        NSColor(calibratedHue: 4/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // green
        NSColor(calibratedHue: 5/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // teal
        NSColor(calibratedHue: 6/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // cyan
        NSColor(calibratedHue: 7/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // azure
        NSColor(calibratedHue: 8/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // blue
        NSColor(calibratedHue: 9/12,  saturation: 0.85, brightness: 1.0, alpha: 1),  // purple
        NSColor(calibratedHue: 10/12, saturation: 0.85, brightness: 1.0, alpha: 1),  // magenta
        NSColor(calibratedHue: 11/12, saturation: 0.85, brightness: 1.0, alpha: 1),  // pink
        .white,
        NSColor(white: 0.7, alpha: 1),
        NSColor(white: 0.4, alpha: 1),
        .black,
    ]

    func show(at point: NSPoint) {
        center = point
        hoveredIndex = -1
        isVisible = true
    }

    func dismiss() {
        isVisible = false
        isSticky = false
        hoveredIndex = -1
    }

    func updateHover(at point: NSPoint) {
        hoveredIndex = indexAt(point)
    }

    /// Returns the selected color, or nil if nothing valid is hovered.
    var hoveredColor: NSColor? {
        guard hoveredIndex >= 0, hoveredIndex < colors.count else { return nil }
        return colors[hoveredIndex]
    }

    func draw(currentColor: NSColor) {
        guard isVisible else { return }
        let count = colors.count
        let angleStep = (2 * CGFloat.pi) / CGFloat(count)

        // Dim background
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - radius - swatchRadius - 8,
            y: center.y - radius - swatchRadius - 8,
            width: (radius + swatchRadius + 8) * 2,
            height: (radius + swatchRadius + 8) * 2
        )).fill()

        // All swatches on one ring
        for (i, color) in colors.enumerated() {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * angleStep
            let sx = center.x + radius * cos(angle)
            let sy = center.y + radius * sin(angle)

            let isHovered = (i == hoveredIndex)
            let r = isHovered ? swatchRadius + 3 : swatchRadius
            let swatchRect = NSRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)

            if isHovered {
                NSColor.black.withAlphaComponent(0.4).setFill()
                NSBezierPath(ovalIn: swatchRect.insetBy(dx: -2, dy: -2)).fill()
            }

            color.setFill()
            NSBezierPath(ovalIn: swatchRect).fill()

            let borderColor: NSColor = isHovered ? .white : .white.withAlphaComponent(0.5)
            borderColor.setStroke()
            let border = NSBezierPath(ovalIn: swatchRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = isHovered ? 2.5 : 1.0
            border.stroke()

            // Check mark for current color
            if colorsMatch(color, currentColor) && !isHovered {
                let s: CGFloat = 8
                let checkPath = NSBezierPath()
                checkPath.lineWidth = 2
                checkPath.lineCapStyle = .round
                checkPath.lineJoinStyle = .round
                checkPath.move(to: NSPoint(x: sx - s * 0.35, y: sy + s * 0.05))
                checkPath.line(to: NSPoint(x: sx - s * 0.05, y: sy - s * 0.3))
                checkPath.line(to: NSPoint(x: sx + s * 0.4, y: sy + s * 0.3))
                let c = color.usingColorSpace(.sRGB) ?? color
                let brightness = c.redComponent * 0.299 + c.greenComponent * 0.587 + c.blueComponent * 0.114
                (brightness > 0.6 ? NSColor.black : NSColor.white).setStroke()
                checkPath.stroke()
            }
        }
    }

    /// Approximate color match (handles different color spaces).
    private func colorsMatch(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ac = a.usingColorSpace(.sRGB), let bc = b.usingColorSpace(.sRGB) else { return a == b }
        return abs(ac.redComponent - bc.redComponent) < 0.02
            && abs(ac.greenComponent - bc.greenComponent) < 0.02
            && abs(ac.blueComponent - bc.blueComponent) < 0.02
            && abs(ac.alphaComponent - bc.alphaComponent) < 0.02
    }

    private func indexAt(_ point: NSPoint) -> Int {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let dist = hypot(dx, dy)

        // Dead zone at center only
        if dist < radius * 0.25 { return -1 }

        // Purely angle-based — works at any distance
        let count = colors.count
        let angleStep = (2 * CGFloat.pi) / CGFloat(count)
        var angle = atan2(dy, dx) + CGFloat.pi / 2
        if angle < 0 { angle += 2 * CGFloat.pi }
        return Int((angle + angleStep / 2) / angleStep) % count
    }
}
