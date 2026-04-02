import Cocoa
import Vision

/// Handles marker/highlighter tool interaction.
/// Accumulates freeform points on drag, semi-transparent wide stroke.
/// Smart mode: detects text lines via Vision OCR and snaps the marker to cover them with a straight highlight.
final class MarkerToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .marker

    /// Shift-constrain direction for freeform drawing. 0 = undecided, 1 = horizontal, 2 = vertical.
    private var freeformShiftDirection: Int = 0

    /// Cached OCR observations for the current selection, to avoid re-running OCR on every stroke.
    private var cachedObservations: [VNRecognizedTextObservation]?
    private var cachedSelectionRect: NSRect = .zero

    var cursor: NSCursor? {
        Self.penCursor
    }

    private static let penCursor: NSCursor = {
        let size: CGFloat = 20
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let img = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
            return NSCursor.crosshair
        }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            NSColor.white.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        return NSCursor(image: tinted, hotSpot: NSPoint(x: 2, y: tinted.size.height - 2))
    }()

    /// Cursor for smart marker mode — vertical pill shape (taller than wide, like a marker tip).
    private static let smartCursor: NSCursor = {
        let w: CGFloat = 12
        let h: CGFloat = 22
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let pill = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: w - 2, height: h - 2),
                                    xRadius: (w - 2) / 2, yRadius: (w - 2) / 2)
            NSColor.yellow.withAlphaComponent(0.5).setFill()
            pill.fill()
            NSColor.yellow.withAlphaComponent(0.9).setStroke()
            pill.lineWidth = 1.0
            pill.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: w / 2, y: h / 2))
    }()

    func cursorForCanvas(_ canvas: AnnotationCanvas) -> NSCursor? {
        canvas.smartMarkerEnabled ? Self.smartCursor : Self.penCursor
    }

    // MARK: - AnnotationToolHandler

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        freeformShiftDirection = 0
        let annotation = Annotation(
            tool: .marker,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .marker),
            strokeWidth: canvas.currentMarkerSize
        )
        annotation.points = [point]
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        var clampedPoint = point

        if shiftHeld || canvas.smartMarkerEnabled {
            // Smart marker always constrains to horizontal
            let refPoint = annotation.points?.last ?? annotation.startPoint
            let dx = clampedPoint.x - refPoint.x
            let dy = clampedPoint.y - refPoint.y

            if canvas.smartMarkerEnabled {
                // Always horizontal for smart marker
                clampedPoint = NSPoint(x: clampedPoint.x, y: annotation.startPoint.y)
            } else {
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
        }

        if canvas.smartMarkerEnabled {
            // Smart marker: find text lines under the stroke and snap to them
            snapToTextLines(annotation: annotation, canvas: canvas)
        } else {
            // Update marker preview position so it doesn't jump back to the pre-drag location
            if let lastPt = annotation.points?.last {
                canvas.markerCursorPoint = lastPt
            }
            commitAnnotation(annotation, canvas: canvas)
        }
        freeformShiftDirection = 0
    }

    // MARK: - Smart marker OCR snapping

    private func snapToTextLines(annotation: Annotation, canvas: AnnotationCanvas) {
        guard let screenshot = canvas.screenshotImage else {
            commitAnnotation(annotation, canvas: canvas)
            return
        }

        let selectionRect = canvas.selectionRect
        let captureDrawRect = canvas.captureDrawRect

        // Build the stroke's bounding rect (with generous vertical padding for text detection)
        guard let points = annotation.points, let firstPt = points.first else {
            commitAnnotation(annotation, canvas: canvas)
            return
        }
        let minX = points.map(\.x).min()!
        let maxX = points.map(\.x).max()!
        let strokeY = firstPt.y  // horizontal line, Y is constant

        // Use cached observations if selection hasn't changed
        if cachedObservations != nil && cachedSelectionRect == selectionRect {
            applySmartSnap(annotation: annotation, observations: cachedObservations!,
                           strokeMinX: minX, strokeMaxX: maxX, strokeY: strokeY,
                           selectionRect: selectionRect, canvas: canvas)
            return
        }

        // Crop selection to CGImage for OCR
        let regionImage = NSImage(size: selectionRect.size, flipped: false) { _ in
            screenshot.draw(in: NSRect(x: -selectionRect.origin.x, y: -selectionRect.origin.y,
                                        width: captureDrawRect.width, height: captureDrawRect.height),
                            from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            commitAnnotation(annotation, canvas: canvas)
            return
        }

        let request = VisionOCR.makeTextRecognitionRequest { [weak self, weak canvas] request, _ in
            guard let self = self, let canvas = canvas else { return }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            DispatchQueue.main.async {
                self.cachedObservations = observations
                self.cachedSelectionRect = selectionRect
                self.applySmartSnap(annotation: annotation, observations: observations,
                                    strokeMinX: minX, strokeMaxX: maxX, strokeY: strokeY,
                                    selectionRect: selectionRect, canvas: canvas)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    private func applySmartSnap(
        annotation: Annotation,
        observations: [VNRecognizedTextObservation],
        strokeMinX: CGFloat, strokeMaxX: CGFloat, strokeY: CGFloat,
        selectionRect: NSRect,
        canvas: AnnotationCanvas
    ) {
        // Find the text line whose bounding box best overlaps with the stroke
        var bestObservation: VNRecognizedTextObservation?
        var bestOverlap: CGFloat = 0

        for observation in observations {
            let box = observation.boundingBox
            // Convert Vision normalized coords (origin bottom-left) to view coords
            let lineMinX = selectionRect.origin.x + box.origin.x * selectionRect.width
            let lineMaxX = lineMinX + box.width * selectionRect.width
            let lineMinY = selectionRect.origin.y + box.origin.y * selectionRect.height
            let lineMaxY = lineMinY + box.height * selectionRect.height

            // Check if stroke Y is within (or near) the text line's vertical bounds
            let verticalPadding: CGFloat = 8
            guard strokeY >= lineMinY - verticalPadding && strokeY <= lineMaxY + verticalPadding else { continue }

            // Compute horizontal overlap
            let overlapMin = max(strokeMinX, lineMinX)
            let overlapMax = min(strokeMaxX, lineMaxX)
            let overlap = max(0, overlapMax - overlapMin)

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestObservation = observation
            }
        }

        if let obs = bestObservation, bestOverlap > 10 {
            let box = obs.boundingBox
            let lineMinY = selectionRect.origin.y + box.origin.y * selectionRect.height
            let lineH = box.height * selectionRect.height
            let lineMidY = lineMinY + lineH / 2

            // Size the marker stroke to cover the text line height (with small padding)
            let smartStrokeWidth = (lineH + 4) / 6  // drawFreeform multiplies strokeWidth by 6

            // Keep the user's horizontal range, only snap Y and stroke height
            annotation.startPoint = NSPoint(x: strokeMinX, y: lineMidY)
            annotation.endPoint = NSPoint(x: strokeMaxX, y: lineMidY)
            annotation.points = [annotation.startPoint, annotation.endPoint]
            annotation.strokeWidth = smartStrokeWidth
        }
        // else: no matching text line — commit the stroke as-is

        if let lastPt = annotation.points?.last {
            canvas.markerCursorPoint = lastPt
        }
        commitAnnotation(annotation, canvas: canvas)
    }

    /// Invalidate cached OCR data (call when selection changes).
    func invalidateCache() {
        cachedObservations = nil
        cachedSelectionRect = .zero
    }
}
