import Cocoa

enum BeautifyMode: Int {
    case window = 0   // macOS window chrome with traffic lights
    case rounded = 1  // just rounded corners, no title bar
}

struct BeautifyStyle {
    let name: String
    let stops: [(NSColor, CGFloat)]  // (color, location 0..1)
    let angle: CGFloat               // degrees, 0 = left→right, 90 = bottom→top

    /// Legacy convenience
    init(name: String, colors: (NSColor, NSColor)) {
        self.name = name
        self.stops = [(colors.0, 0), (colors.1, 1)]
        self.angle = 135  // top-left → bottom-right (matches old diagonal)
    }

    init(name: String, stops: [(NSColor, CGFloat)], angle: CGFloat = 135) {
        self.name = name
        self.stops = stops
        self.angle = angle
    }
}

struct BeautifyConfig {
    var mode: BeautifyMode = .window
    var styleIndex: Int = 0
    var padding: CGFloat = 48       // 16..96
    var cornerRadius: CGFloat = 10  // 0..30
    var shadowRadius: CGFloat = 20  // 0..40
    var bgRadius: CGFloat = 8      // 0..30 (outer background corner radius)

    /// Convenience: the resolved style from styles array
    var style: BeautifyStyle {
        BeautifyRenderer.styles[styleIndex % BeautifyRenderer.styles.count]
    }
}

class BeautifyRenderer {

    static let styles: [BeautifyStyle] = [
        // Row 1 — warm / sunset / orange
        BeautifyStyle(name: "Sunset", stops: [
            (NSColor(calibratedRed: 1.00, green: 0.60, blue: 0.15, alpha: 1), 0),
            (NSColor(calibratedRed: 0.98, green: 0.35, blue: 0.30, alpha: 1), 0.45),
            (NSColor(calibratedRed: 0.85, green: 0.18, blue: 0.45, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Peach", stops: [
            (NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.68, alpha: 1), 0),
            (NSColor(calibratedRed: 0.95, green: 0.60, blue: 0.55, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Ember", stops: [
            (NSColor(calibratedRed: 0.90, green: 0.25, blue: 0.10, alpha: 1), 0),
            (NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.05, alpha: 1), 0.5),
            (NSColor(calibratedRed: 1.00, green: 0.85, blue: 0.20, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Warm", stops: [
            (NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.88, alpha: 1), 0),
            (NSColor(calibratedRed: 0.92, green: 0.85, blue: 0.78, alpha: 1), 1),
        ], angle: 135),

        // Row 2 — blues / cool
        BeautifyStyle(name: "Ocean", stops: [
            (NSColor(calibratedRed: 0.10, green: 0.70, blue: 0.95, alpha: 1), 0),
            (NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.90, alpha: 1), 0.55),
            (NSColor(calibratedRed: 0.35, green: 0.20, blue: 0.80, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Sky", stops: [
            (NSColor(calibratedRed: 0.72, green: 0.90, blue: 0.98, alpha: 1), 0),
            (NSColor(calibratedRed: 0.50, green: 0.75, blue: 0.95, alpha: 1), 1),
        ], angle: 160),
        BeautifyStyle(name: "Cobalt", stops: [
            (NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.55, alpha: 1), 0),
            (NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.85, alpha: 1), 0.5),
            (NSColor(calibratedRed: 0.30, green: 0.60, blue: 0.95, alpha: 1), 1),
        ], angle: 150),
        BeautifyStyle(name: "Arctic", stops: [
            (NSColor(calibratedRed: 0.85, green: 0.93, blue: 0.98, alpha: 1), 0),
            (NSColor(calibratedRed: 0.65, green: 0.82, blue: 0.95, alpha: 1), 0.5),
            (NSColor(calibratedRed: 0.45, green: 0.70, blue: 0.90, alpha: 1), 1),
        ], angle: 135),

        // Row 3 — pink / purple / vibrant
        BeautifyStyle(name: "Candy", stops: [
            (NSColor(calibratedRed: 0.98, green: 0.40, blue: 0.55, alpha: 1), 0),
            (NSColor(calibratedRed: 0.90, green: 0.30, blue: 0.70, alpha: 1), 0.4),
            (NSColor(calibratedRed: 0.60, green: 0.25, blue: 0.90, alpha: 1), 0.75),
            (NSColor(calibratedRed: 0.35, green: 0.30, blue: 0.95, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Love", stops: [
            (NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.45, alpha: 1), 0),
            (NSColor(calibratedRed: 0.92, green: 0.50, blue: 0.55, alpha: 1), 1),
        ], angle: 150),
        BeautifyStyle(name: "Lavender", stops: [
            (NSColor(calibratedRed: 0.75, green: 0.65, blue: 0.95, alpha: 1), 0),
            (NSColor(calibratedRed: 0.90, green: 0.78, blue: 0.98, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Neon", stops: [
            (NSColor(calibratedRed: 0.98, green: 0.20, blue: 0.60, alpha: 1), 0),
            (NSColor(calibratedRed: 0.90, green: 0.50, blue: 0.15, alpha: 1), 0.3),
            (NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.60, alpha: 1), 0.6),
            (NSColor(calibratedRed: 0.25, green: 0.50, blue: 0.98, alpha: 1), 1),
        ], angle: 135),

        // Row 4 — greens / nature
        BeautifyStyle(name: "Forest", stops: [
            (NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.30, alpha: 1), 0),
            (NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.40, alpha: 1), 0.5),
            (NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.50, alpha: 1), 1),
        ], angle: 150),
        BeautifyStyle(name: "Mint", stops: [
            (NSColor(calibratedRed: 0.60, green: 0.95, blue: 0.80, alpha: 1), 0),
            (NSColor(calibratedRed: 0.40, green: 0.85, blue: 0.70, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Aurora", stops: [
            (NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.50, alpha: 1), 0),
            (NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.80, alpha: 1), 0.35),
            (NSColor(calibratedRed: 0.40, green: 0.30, blue: 0.85, alpha: 1), 0.65),
            (NSColor(calibratedRed: 0.70, green: 0.25, blue: 0.75, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Lime", stops: [
            (NSColor(calibratedRed: 0.55, green: 0.90, blue: 0.20, alpha: 1), 0),
            (NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.35, alpha: 1), 0.5),
            (NSColor(calibratedRed: 0.15, green: 0.60, blue: 0.45, alpha: 1), 1),
        ], angle: 135),

        // Row 5 — multicolor / dreamy
        BeautifyStyle(name: "Dreamy", stops: [
            (NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.98, alpha: 1), 0),
            (NSColor(calibratedRed: 0.75, green: 0.60, blue: 0.95, alpha: 1), 0.35),
            (NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.70, alpha: 1), 0.7),
            (NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.40, alpha: 1), 1),
        ], angle: 150),
        BeautifyStyle(name: "Rainbow", stops: [
            (NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.30, alpha: 1), 0),
            (NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.20, alpha: 1), 0.25),
            (NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.40, alpha: 1), 0.5),
            (NSColor(calibratedRed: 0.30, green: 0.60, blue: 0.95, alpha: 1), 0.75),
            (NSColor(calibratedRed: 0.70, green: 0.30, blue: 0.90, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Twilight", stops: [
            (NSColor(calibratedRed: 0.15, green: 0.10, blue: 0.35, alpha: 1), 0),
            (NSColor(calibratedRed: 0.45, green: 0.20, blue: 0.60, alpha: 1), 0.4),
            (NSColor(calibratedRed: 0.85, green: 0.40, blue: 0.50, alpha: 1), 0.7),
            (NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.40, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Hologram", stops: [
            (NSColor(calibratedRed: 0.40, green: 0.90, blue: 0.85, alpha: 1), 0),
            (NSColor(calibratedRed: 0.50, green: 0.65, blue: 0.98, alpha: 1), 0.35),
            (NSColor(calibratedRed: 0.80, green: 0.50, blue: 0.95, alpha: 1), 0.65),
            (NSColor(calibratedRed: 0.95, green: 0.60, blue: 0.80, alpha: 1), 1),
        ], angle: 120),

        // Row 6 — dark / moody
        BeautifyStyle(name: "Midnight", stops: [
            (NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.15, alpha: 1), 0),
            (NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.30, alpha: 1), 0.5),
            (NSColor(calibratedRed: 0.20, green: 0.15, blue: 0.45, alpha: 1), 1),
        ], angle: 150),
        BeautifyStyle(name: "Charcoal", stops: [
            (NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1), 0),
            (NSColor(calibratedRed: 0.22, green: 0.22, blue: 0.25, alpha: 1), 1),
        ], angle: 160),
        BeautifyStyle(name: "Abyss", stops: [
            (NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.12, alpha: 1), 0),
            (NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.30, alpha: 1), 0.4),
            (NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.50, alpha: 1), 0.75),
            (NSColor(calibratedRed: 0.15, green: 0.50, blue: 0.55, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Noir", stops: [
            (NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.03, alpha: 1), 0),
            (NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1), 1),
        ], angle: 135),

        // Row 7 — clean / neutral / light
        BeautifyStyle(name: "Snow", stops: [
            (NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.97, alpha: 1), 0),
            (NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.93, alpha: 1), 1),
        ], angle: 160),
        BeautifyStyle(name: "Cream", stops: [
            (NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.90, alpha: 1), 0),
            (NSColor(calibratedRed: 0.95, green: 0.90, blue: 0.80, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Slate", stops: [
            (NSColor(calibratedRed: 0.30, green: 0.35, blue: 0.42, alpha: 1), 0),
            (NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.58, alpha: 1), 0.5),
            (NSColor(calibratedRed: 0.60, green: 0.65, blue: 0.72, alpha: 1), 1),
        ], angle: 135),
        BeautifyStyle(name: "Steel", stops: [
            (NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.62, alpha: 1), 0),
            (NSColor(calibratedRed: 0.72, green: 0.75, blue: 0.78, alpha: 1), 0.5),
            (NSColor(calibratedRed: 0.85, green: 0.87, blue: 0.90, alpha: 1), 1),
        ], angle: 150),
    ]

    // MARK: - Legacy API (keeps existing callers working)

    static func render(image: NSImage, styleIndex: Int) -> NSImage {
        let config = BeautifyConfig(mode: .window, styleIndex: styleIndex)
        return render(image: image, config: config)
    }

    // MARK: - New configurable API

    static func render(image: NSImage, config: BeautifyConfig) -> NSImage {
        switch config.mode {
        case .window:
            return renderWindow(image: image, config: config)
        case .rounded:
            return renderRounded(image: image, config: config)
        }
    }

    /// Draw just the background gradient into a rect (for live overlay preview)
    static func drawGradientBackground(in rect: NSRect, config: BeautifyConfig, context: CGContext) {
        let style = config.style
        let colors = style.stops.map { $0.0.cgColor } as CFArray
        var locations = style.stops.map { $0.1 }
        let cs = CGColorSpaceCreateDeviceRGB()

        guard let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: &locations) else { return }

        // Convert angle (degrees) to start/end points within the rect
        let radians = style.angle * .pi / 180
        let dx = cos(radians)
        let dy = sin(radians)
        let cx = rect.midX
        let cy = rect.midY
        // Project to rect edges
        let halfW = rect.width / 2
        let halfH = rect.height / 2
        let scale = max(abs(dx) > 0.001 ? halfW / abs(dx) : .greatestFiniteMagnitude,
                        abs(dy) > 0.001 ? halfH / abs(dy) : .greatestFiniteMagnitude)
        let len = min(scale, hypot(halfW, halfH))
        let start = CGPoint(x: cx - dx * len, y: cy - dy * len)
        let end = CGPoint(x: cx + dx * len, y: cy + dy * len)

        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: - Window mode (macOS title bar chrome)

    private static func renderWindow(image: NSImage, config: BeautifyConfig) -> NSImage {
        let style = config.style
        let imgSize = image.size
        let padding = config.padding
        let windowCornerRadius = config.cornerRadius
        let shadowRadius = config.shadowRadius
        let shadowOffset = min(shadowRadius * 0.4, 10)
        let titleBarHeight: CGFloat = 28

        let windowWidth = imgSize.width
        let windowHeight = imgSize.height + titleBarHeight

        let totalWidth = windowWidth + padding * 2
        let totalHeight = windowHeight + padding * 2 + shadowOffset

        let result = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        result.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            result.unlockFocus()
            return image
        }

        // Draw gradient background with outer corner radius
        let bgRect = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        context.saveGState()
        NSBezierPath(roundedRect: bgRect, xRadius: config.bgRadius, yRadius: config.bgRadius).addClip()
        drawGradientBackground(in: bgRect, config: config, context: context)
        context.restoreGState()

        // Window frame position
        let windowX = padding
        let windowY = padding

        // Drop shadow
        if shadowRadius > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = shadowRadius
            shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
            NSBezierPath(roundedRect: windowRect, xRadius: windowCornerRadius, yRadius: windowCornerRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Draw window background clipped
        let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
        context.saveGState()
        let clipPath = NSBezierPath(roundedRect: windowRect, xRadius: windowCornerRadius, yRadius: windowCornerRadius)
        clipPath.addClip()

        NSColor(white: 0.97, alpha: 1.0).setFill()
        NSBezierPath(rect: windowRect).fill()

        // Title bar
        let titleBarRect = NSRect(x: windowX, y: windowY + windowHeight - titleBarHeight, width: windowWidth, height: titleBarHeight)
        NSColor(white: 0.94, alpha: 1.0).setFill()
        NSBezierPath(rect: titleBarRect).fill()

        // Separator
        NSColor(white: 0.82, alpha: 1.0).setFill()
        NSBezierPath(rect: NSRect(x: windowX, y: titleBarRect.minY - 0.5, width: windowWidth, height: 0.5)).fill()

        // Traffic lights
        let buttonY = titleBarRect.midY
        let buttonRadius: CGFloat = 6
        let buttonStartX = windowX + 14
        let buttonSpacing: CGFloat = 20

        let trafficLights: [(NSColor, NSColor)] = [
            (NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
             NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.22, alpha: 1.0)),
            (NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1.0),
             NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.15, alpha: 1.0)),
            (NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 1.0),
             NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.25, alpha: 1.0)),
        ]

        for (i, (fill, ring)) in trafficLights.enumerated() {
            let cx = buttonStartX + CGFloat(i) * buttonSpacing
            let circleRect = NSRect(x: cx - buttonRadius, y: buttonY - buttonRadius, width: buttonRadius * 2, height: buttonRadius * 2)
            fill.setFill()
            NSBezierPath(ovalIn: circleRect).fill()
            ring.setStroke()
            let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 0.5
            border.stroke()
        }

        // Screenshot image
        let contentRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight - titleBarHeight)
        image.draw(in: contentRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        context.restoreGState()

        result.unlockFocus()
        return result
    }

    // MARK: - Rounded mode (just rounded corners, no title bar)

    private static func renderRounded(image: NSImage, config: BeautifyConfig) -> NSImage {
        let imgSize = image.size
        let padding = config.padding
        let cornerRadius = config.cornerRadius
        let shadowRadius = config.shadowRadius
        let shadowOffset = min(shadowRadius * 0.4, 10)

        let totalWidth = imgSize.width + padding * 2
        let totalHeight = imgSize.height + padding * 2 + shadowOffset

        let result = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        result.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            result.unlockFocus()
            return image
        }

        // Gradient background with outer corner radius
        let bgRect = NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        context.saveGState()
        NSBezierPath(roundedRect: bgRect, xRadius: config.bgRadius, yRadius: config.bgRadius).addClip()
        drawGradientBackground(in: bgRect, config: config, context: context)
        context.restoreGState()

        let imageRect = NSRect(x: padding, y: padding, width: imgSize.width, height: imgSize.height)

        // Drop shadow
        if shadowRadius > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = shadowRadius
            shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Draw image with rounded corners
        context.saveGState()
        NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        image.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1.0)
        context.restoreGState()

        result.unlockFocus()
        return result
    }
}
