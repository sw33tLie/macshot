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
final class PencilToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .pencil

    /// Shift-constrain direction for freeform drawing. 0 = undecided, 1 = horizontal, 2 = vertical.
    private var freeformShiftDirection: Int = 0

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
        let blackImg = tintedSymbolCopy(of: base, color: .black)
        let whiteImg = tintedSymbolCopy(of: base, color: .white)

        let pad: CGFloat = 2
        let outSize = NSSize(width: base.size.width + pad * 2, height: base.size.height + pad * 2)
        let result = NSImage(size: outSize, flipped: false) { _ in
            let drawRect = NSRect(x: pad, y: pad, width: base.size.width, height: base.size.height)
            for ox: CGFloat in [-1, 0, 1] {
                for oy: CGFloat in [-1, 0, 1] {
                    guard ox != 0 || oy != 0 else { continue }
                    blackImg.draw(in: drawRect.offsetBy(dx: ox, dy: oy))
                }
            }
            whiteImg.draw(in: drawRect)
            return true
        }
        result.lockFocus(); result.unlockFocus()
        return NSCursor(image: result, hotSpot: NSPoint(x: pad + 2, y: result.size.height - pad - 2))
    }()

    // MARK: - AnnotationToolHandler

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        freeformShiftDirection = 0
        let annotation = Annotation(
            tool: .pencil,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .pencil),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.points = [point]
        annotation.lineStyle = canvas.currentLineStyle
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
        } else if canvas.pencilSmoothEnabled {
            annotation.points = Self.chaikinSmooth(points, iterations: 2)
        }

        commitAnnotation(annotation, canvas: canvas)
        freeformShiftDirection = 0
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
}
