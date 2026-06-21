import Cocoa

/// Handles loupe (magnifying glass) tool interaction.
/// Click-to-place: a single loupe that magnifies the region under itself.
/// Click + drag: a rooted two-circle magnifier (#197) — the source circle stays
/// at the click point, the magnified lens follows the drag, connected by a line.
final class LoupeToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .loupe

    /// The point where the press started (the rooted source spot if the user drags).
    private var anchorPoint: NSPoint = .zero
    /// Whether the current gesture has become a drag (two-circle mode).
    private var didDrag = false

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        anchorPoint = point
        didDrag = false
        let size = canvas.currentLoupeSize
        let annotation = Annotation(
            tool: .loupe,
            startPoint: NSPoint(x: point.x - size / 2, y: point.y - size / 2),
            endPoint: NSPoint(x: point.x + size / 2, y: point.y + size / 2),
            color: canvas.currentColor,
            strokeWidth: size
        )
        annotation.loupeMagnification = canvas.currentLoupeMagnification
        annotation.outlineColor = canvas.currentLoupeOutlineColor
        annotation.loupeOutlineEnabled = canvas.currentLoupeOutlineEnabled
        annotation.sourceImage = canvas.screenshotImage
        annotation.sourceImageBounds = canvas.captureDrawRect
        annotation.bakeLoupe()
        // Active (not instant-commit) so a drag can turn it into a two-circle loupe.
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        let dist = hypot(point.x - anchorPoint.x, point.y - anchorPoint.y)
        // Threshold to distinguish a click from a drag.
        guard dist > 6 else {
            if didDrag {
                // Drag collapsed back near the anchor — revert to single loupe.
                didDrag = false
                annotation.loupeSourceRect = nil
                let size = canvas.currentLoupeSize
                annotation.startPoint = NSPoint(x: anchorPoint.x - size / 2, y: anchorPoint.y - size / 2)
                annotation.endPoint = NSPoint(x: anchorPoint.x + size / 2, y: anchorPoint.y + size / 2)
                annotation.bakedBlurNSImage = nil
                annotation.bakeLoupe()
                canvas.setNeedsDisplay()
            }
            return
        }

        didDrag = true
        let lensSize = canvas.currentLoupeSize
        let mag = max(1.1, canvas.currentLoupeMagnification)
        // Source circle: rooted at the press point, sized so it shows exactly the
        // region the lens magnifies (lensSize / magnification).
        let srcSize = lensSize / mag
        annotation.loupeSourceRect = NSRect(
            x: anchorPoint.x - srcSize / 2, y: anchorPoint.y - srcSize / 2,
            width: srcSize, height: srcSize)
        // Lens follows the pointer, at the loupe Size.
        annotation.startPoint = NSPoint(x: point.x - lensSize / 2, y: point.y - lensSize / 2)
        annotation.endPoint = NSPoint(x: point.x + lensSize / 2, y: point.y + lensSize / 2)
        annotation.bakedBlurNSImage = nil
        annotation.bakeLoupe()
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        annotation.bakedBlurNSImage = nil
        annotation.bakeLoupe()
        commitAnnotation(annotation, canvas: canvas)
    }
}
