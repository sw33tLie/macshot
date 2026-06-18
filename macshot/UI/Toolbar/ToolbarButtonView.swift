import Cocoa

/// Real NSView for a single toolbar button. Handles its own hover, press, drawing.
/// Matches the existing dark toolbar look: purple accent, SF Symbols, color swatches.
class ToolbarButtonView: NSView {

    let action: ToolbarButtonAction
    var sfSymbol: String?
    var isOn: Bool = false { didSet { if oldValue != isOn { cachedIcon = nil; needsDisplay = true } } }
    var tintColor: NSColor = ToolbarLayout.iconColor { didSet { cachedIcon = nil; cachedIconIsOn = nil; needsDisplay = true } }
    var swatchColor: NSColor? { didSet { needsDisplay = true } }
    var hasContextMenu: Bool = false
    /// Mic input level (0–1). When > 0, draws a green fill from the bottom of the button.
    var micLevel: Float = 0 { didSet { if abs(oldValue - micLevel) > 0.005 { needsDisplay = true } } }

    private var isHovered: Bool = false
    var isPressed: Bool = false
    private var trackingArea: NSTrackingArea?
    private var suppressHoverStartPoint: NSPoint?
    private var cachedIcon: NSImage?       // cached tinted SF Symbol for current state
    private var cachedIconIsOn: Bool?       // the isOn state when icon was cached

    /// Shared cross-instance cache: avoids re-rasterizing SF Symbols when toolbar is rebuilt.
    /// Key: "symbolName|isOn|colorHex"
    private static var iconCache: [String: NSImage] = [:]

    private static func cacheKey(name: String, isOn: Bool, color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: nil)
        return "\(name)|\(isOn)|\(Int(r*255)),\(Int(g*255)),\(Int(b*255))"
    }

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onMouseDown: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?  // (action, isHovered)

    static let size: CGFloat = 32
    private static let radius: CGFloat = 6

    var tooltipText: String = ""

    init(action: ToolbarButtonAction, sfSymbol: String?, tooltip: String) {
        self.action = action
        self.sfSymbol = sfSymbol
        self.tooltipText = tooltip
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
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
            bg = ToolbarLayout.iconColor.withAlphaComponent(0.12)
        } else {
            bg = NSColor.clear
        }
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()

        // Mic level fill — green bar rising from the bottom inside the button
        if micLevel > 0.001 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).addClip()
            let fillH = bounds.height * CGFloat(min(micLevel, 1.0))
            let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: fillH)
            NSColor.systemGreen.withAlphaComponent(0.45).setFill()
            fillRect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Color swatch
        if let swatch = swatchColor {
            let inset: CGFloat = 6
            let r = bounds.insetBy(dx: inset, dy: inset)
            swatch.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            ToolbarLayout.iconColor.withAlphaComponent(0.4).setStroke()
            let border = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            border.lineWidth = 0.5
            border.stroke()
            return
        }

        // SF Symbol or custom icon (static cache survives toolbar rebuilds)
        guard let name = sfSymbol else { return }
        let currentIsOn = isOn
        if cachedIcon == nil || cachedIconIsOn != currentIsOn {
            let color = currentIsOn ? ToolbarLayout.iconColor : tintColor
            let key = Self.cacheKey(name: name, isOn: currentIsOn, color: color)
            if let cached = Self.iconCache[key] {
                cachedIcon = cached
                cachedIconIsOn = currentIsOn
            } else {
                let img: NSImage?
                if name == "_custom.checkerboard" {
                    img = Self.checkerboardIcon(color: color)
                } else {
                    let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                    if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                            .withSymbolConfiguration(cfg) {
                        img = NSImage(size: symbol.size, flipped: false) { r in
                            symbol.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                            color.setFill()
                            r.fill(using: .sourceAtop)
                            return true
                        }
                    } else {
                        img = nil
                    }
                }
                if let img = img {
                    img.lockFocus(); img.unlockFocus()
                    Self.iconCache[key] = img
                    cachedIcon = img
                    cachedIconIsOn = currentIsOn
                }
            }
        }
        if let icon = cachedIcon {
            let x = bounds.midX - icon.size.width / 2
            let y = bounds.midY - icon.size.height / 2
            icon.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        // Context menu triangle
        if hasContextMenu {
            let s: CGFloat = 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.maxX - s - 3, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + 3 + s))
            path.close()
            ToolbarLayout.iconColor.withAlphaComponent(0.4).setFill()
            path.fill()
        }
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        // `.activeAlways` (not `.activeInActiveApp`): macshot is a menu-bar
        // LSUIElement app and the toolbars can live in non-activating panels
        // (Liquid Glass chrome). With `.activeInActiveApp`, mouseExited wouldn't
        // fire when the app isn't frontmost, leaving a previous button stuck in
        // its hover state when moving to another.
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Toolbar buttons always show the arrow cursor, overriding the overlay's
    // crosshair / hidden drawing-cursor that would otherwise bleed through.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        guard suppressHoverStartPoint == nil else {
            setHovered(false)
            return
        }
        // Robustly clear any sibling that AppKit failed to send mouseExited to
        // (common in non-activating glass chrome panels) so only one button is
        // ever hovered.
        (superview as? ToolbarStripView ?? superview?.superview as? ToolbarStripView)?.clearHover(except: self)
        setHovered(true)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        if let start = suppressHoverStartPoint {
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x
            let dy = now.y - start.y
            // AppKit can synthesize a mouseMoved/entered pass at the same
            // location after a toolbar drag loop unwinds. Keep hover suppressed
            // until the pointer actually moves away from the release point.
            guard dx * dx + dy * dy >= 9 else {
                setHovered(false)
                return
            }
            suppressHoverStartPoint = nil
        }
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            (superview as? ToolbarStripView ?? superview?.superview as? ToolbarStripView)?.clearHover(except: self)
            setHovered(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        suppressHoverStartPoint = nil
        setHovered(false)
    }

    /// Externally force the hover state (used by the strip to clear stale hovers).
    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
        onHover?(action, hovered)
    }

    func clearInteractionState(suppressHoverUntilMouseMoved suppress: Bool = false) {
        suppressHoverStartPoint = suppress ? NSEvent.mouseLocation : nil
        forwardingDrag = false
        isPressed = false
        setHovered(false)
        needsDisplay = true
    }

    private var forwardingDrag = false
    /// The view that should receive forwarded drag events (set by onMouseDown handler).
    var dragForwardTarget: NSView?

    override func mouseDown(with event: NSEvent) {
        isPressed = true; needsDisplay = true
        if onMouseDown != nil {
            onMouseDown?(action)
            if dragForwardTarget != nil {
                forwardingDrag = true
            }
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if forwardingDrag, let target = dragForwardTarget {
            target.mouseDragged(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false; needsDisplay = true
        if forwardingDrag, let target = dragForwardTarget {
            forwardingDrag = false
            target.mouseUp(with: event)
            return
        }
        forwardingDrag = false
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(action)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(action, self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - Custom checkerboard icon

    /// Generate a checkerboard icon matching the style of SF Symbols, tinted with the given color.
    /// The result is a rounded square with a 4x4 checkerboard pattern.
    private static func checkerboardIcon(color: NSColor) -> NSImage {
        let size: CGFloat = 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let cornerRadius: CGFloat = 3
            let cellSize = size / 4
            let clip = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                                    xRadius: cornerRadius, yRadius: cornerRadius)
            clip.addClip()

            for row in 0..<4 {
                for col in 0..<4 {
                    let isDark = (row + col) % 2 == 0
                    if isDark {
                        color.setFill()
                    } else {
                        color.withAlphaComponent(0.35).setFill()
                    }
                    let cellRect = NSRect(x: CGFloat(col) * cellSize, y: CGFloat(row) * cellSize,
                                          width: cellSize, height: cellSize)
                    cellRect.fill()
                }
            }
            return true
        }
        return img
    }
}
