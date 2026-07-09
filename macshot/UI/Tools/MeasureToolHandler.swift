import Cocoa

/// Handles measure (pixel ruler) tool interaction.
/// Draws a measurement line with shift-constrain to 45° angles and snap guides.
final class MeasureToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .measure

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let origin = canvas.currentMeasureClampToSelection
            ? point.clampedToRect(canvas.selectionRect) : point
        let annotation = Annotation(
            tool: .measure,
            startPoint: origin,
            endPoint: origin,
            color: canvas.opacityAppliedColor(for: .measure),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.measureInPoints = canvas.currentMeasureInPoints
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            clampedPoint = snap45(point, from: annotation.startPoint)
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
        } else {
            clampedPoint = canvas.snapPoint(point, excluding: annotation)
        }

        if canvas.currentMeasureClampToSelection {
            // With shift's 45° snap active, clamping x/y independently would
            // bend the ray at the selection edge — shorten along the ray instead.
            clampedPoint = shiftHeld
                ? clampedPoint.clampedAlongRay(from: annotation.startPoint, in: canvas.selectionRect)
                : clampedPoint.clampedToRect(canvas.selectionRect)
        }

        annotation.endPoint = clampedPoint
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        let dx = abs(annotation.endPoint.x - annotation.startPoint.x)
        let dy = abs(annotation.endPoint.y - annotation.startPoint.y)
        guard dx > 2 || dy > 2 else {
            canvas.activeAnnotation = nil
            canvas.setNeedsDisplay()
            return
        }
        commitAnnotation(annotation, canvas: canvas)
    }
}

// Internal (not fileprivate): OverlayView reuses these to clamp the other two
// measure geometry paths — auto-measure (hold 1/2) and endpoint handle resize.
extension NSPoint {
    func clampedToRect(_ rect: NSRect) -> NSPoint {
        NSPoint(x: min(max(x, rect.minX), rect.maxX),
                y: min(max(y, rect.minY), rect.maxY))
    }

    /// Shorten the segment start→self so it stays inside rect without
    /// changing its direction (start must already be inside rect).
    func clampedAlongRay(from start: NSPoint, in rect: NSRect) -> NSPoint {
        let dx = x - start.x
        let dy = y - start.y
        var t: CGFloat = 1
        if dx > 0 { t = min(t, (rect.maxX - start.x) / dx) }
        else if dx < 0 { t = min(t, (rect.minX - start.x) / dx) }
        if dy > 0 { t = min(t, (rect.maxY - start.y) / dy) }
        else if dy < 0 { t = min(t, (rect.minY - start.y) / dy) }
        t = max(0, t)
        return NSPoint(x: start.x + dx * t, y: start.y + dy * t)
    }
}
