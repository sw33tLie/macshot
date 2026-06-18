import Cocoa

/// Handles the highlight (spotlight) tool: drag a rectangle to keep that region
/// bright while everything OUTSIDE it is dimmed. Shift-constrains to a square.
///
/// Unlike censor (pixelate/blur), highlight bakes nothing and holds no source
/// image — the dimming is rendered globally as a single union pass over all
/// highlight rects (see `Annotation.drawHighlightDim`). Each highlight
/// annotation only carries its rect + `dimOpacity`.
final class HighlightToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .highlight

    static let dimOpacityKey = "highlightDimOpacity"

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        let annotation = Annotation(
            tool: .highlight,
            startPoint: point,
            endPoint: point,
            // The dim is black; the global color/opacity doesn't apply. Color is
            // stored but unused for the dim (kept opaque black for the border).
            color: .black,
            strokeWidth: canvas.currentStrokeWidth
        )
        let stored = UserDefaults.standard.object(forKey: Self.dimOpacityKey) as? Double
        annotation.dimOpacity = stored.map { CGFloat($0) } ?? 0.55
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
        // Commit WITHOUT the incremental cache append used by the default
        // commitAnnotation: the dim is a global union pass over ALL highlight
        // rects, so the whole annotation layer must rebuild (appending only this
        // highlight's border would skip the dim). Appending to `annotations`
        // already invalidates the cache, so the next draw rebuilds fully.
        canvas.annotations.append(annotation)
        canvas.undoStack.append(.added(annotation))
        canvas.redoStack.removeAll()
        canvas.activeAnnotation = nil
        canvas.snapGuideX = nil
        canvas.snapGuideY = nil
        canvas.setNeedsDisplay()
    }

    var cursor: NSCursor? { .crosshair }
}
