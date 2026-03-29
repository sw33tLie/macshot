import Cocoa

/// Grid of beautify gradient style swatches for use inside an NSPopover.
class GradientPickerView: NSView {

    var selectedIndex: Int = 0
    var onSelect: ((Int) -> Void)?

    private let styles = BeautifyRenderer.styles
    private let cols = 6
    private let swSize: CGFloat = 28
    private let padding: CGFloat = 8
    private let gap: CGFloat = 4

    init(selectedIndex: Int) {
        self.selectedIndex = selectedIndex
        let rows = (BeautifyRenderer.styles.count + 5) / 6
        let w = 8 * 2 + CGFloat(6) * 28 + CGFloat(5) * 4
        let h = 8 * 2 + CGFloat(rows) * 28 + CGFloat(max(0, rows - 1)) * 4
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize { frame.size }

    override func draw(_ dirtyRect: NSRect) {
        for (i, style) in styles.enumerated() {
            let col = i % cols
            let row = i / cols
            let sx = padding + CGFloat(col) * (swSize + gap)
            let sy = bounds.maxY - padding - swSize - CGFloat(row) * (swSize + gap)
            let sr = NSRect(x: sx, y: sy, width: swSize, height: swSize)

            let path = NSBezierPath(roundedRect: sr, xRadius: 6, yRadius: 6)
            // Draw gradient — use mesh rendering on macOS 15+ for mesh styles
            if #available(macOS 15.0, *), let mesh = style.meshDef,
               let img = BeautifyRenderer.renderMeshSwatch(mesh, size: swSize) {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                img.draw(in: sr, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
            } else if let grad = NSGradient(colors: style.stops.map { $0.0 }, atLocations: style.stops.map { $0.1 }, colorSpace: .deviceRGB) {
                grad.draw(in: path, angle: style.angle - 90)
            }

            if i == selectedIndex % styles.count {
                ToolbarLayout.accentColor.setStroke()
                let ring = NSBezierPath(roundedRect: sr.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        for (i, _) in styles.enumerated() {
            let col = i % cols
            let row = i / cols
            let sx = padding + CGFloat(col) * (swSize + gap)
            let sy = bounds.maxY - padding - swSize - CGFloat(row) * (swSize + gap)
            let sr = NSRect(x: sx, y: sy, width: swSize, height: swSize)
            if sr.insetBy(dx: -2, dy: -2).contains(pt) {
                selectedIndex = i
                onSelect?(i)
                needsDisplay = true
                return
            }
        }
    }
}
