import Cocoa

/// Pure geometry and persistence for the webcam bubble: corner placement,
/// clamping to the recorded area, snapping and resizing. Frames are square
/// and in screen coordinates (AppKit, bottom-left origin).
enum WebcamPlacement {
    /// Gap between the bubble and the edge of the recorded area.
    static let padding: CGFloat = 12
    /// Distance from a corner slot at which a released bubble snaps into it.
    static let snapThreshold: CGFloat = 24

    static let freeCenterKey = "webcamFreeCenter"
    static let snapKey = "webcamSnapToCorners"

    // MARK: Geometry

    /// Largest side that fits inside `bounds` with padding on both sides.
    static func maximumSize(in bounds: NSRect) -> CGFloat {
        max(1, min(bounds.width, bounds.height) - padding * 2)
    }

    /// Side clamped to the allowed range and to what fits inside `bounds`.
    static func fittedSize(_ size: CGFloat, in bounds: NSRect) -> CGFloat {
        min(min(max(size, WebcamSize.minPoints), WebcamSize.maxPoints), maximumSize(in: bounds))
    }

    static func cornerFrame(_ position: WebcamPosition, size s: CGFloat, in bounds: NSRect) -> NSRect {
        let origin: NSPoint
        switch position {
        case .bottomRight: origin = NSPoint(x: bounds.maxX - s - padding, y: bounds.minY + padding)
        case .bottomLeft: origin = NSPoint(x: bounds.minX + padding, y: bounds.minY + padding)
        case .topRight: origin = NSPoint(x: bounds.maxX - s - padding, y: bounds.maxY - s - padding)
        case .topLeft: origin = NSPoint(x: bounds.minX + padding, y: bounds.maxY - s - padding)
        }
        return NSRect(origin: origin, size: NSSize(width: s, height: s))
    }

    /// Moves `frame` so it lies fully inside `bounds` (inset by the padding).
    static func clamped(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        let inner = bounds.insetBy(dx: padding, dy: padding)
        var f = frame
        if f.width >= inner.width { f.origin.x = inner.midX - f.width / 2 } else {
            f.origin.x = min(max(f.origin.x, inner.minX), inner.maxX - f.width)
        }
        if f.height >= inner.height { f.origin.y = inner.midY - f.height / 2 } else {
            f.origin.y = min(max(f.origin.y, inner.minY), inner.maxY - f.height)
        }
        return f
    }

    /// The corner slot `frame` is close enough to snap into, if any.
    static func snapCorner(for frame: NSRect, in bounds: NSRect,
                           threshold: CGFloat = snapThreshold) -> WebcamPosition? {
        let corners: [WebcamPosition] = [.bottomRight, .bottomLeft, .topRight, .topLeft]
        var best: (WebcamPosition, CGFloat)?
        for corner in corners {
            let slot = cornerFrame(corner, size: frame.width, in: bounds)
            let distance = hypot(slot.minX - frame.minX, slot.minY - frame.minY)
            if distance <= threshold, distance < (best?.1 ?? .infinity) { best = (corner, distance) }
        }
        return best?.0
    }

    /// Frame of side `size` centered on `center`, clamped into `bounds`.
    static func frame(center: NSPoint, size: CGFloat, in bounds: NSRect) -> NSRect {
        let s = fittedSize(size, in: bounds)
        return clamped(NSRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s), to: bounds)
    }

    /// Resizes `frame` to `size` keeping the corner at `anchor` (a corner of
    /// `frame`) fixed, then clamps into `bounds`.
    static func resized(_ frame: NSRect, to size: CGFloat, keeping anchor: NSPoint, in bounds: NSRect) -> NSRect {
        let s = fittedSize(size, in: bounds)
        let x = anchor.x <= frame.midX ? anchor.x : anchor.x - s
        let y = anchor.y <= frame.midY ? anchor.y : anchor.y - s
        return clamped(NSRect(x: x, y: y, width: s, height: s), to: bounds)
    }

    /// Direction (±1, ±1) from the bubble toward the inside of `bounds`:
    /// the resize handle sits on that side so it never ends up off-area.
    static func handleDirection(for frame: NSRect, in bounds: NSRect) -> CGVector {
        CGVector(dx: frame.midX <= bounds.midX ? 1 : -1, dy: frame.midY <= bounds.midY ? 1 : -1)
    }

    // MARK: Normalized center (relative to the recorded area)

    static func normalizedCenter(of frame: NSRect, in bounds: NSRect) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let x = (frame.midX - bounds.minX) / bounds.width
        let y = (frame.midY - bounds.minY) / bounds.height
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    static func center(fromNormalized p: CGPoint, in bounds: NSRect) -> NSPoint {
        NSPoint(x: bounds.minX + p.x * bounds.width, y: bounds.minY + p.y * bounds.height)
    }

    // MARK: Persistence

    static var snapsToCorners: Bool {
        UserDefaults.standard.object(forKey: snapKey) as? Bool ?? true
    }

    static var savedPosition: WebcamPosition {
        WebcamPosition(rawValue: UserDefaults.standard.string(forKey: "webcamPosition") ?? "") ?? .bottomRight
    }

    /// A freely dragged position, when the bubble isn't in a corner slot.
    static var savedFreeCenter: CGPoint? {
        guard let values = UserDefaults.standard.array(forKey: freeCenterKey) as? [NSNumber],
              values.count == 2 else { return nil }
        let x = values[0].doubleValue, y = values[1].doubleValue
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    static func saveCorner(_ position: WebcamPosition) {
        UserDefaults.standard.set(position.rawValue, forKey: "webcamPosition")
        clearFreeCenter()
    }

    static func saveFreeCenter(_ p: CGPoint) {
        UserDefaults.standard.set([Double(p.x), Double(p.y)], forKey: freeCenterKey)
    }

    static func clearFreeCenter() {
        UserDefaults.standard.removeObject(forKey: freeCenterKey)
    }
}
