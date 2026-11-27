import Cocoa

/// Move area: drag a rectangle over the screenshot, then drag the pixels inside
/// it somewhere else. The hole left behind is filled from the colors around it.
///
/// The committed annotation starts in place (source == destination) and is
/// selected, so the next drag moves the pixels with the normal annotation drag.
/// Its rect is the destination; `moveSourceRect` stays where the pixels came from.
final class MoveAreaToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .moveArea

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let annotation = Annotation(
            tool: .moveArea,
            startPoint: point,
            endPoint: point,
            color: canvas.currentColor,
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.sourceImage = canvas.screenshotImage
        annotation.sourceImageBounds = canvas.captureDrawRect
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        if shiftHeld {
            annotation.endPoint = snapSquare(point, from: annotation.startPoint)
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
        } else {
            annotation.endPoint = canvas.snapPoint(point, excluding: annotation)
        }
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        // Only the part over the image can be moved.
        let rect = annotation.boundingRect.intersection(canvas.captureDrawRect).integral
        guard rect.width > 4, rect.height > 4 else {
            canvas.activeAnnotation = nil
            canvas.snapGuideX = nil
            canvas.snapGuideY = nil
            canvas.setNeedsDisplay()
            return
        }
        annotation.startPoint = NSPoint(x: rect.minX, y: rect.minY)
        annotation.endPoint = NSPoint(x: rect.maxX, y: rect.maxY)
        annotation.moveSourceRect = rect
        annotation.bakeMoveArea()
        guard annotation.stampImage != nil else {
            canvas.activeAnnotation = nil
            canvas.setNeedsDisplay()
            return
        }
        commitAnnotation(annotation, canvas: canvas)
        canvas.selectCommittedAnnotation(annotation)
    }

    var cursor: NSCursor? { .crosshair }
}
