import Cocoa

/// Handles arrow tool interaction.
/// Same as line but also applies arrow style.
final class ArrowToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .arrow

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let annotation = Annotation(
            tool: .arrow,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .arrow),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.lineStyle = canvas.currentLineStyle
        annotation.arrowStyle = canvas.currentArrowStyle
        annotation.arrowReversed = canvas.arrowReversed
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
