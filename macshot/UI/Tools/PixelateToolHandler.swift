import Cocoa

/// Handles the unified censor tool (pixelate, blur, solid).
/// Mode is read from UserDefaults "censorMode". Shift-constrains to square.
/// Captures composited image source for pixelate/blur baking.
final class PixelateToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .pixelate

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let mode = CensorMode(rawValue: UserDefaults.standard.integer(forKey: "censorMode")) ?? .pixelate
        let annotation = Annotation(
            tool: .pixelate,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .pixelate),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.censorMode = mode
        // Solid mode doesn't need a source image; all others do
        if mode != .solid {
            annotation.sourceImage = canvas.screenshotImage
            annotation.sourceImageBounds = canvas.captureDrawRect
        }
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            clampedPoint = snapSquare(point, from: annotation.startPoint)
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

        if UserDefaults.standard.bool(forKey: "censorTextOnly") {
            let drawnRect = annotation.boundingRect
            let sourceImg = annotation.sourceImage
            let sourceImgBounds = annotation.sourceImageBounds
            canvas.activeAnnotation = nil
            canvas.setNeedsDisplay()
            guard let screenshot = canvas.screenshotImage else { return }
            AutoRedactor.redactAllText(
                screenshot: screenshot, selectionRect: drawnRect,
                captureDrawRect: canvas.captureDrawRect,
                redactTool: .pixelate, color: canvas.currentColor,
                sourceImage: sourceImg, sourceImageBounds: sourceImgBounds
            ) { [weak canvas] anns in
                guard let canvas = canvas, !anns.isEmpty else { return }
                canvas.annotations.append(contentsOf: anns)
                canvas.undoStack.append(contentsOf: anns.map { .added($0) })
                canvas.redoStack.removeAll()
                canvas.setNeedsDisplay()
            }
        } else {
            commitAnnotation(annotation, canvas: canvas)
        }
    }
}
