import Cocoa

/// Create a tinted bitmap copy of an SF Symbol image.
private func tintedSymbolCopy(of image: NSImage, color: NSColor) -> NSImage {
    let img = NSImage(size: image.size, flipped: false) { r in
        image.draw(in: r)
        color.setFill()
        r.fill(using: .sourceAtop)
        return true
    }
    img.lockFocus(); img.unlockFocus()
    return img
}

/// Handles pencil (freeform draw) tool interaction.
/// Accumulates points on drag, applies Chaikin smoothing on finish.
/// Optional velocity mode: thinner strokes at high speed, thicker when slow.
final class PencilToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .pencil

    /// Shift-constrain direction for freeform drawing. 0 = undecided, 1 = horizontal, 2 = vertical.
    private var freeformShiftDirection: Int = 0

    // Velocity tracking state
    private var lastPointTime: CFTimeInterval = 0
    private var smoothedVelocity: CGFloat = 0
    private var pointWidths: [CGFloat] = []

    var cursor: NSCursor? {
        Self.penCursor
    }

    private static let penCursor: NSCursor = {
        let size: CGFloat = 25
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let base = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
            return NSCursor.crosshair
        }
        // Pre-tint black and white copies
        let blackImg = tintedSymbolCopy(of: base, color: .black)
        let whiteImg = tintedSymbolCopy(of: base, color: .white)

        let pad: CGFloat = 2
        let outSize = NSSize(width: base.size.width + pad * 2, height: base.size.height + pad * 2)
        let result = NSImage(size: outSize, flipped: false) { _ in
            let drawRect = NSRect(x: pad, y: pad, width: base.size.width, height: base.size.height)
            // Black outline: draw offset in 8 directions
            for ox: CGFloat in [-1, 0, 1] {
                for oy: CGFloat in [-1, 0, 1] {
                    guard ox != 0 || oy != 0 else { continue }
                    blackImg.draw(in: drawRect.offsetBy(dx: ox, dy: oy))
                }
            }
            // White foreground
            whiteImg.draw(in: drawRect)
            return true
        }
        result.lockFocus(); result.unlockFocus()
        return NSCursor(image: result, hotSpot: NSPoint(x: pad + 2, y: result.size.height - pad - 2))
    }()

    // MARK: - AnnotationToolHandler

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        freeformShiftDirection = 0
        lastPointTime = CACurrentMediaTime()
        smoothedVelocity = 0
        pointWidths = [canvas.currentStrokeWidth]

        let annotation = Annotation(
            tool: .pencil,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .pencil),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.points = [point]
        annotation.lineStyle = canvas.currentLineStyle
        if canvas.pencilVelocityEnabled {
            annotation.pointWidths = pointWidths
        }
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            let refPoint = annotation.points?.last ?? annotation.startPoint
            let dx = clampedPoint.x - refPoint.x
            let dy = clampedPoint.y - refPoint.y

            if freeformShiftDirection == 0 && hypot(dx, dy) > 5 {
                freeformShiftDirection = abs(dx) >= abs(dy) ? 1 : 2
            }
            if freeformShiftDirection == 1 {
                clampedPoint = NSPoint(x: clampedPoint.x, y: annotation.startPoint.y)
            } else if freeformShiftDirection == 2 {
                clampedPoint = NSPoint(x: annotation.startPoint.x, y: clampedPoint.y)
            } else {
                clampedPoint = annotation.startPoint
            }
        }

        // No snap guides for freeform tools
        canvas.snapGuideX = nil
        canvas.snapGuideY = nil

        annotation.endPoint = clampedPoint
        annotation.points?.append(clampedPoint)

        // Velocity-based width
        if canvas.pencilVelocityEnabled {
            let now = CACurrentMediaTime()
            let dt = now - lastPointTime
            lastPointTime = now

            let prevPoint = annotation.points!.count >= 2
                ? annotation.points![annotation.points!.count - 2]
                : clampedPoint
            let dist = hypot(clampedPoint.x - prevPoint.x, clampedPoint.y - prevPoint.y)
            let velocity = dt > 0.0001 ? dist / CGFloat(dt) : 0

            // Smooth the velocity to avoid jittery width changes
            let smoothing: CGFloat = 0.6
            smoothedVelocity = smoothedVelocity * (1 - smoothing) + velocity * smoothing

            // Map velocity to width: slow = slightly thicker, fast = slightly thinner
            let baseWidth = canvas.currentStrokeWidth
            let minWidth = baseWidth * 0.6
            let maxWidth = baseWidth * 1.3
            // Normalize: ~0 velocity = max width, ~1500+ px/s = min width
            let t = min(1.0, smoothedVelocity / 1500)
            let width = maxWidth - t * (maxWidth - minWidth)

            pointWidths.append(width)
            annotation.pointWidths = pointWidths
        }
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        guard let points = annotation.points, !points.isEmpty else {
            canvas.activeAnnotation = nil
            return
        }

        // Single click: duplicate the point so drawFreeform renders a dot
        if points.count < 3, let p = points.first {
            annotation.points = [p, p, p]
            if canvas.pencilVelocityEnabled {
                let w = pointWidths.first ?? canvas.currentStrokeWidth
                annotation.pointWidths = [w, w, w]
            }
        } else if canvas.pencilSmoothEnabled {
            let smoothed = Self.chaikinSmooth(points, iterations: 2)
            annotation.points = smoothed
            // Interpolate widths to match smoothed points
            if canvas.pencilVelocityEnabled, let widths = annotation.pointWidths {
                annotation.pointWidths = Self.interpolateWidths(widths, to: smoothed.count)
            }
        }

        // Smooth the widths array to eliminate abrupt jumps, then taper ends
        if canvas.pencilVelocityEnabled, let widths = annotation.pointWidths, widths.count > 2 {
            var smoothed = Self.smoothWidths(widths, passes: 3)
            Self.applyTaper(&smoothed)
            annotation.pointWidths = smoothed
        }

        commitAnnotation(annotation, canvas: canvas)
        freeformShiftDirection = 0
        pointWidths = []
        smoothedVelocity = 0
    }

    // MARK: - Smoothing

    /// Chaikin corner-cutting: each iteration replaces every segment with two points
    /// at 25% and 75% along it, keeping endpoints fixed. 2 passes gives gentle smoothing.
    static func chaikinSmooth(_ pts: [NSPoint], iterations: Int) -> [NSPoint] {
        guard pts.count > 2 else { return pts }
        var result = pts
        for _ in 0..<iterations {
            var next: [NSPoint] = [result[0]]
            for i in 0..<result.count - 1 {
                let p0 = result[i]
                let p1 = result[i + 1]
                next.append(NSPoint(x: 0.75 * p0.x + 0.25 * p1.x, y: 0.75 * p0.y + 0.25 * p1.y))
                next.append(NSPoint(x: 0.25 * p0.x + 0.75 * p1.x, y: 0.25 * p0.y + 0.75 * p1.y))
            }
            next.append(result[result.count - 1])
            result = next
        }
        return result
    }

    /// Taper the end of the stroke to a point. Uses last ~12 points.
    private static func applyTaper(_ widths: inout [CGFloat]) {
        let count = widths.count
        guard count > 4 else { return }
        let taperLen = min(12, count / 2)
        for i in 0..<taperLen {
            let t = CGFloat(i) / CGFloat(taperLen)
            let scale = t * t  // quadratic ease: 0 at tip, 1 at full width
            widths[count - 1 - i] *= scale
        }
    }

    /// Moving-average smoothing on widths to eliminate abrupt transitions.
    private static func smoothWidths(_ widths: [CGFloat], passes: Int) -> [CGFloat] {
        var result = widths
        for _ in 0..<passes {
            var next = result
            for i in 1..<result.count - 1 {
                next[i] = (result[i - 1] + result[i] + result[i + 1]) / 3
            }
            result = next
        }
        return result
    }

    /// Linearly interpolate a widths array to a new count (for matching Chaikin-smoothed points).
    private static func interpolateWidths(_ widths: [CGFloat], to count: Int) -> [CGFloat] {
        guard widths.count >= 2, count >= 2 else { return Array(repeating: widths.first ?? 1, count: count) }
        var result: [CGFloat] = []
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(count - 1) * CGFloat(widths.count - 1)
            let lo = Int(t)
            let hi = min(lo + 1, widths.count - 1)
            let frac = t - CGFloat(lo)
            result.append(widths[lo] * (1 - frac) + widths[hi] * frac)
        }
        return result
    }
}
