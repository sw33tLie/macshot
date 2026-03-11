import Cocoa

struct BeautifyStyle {
    let name: String
    let colors: (NSColor, NSColor)  // gradient start, end
}

class BeautifyRenderer {

    static let styles: [BeautifyStyle] = [
        BeautifyStyle(name: "Ocean", colors: (
            NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.85, alpha: 1.0),
            NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
        )),
        BeautifyStyle(name: "Sunset", colors: (
            NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.35, alpha: 1.0),
            NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.20, alpha: 1.0)
        )),
        BeautifyStyle(name: "Forest", colors: (
            NSColor(calibratedRed: 0.15, green: 0.65, blue: 0.45, alpha: 1.0),
            NSColor(calibratedRed: 0.20, green: 0.80, blue: 0.70, alpha: 1.0)
        )),
        BeautifyStyle(name: "Midnight", colors: (
            NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.20, alpha: 1.0),
            NSColor(calibratedRed: 0.25, green: 0.20, blue: 0.40, alpha: 1.0)
        )),
        BeautifyStyle(name: "Candy", colors: (
            NSColor(calibratedRed: 0.90, green: 0.35, blue: 0.55, alpha: 1.0),
            NSColor(calibratedRed: 0.60, green: 0.30, blue: 0.90, alpha: 1.0)
        )),
        BeautifyStyle(name: "Snow", colors: (
            NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.95, alpha: 1.0),
            NSColor(calibratedRed: 0.82, green: 0.84, blue: 0.88, alpha: 1.0)
        )),
    ]

    static func render(image: NSImage, styleIndex: Int) -> NSImage {
        let style = styles[styleIndex % styles.count]
        let imgSize = image.size

        // Layout constants
        let padding: CGFloat = 48
        let titleBarHeight: CGFloat = 28
        let windowCornerRadius: CGFloat = 10
        let shadowRadius: CGFloat = 20
        let shadowOffset: CGFloat = 8

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

        // Draw gradient background
        let gradientColors = [style.colors.0.cgColor, style.colors.1.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradientColors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: totalHeight),
                end: CGPoint(x: totalWidth, y: 0),
                options: []
            )
        }

        // Window frame position
        let windowX = padding
        let windowY = padding

        // Drop shadow
        let shadowColor = NSColor.black.withAlphaComponent(0.35)
        let shadow = NSShadow()
        shadow.shadowColor = shadowColor
        shadow.shadowBlurRadius = shadowRadius
        shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)

        // Draw window background with shadow
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let windowRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)
        let windowPath = NSBezierPath(roundedRect: windowRect, xRadius: windowCornerRadius, yRadius: windowCornerRadius)
        NSColor.white.setFill()
        windowPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Draw window background (on top of shadow, clean)
        context.saveGState()
        let clipPath = NSBezierPath(roundedRect: windowRect, xRadius: windowCornerRadius, yRadius: windowCornerRadius)
        clipPath.addClip()

        NSColor(white: 0.97, alpha: 1.0).setFill()
        NSBezierPath(rect: windowRect).fill()

        // Title bar
        let titleBarRect = NSRect(x: windowX, y: windowY + windowHeight - titleBarHeight, width: windowWidth, height: titleBarHeight)
        NSColor(white: 0.94, alpha: 1.0).setFill()
        NSBezierPath(rect: titleBarRect).fill()

        // Subtle separator line below title bar
        NSColor(white: 0.82, alpha: 1.0).setFill()
        NSBezierPath(rect: NSRect(x: windowX, y: titleBarRect.minY - 0.5, width: windowWidth, height: 0.5)).fill()

        // Traffic light buttons
        let buttonY = titleBarRect.midY
        let buttonRadius: CGFloat = 6
        let buttonStartX = windowX + 14
        let buttonSpacing: CGFloat = 20

        let trafficLights: [(NSColor, NSColor)] = [
            // (fill, darker ring)
            (NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
             NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.22, alpha: 1.0)),  // close
            (NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1.0),
             NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.15, alpha: 1.0)),  // minimize
            (NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 1.0),
             NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.25, alpha: 1.0)),  // maximize
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

        // Draw the screenshot image in the content area
        let contentRect = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight - titleBarHeight)
        image.draw(in: contentRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        context.restoreGState()

        result.unlockFocus()
        return result
    }
}
