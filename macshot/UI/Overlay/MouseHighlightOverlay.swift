import Cocoa

/// Transparent fullscreen overlay that draws animated mouse click highlights during recording.
/// Sits above other windows so ScreenCaptureKit captures the highlights.
class MouseHighlightOverlay: NSPanel {

    private let highlightView: MouseHighlightView

    init(screen: NSScreen) {
        highlightView = MouseHighlightView()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 1  // above normal windows, captured by SCStream
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        highlightView.frame = NSRect(origin: .zero, size: screen.frame.size)
        highlightView.autoresizingMask = [.width, .height]
        contentView = highlightView
    }

    private var globalMonitor: Any?

    func startMonitoring() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return }
            let screenPoint = event.locationInWindow
            // Convert screen point to view coordinates
            let windowPoint = self.convertPoint(fromScreen: screenPoint)
            let viewPoint = self.highlightView.convert(windowPoint, from: nil)
            DispatchQueue.main.async {
                self.highlightView.addHighlight(at: viewPoint)
            }
        }
    }

    func stopMonitoring() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        highlightView.highlights.removeAll()
        highlightView.needsDisplay = true
    }
}

private class MouseHighlightView: NSView {

    struct Highlight {
        let point: NSPoint
        let time: Date
    }

    var highlights: [Highlight] = []

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()

        for entry in highlights {
            let age = now.timeIntervalSince(entry.time)
            guard age <= 0.3 else { continue }
            let alpha = max(0, 1.0 - age / 0.3)
            let radius: CGFloat = 18 + CGFloat(age) * 60
            let rect = NSRect(
                x: entry.point.x - radius, y: entry.point.y - radius,
                width: radius * 2, height: radius * 2)
            NSColor.systemYellow.withAlphaComponent(0.35 * alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.systemYellow.withAlphaComponent(0.6 * alpha).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2
            ring.stroke()
        }

        if !highlights.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.highlights.removeAll { now.timeIntervalSince($0.time) > 0.3 }
                self.needsDisplay = true
                self.displayIfNeeded()
            }
        }
    }

    func addHighlight(at point: NSPoint) {
        highlights.append(Highlight(point: point, time: Date()))
        needsDisplay = true
        displayIfNeeded()
    }
}
