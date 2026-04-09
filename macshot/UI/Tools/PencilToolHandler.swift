import Cocoa

/// Handles pencil (freeform draw) tool interaction.
/// Accumulates points on drag, applies Chaikin smoothing on finish.
final class PencilToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .pencil

    /// Shift-constrain direction for freeform drawing. 0 = undecided, 1 = horizontal, 2 = vertical.
    private var freeformShiftDirection: Int = 0
    /// The point where shift-constrain started (where the user first held Shift mid-stroke).
    private var shiftAnchor: NSPoint = .zero
    /// Moving average window for live smoothing (Refined mode).
    private var rawPointBuffer: [NSPoint] = []
    private var rawPressureBuffer: [CGFloat] = []
    private let smoothWindowSize: Int = 8

    var cursor: NSCursor? { nil }  // dot preview replaces system cursor

    // MARK: - AnnotationToolHandler

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        freeformShiftDirection = 0
        shiftAnchor = .zero
        rawPointBuffer = [point]
        rawPressureBuffer = [canvas.currentPressure]
        let annotation = Annotation(
            tool: .pencil,
            startPoint: point,
            endPoint: point,
            color: canvas.opacityAppliedColor(for: .pencil),
            strokeWidth: canvas.currentStrokeWidth
        )
        annotation.points = [point]
        if canvas.pencilPressureEnabled {
            annotation.pressures = [canvas.currentPressure]
        }
        annotation.lineStyle = canvas.currentLineStyle
        return annotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            // Capture the anchor point when shift is first pressed
            if freeformShiftDirection == 0 && shiftAnchor == .zero {
                shiftAnchor = annotation.points?.last ?? annotation.startPoint
            }
            let dx = clampedPoint.x - shiftAnchor.x
            let dy = clampedPoint.y - shiftAnchor.y

            if freeformShiftDirection == 0 && hypot(dx, dy) > 5 {
                freeformShiftDirection = abs(dx) >= abs(dy) ? 1 : 2
            }
            if freeformShiftDirection == 1 {
                clampedPoint = NSPoint(x: clampedPoint.x, y: shiftAnchor.y)
            } else if freeformShiftDirection == 2 {
                clampedPoint = NSPoint(x: shiftAnchor.x, y: clampedPoint.y)
            } else {
                clampedPoint = shiftAnchor
            }
        } else if freeformShiftDirection != 0 {
            // Shift released — reset so next shift press picks a new anchor
            freeformShiftDirection = 0
            shiftAnchor = .zero
        }

        // Refined mode: collect raw points for retroactive smoothing on finish.
        // Draw the raw point immediately (zero lag) — smoothing is applied in finish().
        if canvas.pencilSmoothMode == 2 {
            rawPointBuffer.append(clampedPoint)
            rawPressureBuffer.append(canvas.currentPressure)
        }

        // No snap guides for freeform tools
        canvas.snapGuideX = nil
        canvas.snapGuideY = nil

        annotation.endPoint = clampedPoint
        annotation.points?.append(clampedPoint)
        annotation.pressures?.append(canvas.currentPressure)
    }

    func finish(canvas: AnnotationCanvas) {
        guard let annotation = canvas.activeAnnotation else { return }

        guard let points = annotation.points, !points.isEmpty else {
            canvas.activeAnnotation = nil
            return
        }

        // Single click: offset points slightly so the round line cap renders a visible dot
        if points.count < 3, let p = points.first {
            annotation.points = [p, NSPoint(x: p.x + 0.5, y: p.y), NSPoint(x: p.x + 0.5, y: p.y)]
            if annotation.pressures != nil {
                let pr = annotation.pressures?.first ?? 1.0
                annotation.pressures = [pr, pr, pr]
            }
        } else if canvas.pencilSmoothMode == 2 {
            // Refined: retroactively apply moving average to the full raw buffer,
            // then Chaikin polish. Same result as live-smoothing but with zero
            // lag during drawing. Preserve exact endpoint so stroke ends where
            // the user released the mouse.
            let lastRaw = rawPointBuffer.last
            let smoothed = Self.movingAverageSmooth(rawPointBuffer, windowSize: smoothWindowSize)
            var final = Self.chaikinSmooth(smoothed, iterations: 2)
            if let last = lastRaw, let finalLast = final.last, finalLast != last {
                final.append(last)
            }
            annotation.points = final
            // Interpolate pressures to match smoothed point count
            if annotation.pressures != nil {
                let smoothedP = Self.movingAverageSmoothValues(rawPressureBuffer, windowSize: smoothWindowSize)
                var finalP = Self.chaikinSmoothValues(smoothedP, iterations: 2)
                if let lastP = rawPressureBuffer.last {
                    if finalP.count < final.count { finalP.append(lastP) }
                }
                annotation.pressures = finalP
            }
        } else if canvas.pencilSmoothMode >= 1 {
            // Mode 1 (Smooth): Chaikin on finish only
            annotation.points = Self.chaikinSmooth(points, iterations: 2)
            if let pressures = annotation.pressures {
                annotation.pressures = Self.chaikinSmoothValues(pressures, iterations: 2)
            }
        }

        // Update drawing cursor position so dot doesn't jump back to pre-drag location
        if let lastPt = annotation.points?.last {
            canvas.drawingCursorPoint = lastPt
        }
        commitAnnotation(annotation, canvas: canvas)
        freeformShiftDirection = 0
        rawPointBuffer.removeAll()
        rawPressureBuffer.removeAll()
    }

    // MARK: - Smoothing

    /// Retroactive trailing moving average: replicates the same smoothing that the
    /// old live-smoothing did incrementally (trailing window of N points), but applied
    /// to the full buffer at once. Produces identical output with zero drawing lag.
    static func movingAverageSmooth(_ pts: [NSPoint], windowSize: Int) -> [NSPoint] {
        guard pts.count > 2 else { return pts }
        var result: [NSPoint] = []
        result.reserveCapacity(pts.count)
        for i in 0..<pts.count {
            let lo = max(0, i - windowSize + 1)
            var avgX: CGFloat = 0, avgY: CGFloat = 0
            for j in lo...i { avgX += pts[j].x; avgY += pts[j].y }
            let n = CGFloat(i - lo + 1)
            result.append(NSPoint(x: avgX / n, y: avgY / n))
        }
        return result
    }

    /// Moving average for scalar values (pressures), matching movingAverageSmooth for points.
    static func movingAverageSmoothValues(_ vals: [CGFloat], windowSize: Int) -> [CGFloat] {
        guard vals.count > 2 else { return vals }
        var result: [CGFloat] = []
        result.reserveCapacity(vals.count)
        for i in 0..<vals.count {
            let lo = max(0, i - windowSize + 1)
            var sum: CGFloat = 0
            for j in lo...i { sum += vals[j] }
            result.append(sum / CGFloat(i - lo + 1))
        }
        return result
    }

    /// Chaikin smoothing for scalar values (pressures), matching chaikinSmooth for points.
    static func chaikinSmoothValues(_ vals: [CGFloat], iterations: Int) -> [CGFloat] {
        guard vals.count > 2 else { return vals }
        var result = vals
        for _ in 0..<iterations {
            var next: [CGFloat] = [result[0]]
            for i in 0..<result.count - 1 {
                next.append(0.75 * result[i] + 0.25 * result[i + 1])
                next.append(0.25 * result[i] + 0.75 * result[i + 1])
            }
            next.append(result[result.count - 1])
            result = next
        }
        return result
    }

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
