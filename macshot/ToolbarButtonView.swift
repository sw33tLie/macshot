import Cocoa

/// Real NSView for a single toolbar button. Handles its own hover, press, drawing.
/// Matches the existing dark toolbar look: purple accent, SF Symbols, color swatches.
class ToolbarButtonView: NSView {

    let action: ToolbarButtonAction
    var sfSymbol: String?
    var isOn: Bool = false { didSet { if oldValue != isOn { needsDisplay = true } } }
    var tintColor: NSColor = .white { didSet { needsDisplay = true } }
    var swatchColor: NSColor? { didSet { needsDisplay = true } }
    var hasContextMenu: Bool = false

    private var isHovered: Bool = false
    private var isPressed: Bool = false
    private var trackingArea: NSTrackingArea?

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?

    static let size: CGFloat = 32
    private static let radius: CGFloat = 6

    init(action: ToolbarButtonAction, sfSymbol: String?, tooltip: String) {
        self.action = action
        self.sfSymbol = sfSymbol
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        self.toolTip = tooltip
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Background
        let bg: NSColor
        if isPressed {
            bg = ToolbarLayout.accentColor.withAlphaComponent(0.6)
        } else if isOn {
            bg = ToolbarLayout.accentColor
        } else if isHovered {
            bg = NSColor.white.withAlphaComponent(0.12)
        } else {
            bg = NSColor.clear
        }
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()

        // Color swatch
        if let swatch = swatchColor {
            let inset: CGFloat = 6
            let r = bounds.insetBy(dx: inset, dy: inset)
            swatch.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            NSColor.white.withAlphaComponent(0.4).setStroke()
            let border = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            border.lineWidth = 0.5
            border.stroke()
            return
        }

        // SF Symbol
        guard let name = sfSymbol else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return }
        let color = isOn ? NSColor.white : tintColor
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            color.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        let x = bounds.midX - img.size.width / 2
        let y = bounds.midY - img.size.height / 2
        tinted.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)

        // Context menu triangle
        if hasContextMenu {
            let s: CGFloat = 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.maxX - s - 3, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3 + s))
            path.close()
            NSColor.white.withAlphaComponent(0.4).setFill()
            path.fill()
        }
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        isPressed = true; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false; needsDisplay = true
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(action)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(action, self)
    }
}
