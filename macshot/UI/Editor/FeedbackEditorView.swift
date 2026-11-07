import Cocoa

/// Independent feedback canvas following EditorView's native scroll/zoom layout.
final class FeedbackEditorView: NSView {
    let image: CGImage
    var notes: [FeedbackNote] = [] { didSet { needsDisplay = true } }
    var selected: UUID? { didSet { needsDisplay = true } }
    var regionMode = false
    var onSelect: ((UUID) -> Void)?
    var onCreate: ((FeedbackNote) -> Void)?
    var onMove: ((UUID, CGRect) -> Void)?
    private var anchor: CGPoint?
    private var original: FeedbackNote?
    private var dragRect: CGRect?
    override var acceptsFirstResponder: Bool { true }

    init(image: CGImage) {
        self.image = image
        super.init(frame: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        let unit = 1 / max(0.1, enclosingScrollView?.magnification ?? 1)
        for (i, note) in notes.enumerated() where note.kind != .global {
            let color = note.id == selected ? NSColor.systemBlue : NSColor.systemOrange
            color.setStroke()
            if note.kind == .region {
                let path = NSBezierPath(rect: displayRect(note.rect)); path.lineWidth = 2 * unit; path.stroke()
            }
            let r = 12 * unit
            let center = CGPoint(x: min(max(r, note.rect.minX), bounds.width-r), y: min(max(r, bounds.height-note.rect.minY), bounds.height-r))
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: center.x-r, y: center.y-r, width: r*2, height: r*2)).fill()
            let text = "\(i+1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12*unit, weight: .semibold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: center.x-size.width/2, y: center.y-size.height/2), withAttributes: attrs)
        }
        if let dragRect { NSColor.systemBlue.setStroke(); let p = NSBezierPath(rect: displayRect(dragRect)); p.lineWidth = 2*unit; p.stroke() }
    }

    private func displayRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: bounds.height-r.maxY, width: r.width, height: r.height)
    }

    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }
    override func rightMouseDown(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) { nextResponder?.keyDown(with: event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, bounds.height-p.y), bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        anchor = p
        let tolerance = 16 / max(0.1, enclosingScrollView?.magnification ?? 1)
        original = notes.reversed().first { n in
            n.kind != .global && (n.kind == .region ? n.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
                : hypot(n.rect.minX-p.x, n.rect.minY-p.y) < tolerance)
        }
        if let original { onSelect?(original.id) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let p = point(event)
        if let original {
            var r = original.rect.offsetBy(dx: p.x-anchor.x, dy: p.y-anchor.y)
            r.origin.x = min(max(0, r.minX), bounds.width-r.width)
            r.origin.y = min(max(0, r.minY), bounds.height-r.height)
            dragRect = r
        } else if regionMode {
            dragRect = CGRect(x: min(anchor.x,p.x), y: min(anchor.y,p.y), width: abs(p.x-anchor.x), height: abs(p.y-anchor.y))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil; original = nil; dragRect = nil; needsDisplay = true }
        guard let anchor else { return }
        if let original {
            if let dragRect { onMove?(original.id, dragRect) }
        } else if regionMode {
            if let r = dragRect, r.width > 0, r.height > 0 { onCreate?(FeedbackNote(kind: .region, rect: r)) }
        } else {
            onCreate?(FeedbackNote(kind: .point, rect: CGRect(origin: anchor, size: .zero)))
        }
    }
}
