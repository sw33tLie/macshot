import Cocoa

/// Grid of beautify gradient style swatches for use inside an NSPopover.
/// Index -1 = custom image background.
class GradientPickerView: NSView {

    var selectedIndex: Int = 0
    var onSelect: ((Int) -> Void)?
    /// Called when the user clicks the custom image swatch — caller shows file picker.
    var onCustomImage: (() -> Void)?

    private let styles = BeautifyRenderer.styles
    private let cols = 6
    private let swSize: CGFloat = 28
    private let padding: CGFloat = 8
    private let gap: CGFloat = 4
    /// Whether a custom background image is stored.
    private var hasCustomImage: Bool {
        UserDefaults.standard.data(forKey: "beautifyCustomBgImageData") != nil
    }
    init(selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        let hasCustom = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData") != nil
        let total = BeautifyRenderer.styles.count + (hasCustom ? 1 : 0) + 1
        let rows = (total + 5) / 6
        let w = 8 * 2 + CGFloat(6) * 28 + CGFloat(5) * 4
        let h = 8 * 2 + CGFloat(rows) * 28 + CGFloat(max(0, rows - 1)) * 4
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize { frame.size }

    private func rectForIndex(_ i: Int) -> NSRect {
        let col = i % cols
        let row = i / cols
        let sx = padding + CGFloat(col) * (swSize + gap)
        let sy = bounds.maxY - padding - swSize - CGFloat(row) * (swSize + gap)
        return NSRect(x: sx, y: sy, width: swSize, height: swSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        var idx = 0

        // Draw gradient swatches
        for (i, style) in styles.enumerated() {
            let sr = rectForIndex(idx)
            let path = NSBezierPath(roundedRect: sr, xRadius: 6, yRadius: 6)
            if #available(macOS 15.0, *), let mesh = style.meshDef,
               let img = BeautifyRenderer.renderMeshSwatch(mesh, size: swSize) {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                img.draw(in: sr, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
            } else if let grad = NSGradient(colors: style.stops.map { $0.0 }, atLocations: style.stops.map { $0.1 }, colorSpace: .deviceRGB) {
                grad.draw(in: path, angle: style.angle - 90)
            }
            if i == selectedIndex {
                ToolbarLayout.accentColor.setStroke()
                let ring = NSBezierPath(roundedRect: sr.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
                ring.lineWidth = 2
                ring.stroke()
            }
            idx += 1
        }

        // Custom image thumbnail swatch (only if a custom image is stored)
        if let thumb = customBackgroundThumbnail() {
            let sr = rectForIndex(idx)
            let path = NSBezierPath(roundedRect: sr, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            thumb.draw(in: sr, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            if selectedIndex == -1 {
                ToolbarLayout.accentColor.setStroke()
                let ring = NSBezierPath(roundedRect: sr.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
                ring.lineWidth = 2
                ring.stroke()
            }
            idx += 1
        }

        // "+" button — always present, always opens file picker
        let pr = rectForIndex(idx)
        let plusPath = NSBezierPath(roundedRect: pr, xRadius: 6, yRadius: 6)
        ToolbarLayout.iconColor.withAlphaComponent(0.15).setFill()
        plusPath.fill()
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let plusIcon = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) {
            let tinted = plusIcon.copy() as! NSImage
            tinted.lockFocus()
            ToolbarLayout.iconColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let iconSize = tinted.size
            let iconRect = NSRect(
                x: pr.midX - iconSize.width / 2,
                y: pr.midY - iconSize.height / 2,
                width: iconSize.width, height: iconSize.height)
            tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.7)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        var idx = 0

        // Check gradient swatches
        for i in 0..<styles.count {
            let sr = rectForIndex(idx)
            if sr.insetBy(dx: -2, dy: -2).contains(pt) {
                selectedIndex = i
                onSelect?(i)
                needsDisplay = true
                return
            }
            idx += 1
        }

        // Check custom image thumbnail
        if hasCustomImage {
            let sr = rectForIndex(idx)
            if sr.insetBy(dx: -2, dy: -2).contains(pt) {
                selectedIndex = -1
                onSelect?(-1)
                needsDisplay = true
                return
            }
            idx += 1
        }

        // Check "+" button
        let pr = rectForIndex(idx)
        if pr.insetBy(dx: -2, dy: -2).contains(pt) {
            onCustomImage?()
        }
    }

    private func customBackgroundThumbnail() -> NSImage? {
        guard let data = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
              let image = NSImage(data: data) else { return nil }
        return image
    }
}
