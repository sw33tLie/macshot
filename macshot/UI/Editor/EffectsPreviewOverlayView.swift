import Cocoa

/// Floating overlay that sits on top of the AVPlayerView and lets the user
/// drag/resize a rectangle that defines a zoom or censor region directly on
/// the live preview. The rectangle is always expressed in normalized video
/// coordinates (origin top-left, y=0 at top) so it stays consistent with how
/// VideoZoomSegment.center and VideoCensorSegment.rect are stored.
///
/// The overlay view spans the entire player view's bounds. Because the video
/// is rendered with AVPlayerLayer's default `.resizeAspect`, the actual video
/// rect inside our bounds is typically letterboxed — we compute that
/// sub-rect from the natural video aspect ratio and only accept mouse
/// events inside it.
@MainActor
final class EffectsPreviewOverlayView: NSView {

    enum Kind {
        case zoom
        case censor(VideoCensorSegment.Style)
    }

    /// The selection currently shown, or `nil` to hide the overlay.
    struct Selection {
        let kind: Kind
        /// Normalized (0..1) rect in video space, origin top-left.
        let rect: CGRect
    }

    var selection: Selection? {
        didSet { needsDisplay = true }
    }

    /// Natural (orientation-applied) video dimensions. Needed to compute
    /// where the video sits inside the player view when the aspect ratios
    /// don't match (letterbox bars).
    var videoSize: CGSize = .zero {
        didSet { needsDisplay = true }
    }

    /// Fires on every drag/resize with the new normalized rect. Controller
    /// is responsible for clamping, writing to the model, and triggering a
    /// composition rebuild.
    var onChange: ((CGRect) -> Void)?

    // MARK: - Drag state

    private enum DragMode {
        case moveBody(grabOffset: NSPoint)       // view-space offset from rect origin to grab
        case resize(corner: Corner)
    }
    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }

    private var dragMode: DragMode?
    private var rectAtDragStart: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Transparent so the video shows through; we only draw the rect.
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    // Let clicks pass through when we're not over our selection rect, so the
    // user can still interact with the AVPlayerView (e.g. trackpad gestures).
    //
    // NSView hitTest(_:) receives its point in the *superview's* coordinate
    // space. Our stored rect is in our own (local) coords, so convert first
    // or we'll get wrong answers whenever our frame origin isn't (0, 0).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let selection = selection else { return nil }
        let localPoint = superview?.convert(point, to: self) ?? point
        let r = viewRect(from: selection.rect)
        let inflated = r.insetBy(dx: -handleHitSlop, dy: -handleHitSlop)
        return inflated.contains(localPoint) ? super.hitTest(point) : nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let selection = selection else { return }
        let rect = viewRect(from: selection.rect)
        guard rect.width > 2, rect.height > 2 else { return }

        let color: NSColor = {
            switch selection.kind {
            case .zoom:    return NSColor(calibratedRed: 0.25, green: 0.55, blue: 1.0, alpha: 1.0)
            case .censor:  return NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 1.0)
            }
        }()

        // Dim outside the rect for zoom (so the zoom target is the "bright"
        // area) — skip for censor since the censor content itself is shown.
        if case .zoom = selection.kind {
            NSColor.black.withAlphaComponent(0.45).setFill()
            let outer = NSBezierPath(rect: videoRectInView())
            outer.append(NSBezierPath(rect: rect).reversed)
            outer.windingRule = .evenOdd
            outer.fill()
        }

        // Fill tint inside the rect
        switch selection.kind {
        case .zoom:
            NSColor.clear.setFill()  // leave clear so user sees what will be zoomed
        case .censor:
            color.withAlphaComponent(0.15).setFill()
            NSBezierPath(rect: rect).fill()
        }

        // Border
        color.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 2
        border.stroke()

        // 8 handles
        for p in handlePositions(in: rect) {
            let handle = NSRect(x: p.x - handleSize/2, y: p.y - handleSize/2,
                                 width: handleSize, height: handleSize)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: handle).fill()
            color.setStroke()
            let outline = NSBezierPath(ovalIn: handle.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let selection = selection else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = viewRect(from: selection.rect)
        rectAtDragStart = selection.rect

        if let corner = hitCorner(point: p, in: r) {
            dragMode = .resize(corner: corner)
        } else if r.contains(p) {
            dragMode = .moveBody(grabOffset: NSPoint(x: p.x - r.minX, y: p.y - r.minY))
        } else {
            dragMode = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mode = dragMode, let selection = selection else { return }
        let p = convert(event.locationInWindow, from: nil)
        let originalView = viewRect(from: rectAtDragStart)
        let videoR = videoRectInView()

        var newRect: NSRect
        switch mode {
        case .moveBody(let grabOffset):
            var nx = p.x - grabOffset.x
            var ny = p.y - grabOffset.y
            nx = max(videoR.minX, min(videoR.maxX - originalView.width, nx))
            ny = max(videoR.minY, min(videoR.maxY - originalView.height, ny))
            newRect = NSRect(x: nx, y: ny, width: originalView.width, height: originalView.height)

        case .resize(let corner):
            newRect = resizedRect(from: originalView, corner: corner, to: p)
            // Clamp to video bounds
            let xLo = max(videoR.minX, newRect.minX)
            let yLo = max(videoR.minY, newRect.minY)
            let xHi = min(videoR.maxX, newRect.maxX)
            let yHi = min(videoR.maxY, newRect.maxY)
            newRect = NSRect(x: xLo, y: yLo, width: max(0, xHi - xLo), height: max(0, yHi - yLo))
        }

        let normalized = normalize(newRect)
        // Update our own displayed rect immediately so the user sees the
        // resize/move live. The controller writes to the model separately;
        // it won't push back to us because the rect is already up-to-date.
        self.selection = Selection(kind: selection.kind, rect: normalized)
        onChange?(normalized)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
    }

    // MARK: - Geometry

    /// The rendered video rect inside our bounds (honoring resizeAspect
    /// letterboxing). If videoSize is zero or bounds are empty returns .zero.
    private func videoRectInView() -> NSRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let viewAspect = bounds.width / bounds.height
        let videoAspect = videoSize.width / videoSize.height
        if viewAspect > videoAspect {
            let h = bounds.height
            let w = h * videoAspect
            return NSRect(x: (bounds.width - w) / 2, y: 0, width: w, height: h)
        } else {
            let w = bounds.width
            let h = w / videoAspect
            return NSRect(x: 0, y: (bounds.height - h) / 2, width: w, height: h)
        }
    }

    /// Normalized video rect (y-top) → view-space rect (y-bottom).
    private func viewRect(from n: CGRect) -> NSRect {
        let video = videoRectInView()
        guard video.width > 0, video.height > 0 else { return .zero }
        let x = video.minX + n.origin.x * video.width
        let y = video.minY + (1 - (n.origin.y + n.size.height)) * video.height
        let w = n.size.width * video.width
        let h = n.size.height * video.height
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// View-space rect (y-bottom) → normalized video rect (y-top), clamped
    /// into [0, 1] and into the video-visible area.
    private func normalize(_ rect: NSRect) -> CGRect {
        let video = videoRectInView()
        guard video.width > 0, video.height > 0 else { return .zero }
        // Clamp into video rect
        let xLo = max(video.minX, min(video.maxX, rect.minX))
        let yLo = max(video.minY, min(video.maxY, rect.minY))
        let xHi = max(video.minX, min(video.maxX, rect.maxX))
        let yHi = max(video.minY, min(video.maxY, rect.maxY))
        let w = max(0, xHi - xLo)
        let h = max(0, yHi - yLo)
        // Normalize
        let nx = (xLo - video.minX) / video.width
        let nyBottom = (yLo - video.minY) / video.height
        let nw = w / video.width
        let nh = h / video.height
        // Flip y: in view coords yLo is the BOTTOM edge, but we want the TOP
        // edge for the normalized y (y=0 at image top).
        let ny = 1 - nyBottom - nh
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }

    // MARK: - Hit testing

    private let handleSize: CGFloat = 10
    private let handleHitSlop: CGFloat = 12

    private func handlePositions(in r: NSRect) -> [NSPoint] {
        return [
            NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
            NSPoint(x: r.maxX, y: r.midY), NSPoint(x: r.maxX, y: r.maxY),
            NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.minX, y: r.midY),
        ]
    }

    private func hitCorner(point p: NSPoint, in rect: NSRect) -> Corner? {
        let t = handleHitSlop
        let nearLeft = abs(p.x - rect.minX) < t
        let nearRight = abs(p.x - rect.maxX) < t
        let nearTop = abs(p.y - rect.maxY) < t
        let nearBottom = abs(p.y - rect.minY) < t
        let withinX = p.x >= rect.minX - t && p.x <= rect.maxX + t
        let withinY = p.y >= rect.minY - t && p.y <= rect.maxY + t
        if nearLeft && nearTop && withinX && withinY { return .topLeft }
        if nearRight && nearTop && withinX && withinY { return .topRight }
        if nearLeft && nearBottom && withinX && withinY { return .bottomLeft }
        if nearRight && nearBottom && withinX && withinY { return .bottomRight }
        if nearTop && withinX { return .top }
        if nearBottom && withinX { return .bottom }
        if nearLeft && withinY { return .left }
        if nearRight && withinY { return .right }
        return nil
    }

    private func resizedRect(from original: NSRect, corner: Corner, to p: NSPoint) -> NSRect {
        var minX = original.minX, maxX = original.maxX
        var minY = original.minY, maxY = original.maxY
        switch corner {
        case .topLeft:     minX = p.x; maxY = p.y
        case .top:         maxY = p.y
        case .topRight:    maxX = p.x; maxY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom:      minY = p.y
        case .bottomLeft:  minX = p.x; minY = p.y
        case .left:        minX = p.x
        }
        let xLo = min(minX, maxX), xHi = max(minX, maxX)
        let yLo = min(minY, maxY), yHi = max(minY, maxY)
        return NSRect(x: xLo, y: yLo, width: xHi - xLo, height: yHi - yLo)
    }
}
