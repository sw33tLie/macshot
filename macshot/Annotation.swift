import Cocoa

enum AnnotationTool: Int, CaseIterable {
    case pencil          // freeform draw
    case line            // straight line
    case arrow           // arrow
    case rectangle       // outlined rect
    case filledRectangle // filled rect (opaque/redact)
    case ellipse         // outlined ellipse
    case marker          // highlighter (semi-transparent wide)
    case text            // text annotation
    case number          // auto-incrementing numbered circle
    case pixelate        // pixelate/blur region
    case blur            // gaussian blur region
    case measure         // pixel ruler / measurement line
    case loupe           // magnifying glass
    case select          // select & move existing annotations
    case translateOverlay // translated text painted over original
    case crop            // crop image (detached editor only)
    case colorSampler    // pick color from screen
}

enum LineStyle: Int, CaseIterable {
    case solid = 0
    case dashed = 1
    case dotted = 2

    var label: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        }
    }

    func apply(to path: NSBezierPath) {
        switch self {
        case .solid: break
        case .dashed:
            let pattern: [CGFloat] = [path.lineWidth * 3, path.lineWidth * 2]
            path.setLineDash(pattern, count: 2, phase: 0)
        case .dotted:
            // Zero-length dash + round cap = perfect circles
            path.lineCapStyle = .round
            let gap = max(path.lineWidth * 2, 6)
            let pattern: [CGFloat] = [0, gap]
            path.setLineDash(pattern, count: 2, phase: 0)
        }
    }

    /// Apply with evenly-spaced segments adjusted to fit a known path length.
    func applyFitted(to path: NSBezierPath, pathLength: CGFloat) {
        guard pathLength > 0 else { apply(to: path); return }
        switch self {
        case .solid: break
        case .dashed:
            let dashLen = path.lineWidth * 3
            let gapLen = path.lineWidth * 2
            let cycle = dashLen + gapLen
            let count = max(1, round(pathLength / cycle))
            let adjustedCycle = pathLength / count
            let ratio = dashLen / cycle
            let adjDash = adjustedCycle * ratio
            let adjGap = adjustedCycle * (1 - ratio)
            let pattern: [CGFloat] = [adjDash, adjGap]
            path.setLineDash(pattern, count: 2, phase: 0)
        case .dotted:
            path.lineCapStyle = .round
            let gap = max(path.lineWidth * 2, 6)
            let count = max(1, round(pathLength / gap))
            let adjustedGap = pathLength / count
            let pattern: [CGFloat] = [0, adjustedGap]
            path.setLineDash(pattern, count: 2, phase: 0)
        }
    }
}

class Annotation {
    let tool: AnnotationTool
    var startPoint: NSPoint
    var endPoint: NSPoint
    var color: NSColor
    var strokeWidth: CGFloat
    var text: String?
    var attributedText: NSAttributedString?  // rich text (overrides text + style flags)
    var number: Int?
    var points: [NSPoint]?
    var sourceImage: NSImage?    // for pixelate: temporary reference during drawing (cleared after bake)
    var sourceImageBounds: NSRect = .zero  // the bounds the image was drawn into
    var bakedBlurNSImage: NSImage?    // baked result for pixelate/blur (NSImage avoids CGImage flip issues)
    var textImage: NSImage?   // snapshot of the NSTextView at commit time — drawn as-is, no coord math
    var textDrawRect: NSRect = .zero  // where to draw textImage in OverlayView coords
    var fontSize: CGFloat = 20
    var isBold: Bool = false
    var isItalic: Bool = false
    var groupID: UUID?  // for batch undo (e.g. auto-redact)
    var isUnderline: Bool = false
    var isStrikethrough: Bool = false
    var controlPoint: NSPoint? = nil  // optional bend point for line/arrow
    var isRounded: Bool = false       // legacy — kept for compat, see rectCornerRadius
    var rectCornerRadius: CGFloat = 0 // 0..30, actual corner radius for rect tools
    var lineStyle: LineStyle = .solid // line/arrow/rect/ellipse stroke style
    var fontFamilyName: String?       // font family for text (nil = system default)

    init(tool: AnnotationTool, startPoint: NSPoint, endPoint: NSPoint, color: NSColor, strokeWidth: CGFloat) {
        self.tool = tool
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.strokeWidth = strokeWidth
    }

    func clone() -> Annotation {
        let c = Annotation(tool: tool, startPoint: startPoint, endPoint: endPoint, color: color, strokeWidth: strokeWidth)
        c.text = text
        c.attributedText = attributedText
        c.number = number
        c.points = points
        c.bakedBlurNSImage = bakedBlurNSImage
        c.textImage = textImage
        c.textDrawRect = textDrawRect
        c.fontSize = fontSize
        c.isBold = isBold
        c.isItalic = isItalic
        c.groupID = groupID
        c.isUnderline = isUnderline
        c.isStrikethrough = isStrikethrough
        c.controlPoint = controlPoint
        c.isRounded = isRounded
        c.rectCornerRadius = rectCornerRadius
        c.lineStyle = lineStyle
        c.fontFamilyName = fontFamilyName
        return c
    }

    var boundingRect: NSRect {
        return NSRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    /// Whether this annotation type can be moved
    var isMovable: Bool {
        switch tool {
        case .pixelate, .blur, .select, .translateOverlay:
            return false
        default:
            return true
        }
    }

    /// Hit-test: returns true if the point is close enough to this annotation
    func hitTest(point: NSPoint, threshold: CGFloat = 8) -> Bool {
        switch tool {
        case .pencil, .marker:
            guard let points = points else { return false }
            let strokeRadius = (tool == .marker ? strokeWidth * 6 : strokeWidth) / 2
            let effectiveThreshold = max(threshold, strokeRadius)
            for p in points {
                if hypot(p.x - point.x, p.y - point.y) < effectiveThreshold { return true }
            }
            return false
        case .line, .arrow, .measure:
            if let cp = controlPoint {
                return distanceToQuadCurve(point: point, from: startPoint, control: cp, to: endPoint) < threshold
            }
            return distanceToLineSegment(point: point, from: startPoint, to: endPoint) < threshold
        case .rectangle, .filledRectangle:
            let rect = boundingRect
            if tool == .filledRectangle {
                return rect.insetBy(dx: -threshold, dy: -threshold).contains(point)
            }
            // For outlined rect, check proximity to edges
            let outer = rect.insetBy(dx: -threshold, dy: -threshold)
            let inner = rect.insetBy(dx: threshold, dy: threshold)
            return outer.contains(point) && (inner.width < 0 || inner.height < 0 || !inner.contains(point))
        case .ellipse, .loupe:
            let rect = boundingRect
            guard rect.width > 0, rect.height > 0 else { return false }
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width / 2, ry = rect.height / 2
            let nx = (point.x - cx) / rx, ny = (point.y - cy) / ry
            let d = nx * nx + ny * ny
            // Close to the ellipse border
            let rNorm = threshold / min(rx, ry)
            return abs(d - 1.0) < rNorm * 2
        case .text:
            return textDrawRect.insetBy(dx: -threshold, dy: -threshold).contains(point)
        case .number:
            let radius = 8 + strokeWidth * 3 + threshold
            return hypot(point.x - startPoint.x, point.y - startPoint.y) < radius
        default:
            return false
        }
    }

    /// Move this annotation by a delta
    func move(dx: CGFloat, dy: CGFloat) {
        startPoint.x += dx
        startPoint.y += dy
        endPoint.x += dx
        endPoint.y += dy
        if textDrawRect != .zero {
            textDrawRect.origin.x += dx
            textDrawRect.origin.y += dy
        }
        if var pts = points {
            for i in 0..<pts.count {
                pts[i].x += dx
                pts[i].y += dy
            }
            points = pts
        }
        
        if var cp = controlPoint {
            cp.x += dx; cp.y += dy
            controlPoint = cp
        }
        // If it's a loupe, we need to clear the baked image so it re-renders the new magnified area
        if tool == .loupe {
            bakedBlurNSImage = nil
        }
    }

    /// Draw a selection highlight around this annotation
    func drawSelectionHighlight() {
        let highlightRect: NSRect
        switch tool {
        case .pencil, .marker:
            guard let points = points, !points.isEmpty else { return }
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for p in points {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            highlightRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text:
            highlightRect = textDrawRect != .zero ? textDrawRect : boundingRect
        case .number:
            let radius = 8 + strokeWidth * 3
            highlightRect = NSRect(x: startPoint.x - radius, y: startPoint.y - radius, width: radius * 2, height: radius * 2)
        case .loupe:
            highlightRect = boundingRect
        default:
            highlightRect = boundingRect
        }

        let padded = highlightRect.insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(roundedRect: padded, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        let pattern: [CGFloat] = [4, 4]
        path.setLineDash(pattern, count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        path.stroke()
        ToolbarLayout.accentColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: padded, xRadius: 3, yRadius: 3).fill()
    }

    // MARK: - Geometry helpers

    /// Approximate the arc length of a cubic bezier by sampling.
    static func approxBezierLength(from p0: NSPoint, cp1: NSPoint, cp2: NSPoint, to p3: NSPoint, steps: Int = 30) -> CGFloat {
        var length: CGFloat = 0
        var prev = p0
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let u = 1 - t
            let x = u*u*u*p0.x + 3*u*u*t*cp1.x + 3*u*t*t*cp2.x + t*t*t*p3.x
            let y = u*u*u*p0.y + 3*u*u*t*cp1.y + 3*u*t*t*cp2.y + t*t*t*p3.y
            length += hypot(x - prev.x, y - prev.y)
            prev = NSPoint(x: x, y: y)
        }
        return length
    }

    private func distanceToQuadCurve(point: NSPoint, from a: NSPoint, control c: NSPoint, to b: NSPoint) -> CGFloat {
        // The curve is drawn as a cubic bezier with cp1 == cp2 == c (NSBezierPath.curve),
        // so sample the cubic formula to match the actual rendered path.
        let steps = 40
        var minDist = CGFloat.greatestFiniteMagnitude
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let u = 1 - t
            let px = u*u*u*a.x + 3*u*u*t*c.x + 3*u*t*t*c.x + t*t*t*b.x
            let py = u*u*u*a.y + 3*u*u*t*c.y + 3*u*t*t*c.y + t*t*t*b.y
            let d = hypot(point.x - px, point.y - py)
            if d < minDist { minDist = d }
        }
        return minDist
    }

    private func distanceToLineSegment(point: NSPoint, from a: NSPoint, to b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.001 { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = NSPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - proj.x, point.y - proj.y)
    }

    func draw(in context: NSGraphicsContext) {
        NSGraphicsContext.current = context

        switch tool {
        case .pencil:
            drawFreeform(alpha: color.alphaComponent, width: strokeWidth)
        case .line:
            drawStraightLine()
        case .arrow:
            drawArrow()
        case .rectangle:
            drawRectangle(filled: false)
        case .filledRectangle:
            drawRectangle(filled: true)
        case .ellipse:
            drawEllipse()
        case .marker:
            drawFreeform(alpha: 0.35, width: strokeWidth * 6)
        case .text:
            drawText()
        case .number:
            drawNumber()
        case .pixelate:
            drawPixelate(in: context)
        case .blur:
            drawBlur(in: context)
        case .measure:
            drawMeasure()
        case .loupe:
            drawLoupe(in: context)
        case .select:
            break  // not a drawable tool
        case .crop:
            break  // handled separately in OverlayView
        case .translateOverlay:
            drawTranslateOverlay()
        case .colorSampler:
            break  // preview-only tool, no annotation drawn
        }
    }

    // MARK: - Drawing methods

    private func drawFreeform(alpha: CGFloat, width: CGFloat) {
        guard let points = points, points.count > 1 else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // For dotted freeform, place dots at evenly-spaced arc-length positions
        // to avoid uneven spacing caused by segment boundaries in the polyline.
        if lineStyle == .dotted {
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            color.withAlphaComponent(1.0).setFill()

            // Compute cumulative arc lengths
            var cumLengths: [CGFloat] = [0]
            for i in 1..<points.count {
                cumLengths.append(cumLengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
            }
            let totalLength = cumLengths.last!
            guard totalLength > 0 else {
                ctx.endTransparencyLayer()
                ctx.setAlpha(1.0)
                return
            }

            let gap = max(width * 2, 6)
            let count = max(1, round(totalLength / gap))
            let spacing = totalLength / count
            let dotRadius = width / 2

            var segIdx = 0
            var dist: CGFloat = 0
            while dist <= totalLength + 0.01 {
                // Find the segment containing this distance
                while segIdx < points.count - 2 && cumLengths[segIdx + 1] < dist {
                    segIdx += 1
                }
                let segStart = cumLengths[segIdx]
                let segLen = cumLengths[segIdx + 1] - segStart
                let t: CGFloat = segLen > 0 ? (dist - segStart) / segLen : 0
                let x = points[segIdx].x + t * (points[segIdx + 1].x - points[segIdx].x)
                let y = points[segIdx].y + t * (points[segIdx + 1].y - points[segIdx].y)
                let dotRect = NSRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                NSBezierPath(ovalIn: dotRect).fill()
                dist += spacing
            }

            ctx.endTransparencyLayer()
            ctx.setAlpha(1.0)
            return
        }

        // Use a transparency layer so self-overlapping segments don't compound alpha
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        lineStyle.apply(to: path)
        color.withAlphaComponent(1.0).setStroke()
        path.move(to: points[0])
        for i in 1..<points.count {
            path.line(to: points[i])
        }
        path.stroke()
        ctx.endTransparencyLayer()
        ctx.setAlpha(1.0)
    }

    private func drawStraightLine() {
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        if lineStyle != .solid {
            let length: CGFloat
            if let cp = controlPoint {
                length = Annotation.approxBezierLength(from: startPoint, cp1: cp, cp2: cp, to: endPoint)
            } else {
                length = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
            }
            lineStyle.applyFitted(to: path, pathLength: length)
        }
        color.setStroke()
        path.move(to: startPoint)
        if let cp = controlPoint {
            path.curve(to: endPoint, controlPoint1: cp, controlPoint2: cp)
        } else {
            path.line(to: endPoint)
        }
        path.stroke()
    }

    private func drawArrow() {
        // Determine the arrival angle at endPoint for the arrowhead
        let angle: CGFloat
        if let cp = controlPoint {
            // Tangent of quadratic bezier at t=1 is: endPoint - controlPoint
            angle = atan2(endPoint.y - cp.y, endPoint.x - cp.x)
        } else {
            angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        }
        let arrowLength: CGFloat = max(14, strokeWidth * 5)
        let arrowAngle: CGFloat = .pi / 6

        let p1 = NSPoint(
            x: endPoint.x - arrowLength * cos(angle - arrowAngle),
            y: endPoint.y - arrowLength * sin(angle - arrowAngle)
        )
        let p2 = NSPoint(
            x: endPoint.x - arrowLength * cos(angle + arrowAngle),
            y: endPoint.y - arrowLength * sin(angle + arrowAngle)
        )

        // Line stops at the base of the arrowhead (midpoint of p1-p2)
        let lineEnd = NSPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)

        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        if lineStyle != .solid {
            let length: CGFloat
            if let cp = controlPoint {
                length = Annotation.approxBezierLength(from: startPoint, cp1: cp, cp2: cp, to: lineEnd)
            } else {
                length = hypot(lineEnd.x - startPoint.x, lineEnd.y - startPoint.y)
            }
            lineStyle.applyFitted(to: path, pathLength: length)
        }
        color.setStroke()
        path.move(to: startPoint)
        if let cp = controlPoint {
            path.curve(to: lineEnd, controlPoint1: cp, controlPoint2: cp)
        } else {
            path.line(to: lineEnd)
        }
        path.stroke()

        // Filled arrowhead
        let arrowHead = NSBezierPath()
        color.setFill()
        arrowHead.move(to: endPoint)
        arrowHead.line(to: p1)
        arrowHead.line(to: p2)
        arrowHead.close()
        arrowHead.fill()
    }

    private func drawRectangle(filled: Bool) {
        let rect = boundingRect
        guard rect.width > 0, rect.height > 0 else { return }
        let cornerRadius: CGFloat = rectCornerRadius > 0 ? rectCornerRadius : (isRounded ? min(rect.width, rect.height) * 0.2 : 0)
        if filled {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        } else if lineStyle == .dotted && cornerRadius < 1 {
            // Draw dots per-side with guaranteed dots at corners
            drawDottedRectPerSide(rect: rect)
        } else {
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineWidth = strokeWidth
            if lineStyle != .solid {
                let r = min(cornerRadius, min(rect.width, rect.height) / 2)
                let perimeter = 2 * (rect.width - 2 * r) + 2 * (rect.height - 2 * r) + 2 * .pi * r
                lineStyle.applyFitted(to: path, pathLength: perimeter)
            }
            color.setStroke()
            path.stroke()
        }
    }

    /// Draw a dotted rectangle with dots guaranteed at every corner.
    /// Each side is drawn independently so dots tile evenly per-side.
    private func drawDottedRectPerSide(rect: NSRect) {
        let dotRadius = strokeWidth / 2
        let idealGap = max(strokeWidth * 2, 6)
        color.setFill()

        // Corner points (bottom-left origin, clockwise: BL → TL → TR → BR)
        let corners = [
            NSPoint(x: rect.minX, y: rect.minY),  // bottom-left
            NSPoint(x: rect.minX, y: rect.maxY),  // top-left
            NSPoint(x: rect.maxX, y: rect.maxY),  // top-right
            NSPoint(x: rect.maxX, y: rect.minY),  // bottom-right
        ]

        for i in 0..<4 {
            let p0 = corners[i]
            let p1 = corners[(i + 1) % 4]
            let sideLen = hypot(p1.x - p0.x, p1.y - p0.y)
            guard sideLen > 0 else { continue }

            // Number of segments (gaps between dots). At least 1 so we get dots at both ends.
            let n = max(1, Int(round(sideLen / idealGap)))
            let step = sideLen / CGFloat(n)
            let dx = (p1.x - p0.x) / sideLen
            let dy = (p1.y - p0.y) / sideLen

            // Draw dots from p0 to p1 (inclusive of p0, exclusive of p1 to avoid double-drawing corners)
            for j in 0..<n {
                let t = CGFloat(j) * step
                let x = p0.x + dx * t
                let y = p0.y + dy * t
                let dotRect = NSRect(x: x - dotRadius, y: y - dotRadius, width: strokeWidth, height: strokeWidth)
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
    }

    private func drawEllipse() {
        let rect = boundingRect
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = strokeWidth
        if lineStyle != .solid {
            // Approximate ellipse perimeter (Ramanujan's approximation)
            let a = rect.width / 2
            let b = rect.height / 2
            let perimeter = .pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b)))
            lineStyle.applyFitted(to: path, pathLength: perimeter)
        } else {
            lineStyle.apply(to: path)
        }
        color.setStroke()
        path.stroke()
    }

    private func drawText() {
        guard let image = textImage, textDrawRect != .zero else { return }
        image.draw(in: textDrawRect)
    }

    private func drawNumber() {
        guard let number = number else { return }
        let radius: CGFloat = 8 + strokeWidth * 3
        let center = startPoint

        // Draw pointer cone if dragged (startPoint != endPoint)
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let dist = hypot(dx, dy)
        if dist > 4 {
            let angle = atan2(dy, dx)
            // Cone base width tapers from the circle edge, narrowing to a point
            let baseHalfWidth = radius * 0.55
            let perpAngle = angle + .pi / 2

            // Base points on the circle's edge
            let baseL = NSPoint(x: center.x + baseHalfWidth * cos(perpAngle),
                                y: center.y + baseHalfWidth * sin(perpAngle))
            let baseR = NSPoint(x: center.x - baseHalfWidth * cos(perpAngle),
                                y: center.y - baseHalfWidth * sin(perpAngle))

            let cone = NSBezierPath()
            cone.move(to: baseL)
            cone.line(to: endPoint)
            cone.line(to: baseR)
            cone.close()
            color.setFill()
            cone.fill()
        }

        // Draw the circle on top of the cone
        let circleRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        // Choose contrasting text color: black for light backgrounds, white for dark
        let textColor: NSColor = {
            guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            return luminance > 0.6 ? .black : .white
        }()
        let fontSize = radius * 1.1
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: textColor
        ]
        let str = "\(number)" as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }

    private func drawMeasure() {
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelDistance = Int(distance * scale)

        // Main measurement line
        let lineColor = color
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        lineColor.setStroke()
        path.move(to: startPoint)
        path.line(to: endPoint)
        path.stroke()

        // Perpendicular end caps (small ticks at each end)
        let angle = atan2(dy, dx)
        let perpAngle = angle + .pi / 2
        let capLength: CGFloat = 6
        let capDx = capLength * cos(perpAngle)
        let capDy = capLength * sin(perpAngle)

        let capPath = NSBezierPath()
        capPath.lineWidth = 1.5
        capPath.lineCapStyle = .round
        lineColor.setStroke()
        // Start cap
        capPath.move(to: NSPoint(x: startPoint.x - capDx, y: startPoint.y - capDy))
        capPath.line(to: NSPoint(x: startPoint.x + capDx, y: startPoint.y + capDy))
        // End cap
        capPath.move(to: NSPoint(x: endPoint.x - capDx, y: endPoint.y - capDy))
        capPath.line(to: NSPoint(x: endPoint.x + capDx, y: endPoint.y + capDy))
        capPath.stroke()

        // Dimension label
        let pxWidth = Int(abs(dx) * scale)
        let pxHeight = Int(abs(dy) * scale)
        let labelText: String
        if pxWidth < 3 {
            labelText = "\(pxHeight)px"
        } else if pxHeight < 3 {
            labelText = "\(pxWidth)px"
        } else {
            labelText = "\(pixelDistance)px (\(pxWidth) × \(pxHeight))"
        }

        let fontSize: CGFloat = 11
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = labelText as NSString
        let strSize = str.size(withAttributes: attrs)

        // Position label at midpoint, offset perpendicular to the line
        let midX = (startPoint.x + endPoint.x) / 2
        let midY = (startPoint.y + endPoint.y) / 2
        let offsetDist: CGFloat = 12
        let labelX = midX + offsetDist * cos(perpAngle) - strSize.width / 2
        let labelY = midY + offsetDist * sin(perpAngle) - strSize.height / 2

        // Background pill for readability
        let padding: CGFloat = 4
        let bgRect = NSRect(
            x: labelX - padding,
            y: labelY - padding / 2,
            width: strSize.width + padding * 2,
            height: strSize.height + padding
        )
        NSColor(white: 0.0, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()

        str.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)
    }

    // MARK: - Shared region crop

    /// Render the source image region matching boundingRect into a new NSImage.
    /// Uses NSImage drawing which handles all coordinate transforms correctly.
    private func cropRegionFromSource() -> NSImage? {
        guard let sourceImage = sourceImage else { return nil }
        let rect = boundingRect
        guard rect.width > 4, rect.height > 4 else { return nil }

        let regionImage = NSImage(size: rect.size)
        regionImage.lockFocus()
        sourceImage.draw(in: NSRect(x: -rect.minX, y: -rect.minY,
                                     width: sourceImageBounds.width, height: sourceImageBounds.height),
                         from: .zero, operation: .copy, fraction: 1.0)
        regionImage.unlockFocus()
        return regionImage
    }

    // MARK: - Pixelate

    /// Bake the processed image from source, then release the source screenshot reference.
    /// Called once when the annotation is finalized (mouseUp).
    func bakePixelate() {
        if tool == .blur {
            bakeBlur()
            return
        }
        guard tool == .pixelate, bakedBlurNSImage == nil, let _ = sourceImage else { return }

        guard let regionImage = cropRegionFromSource() else { return }
        let rect = boundingRect

        // Convert to CGImage for pixelation
        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cropped = bitmap.cgImage else { return }

        // Fixed block size of ~8px on screen (scaled for Retina)
        let pixelBlock = 8
        let tinyW = max(1, cropped.width / pixelBlock)
        let tinyH = max(1, cropped.height / pixelBlock)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx1 = CGContext(data: nil, width: tinyW, height: tinyH,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return }
        ctx1.interpolationQuality = .low
        ctx1.draw(cropped, in: CGRect(x: 0, y: 0, width: tinyW, height: tinyH))
        guard let tiny1 = ctx1.makeImage() else { return }

        let tinyW2 = max(1, tinyW / 2)
        let tinyH2 = max(1, tinyH / 2)
        guard let ctx2 = CGContext(data: nil, width: tinyW2, height: tinyH2,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return }
        ctx2.interpolationQuality = .low
        ctx2.draw(tiny1, in: CGRect(x: 0, y: 0, width: tinyW2, height: tinyH2))
        guard let tiny2 = ctx2.makeImage() else { return }

        let finalW = max(1, Int(rect.width * 2))
        let finalH = max(1, Int(rect.height * 2))
        guard let ctx3 = CGContext(data: nil, width: finalW, height: finalH,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return }
        ctx3.interpolationQuality = .none
        ctx3.draw(tiny2, in: CGRect(x: 0, y: 0, width: finalW, height: finalH))

        guard let pixelatedCG = ctx3.makeImage() else { return }
        bakedBlurNSImage = NSImage(cgImage: pixelatedCG, size: rect.size)
        self.sourceImage = nil
    }

    private func drawPixelate(in context: NSGraphicsContext) {
        let rect = boundingRect
        guard rect.width > 4, rect.height > 4 else { return }

        // Use baked image if available (finalized annotation)
        if let baked = bakedBlurNSImage {
            baked.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return
        }

        // Live preview while drawing: frosted overlay indicator (real pixelation applied on mouseUp)
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: rect).fill()

        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        let pattern: [CGFloat] = [4, 4]
        border.setLineDash(pattern, count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.5).setStroke()
        border.stroke()
    }

    // MARK: - Blur

    private static let ciContext = CIContext()

    private func applyGaussianBlur(to cgImage: CGImage) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        let radius = max(10.0, min(Double(w), Double(h)) * 0.03)

        let ciImage = CIImage(cgImage: cgImage)

        // Clamp edges to avoid dark border artifacts
        guard let clamp = CIFilter(name: "CIAffineClamp") else { return nil }
        clamp.setValue(ciImage, forKey: kCIInputImageKey)
        clamp.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
        guard let clamped = clamp.outputImage else { return nil }

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(clamped, forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage else { return nil }

        // Render exactly at the original pixel dimensions
        let outputRect = CGRect(x: 0, y: 0, width: w, height: h)
        return Annotation.ciContext.createCGImage(output, from: outputRect)
    }

    private func bakeBlur() {
        guard tool == .blur, bakedBlurNSImage == nil, let _ = sourceImage else { return }

        guard let regionImage = cropRegionFromSource() else { return }
        let rect = boundingRect

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage,
              let blurredCG = applyGaussianBlur(to: cgImage) else { return }

        bakedBlurNSImage = NSImage(cgImage: blurredCG, size: rect.size)
        self.sourceImage = nil
    }

    private func drawBlur(in context: NSGraphicsContext) {
        let rect = boundingRect
        guard rect.width > 4, rect.height > 4 else { return }

        if let blurred = bakedBlurNSImage {
            blurred.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return
        }

        // Live preview while dragging: frosted overlay indicator (real blur applied on mouseUp)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: rect).fill()

        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        let pattern: [CGFloat] = [4, 4]
        border.setLineDash(pattern, count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        border.stroke()
    }

    // MARK: - Loupe (Magnifying Glass)

    // MARK: - Loupe (Magnifying Glass)

    func bakeLoupe() {
        guard tool == .loupe else { return }
        if let live = generateLoupeImage() {
            bakedBlurNSImage = live
        }
        // Do NOT set self.sourceImage = nil so that if the user moves it later, it can still magnify!
    }

    private func generateLoupeImage() -> NSImage? {
        // Real-time geometric magnification of the source underlying the circle
        guard let image = sourceImage else { return nil }

        let bounds = sourceImageBounds
        let imageSize = image.size
        let scaleX = imageSize.width / bounds.width
        let scaleY = imageSize.height / bounds.height
        
        let rect = boundingRect
        let scale: CGFloat = 2.0 // 2x Magnification
        
        // Always force a perfect circle
        let size = min(rect.width, rect.height)
        guard size > 10 else { return nil }

        let centerX = rect.origin.x + rect.width / 2
        let centerY = rect.origin.y + rect.height / 2
        
        let srcSize = size / scale
        let srcX = centerX - srcSize / 2
        let srcY = centerY - srcSize / 2
        
        // Extract the original region.
        // NSImage and the overlay view share the same coordinate system (Y=0 at bottom),
        // so no Y-flip is needed — just scale directly.
        let cropRect = NSRect(
            x: srcX * scaleX,
            y: srcY * scaleY,
            width: srcSize * scaleX,
            height: srcSize * scaleY
        )
        
        let magnifiedImage = NSImage(size: NSSize(width: size, height: size))
        magnifiedImage.lockFocus()
        if let ctx = NSGraphicsContext.current {
            ctx.imageInterpolation = .high
        }
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                   from: cropRect,
                   operation: .copy,
                   fraction: 1.0)
        magnifiedImage.unlockFocus()
        
        return magnifiedImage
    }

    // Cached loupe chrome objects (shared across all loupe annotations)
    private static let loupeOuterShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.4)
        s.shadowOffset = NSSize(width: 0, height: -6)
        s.shadowBlurRadius = 14
        return s
    }()
    private static let loupeInnerShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.5)
        s.shadowOffset = NSSize(width: 0, height: -3)
        s.shadowBlurRadius = 6
        return s
    }()
    private static let loupeGradient: CGGradient? = {
        let colors = [
            NSColor.white.withAlphaComponent(0.95).cgColor,
            NSColor(white: 0.7, alpha: 0.85).cgColor,
        ] as CFArray
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0])
    }()

    private func drawLoupe(in context: NSGraphicsContext) {
        let rect = boundingRect
        guard rect.width > 10, rect.height > 10 else { return }

        let size = min(rect.width, rect.height)
        let squareRect = NSRect(
            x: rect.origin.x + (rect.width - size) / 2,
            y: rect.origin.y + (rect.height - size) / 2,
            width: size,
            height: size
        )

        let path = NSBezierPath(ovalIn: squareRect)

        // 1. Outer drop shadow
        context.saveGraphicsState()
        Self.loupeOuterShadow.set()
        NSColor.white.setFill()
        path.fill()
        context.restoreGraphicsState()

        // 2. Magnified content clipped to circle
        context.saveGraphicsState()
        path.addClip()

        if let baked = bakedBlurNSImage {
            baked.draw(in: squareRect, from: NSRect(origin: .zero, size: baked.size),
                       operation: .sourceOver, fraction: 1.0)
        } else if let image = sourceImage {
            // Draw directly from source without creating an intermediate image.
            let imgSize = image.size
            let scaleX = imgSize.width / sourceImageBounds.width
            let scaleY = imgSize.height / sourceImageBounds.height
            let magnification: CGFloat = 2.0
            let srcSize = size / magnification
            let cx = rect.midX, cy = rect.midY
            let fromRect = NSRect(
                x: (cx - srcSize/2) * scaleX,
                y: (cy - srcSize/2) * scaleY,
                width: srcSize * scaleX,
                height: srcSize * scaleY
            )
            context.imageInterpolation = .high
            image.draw(in: squareRect, from: fromRect, operation: .copy, fraction: 1.0)
        }
        context.restoreGraphicsState()

        // 3. Gradient border ring
        let cgCtx = context.cgContext
        let borderWidth: CGFloat = 4.0
        let innerPath = NSBezierPath(ovalIn: squareRect.insetBy(dx: borderWidth, dy: borderWidth))
        let ringPath = NSBezierPath()
        ringPath.append(path)
        ringPath.append(innerPath.reversed)
        cgCtx.saveGState()
        ringPath.addClip()
        if let gradient = Self.loupeGradient {
            cgCtx.drawLinearGradient(
                gradient,
                start: CGPoint(x: squareRect.midX, y: squareRect.maxY),
                end:   CGPoint(x: squareRect.midX, y: squareRect.minY),
                options: []
            )
        }
        cgCtx.restoreGState()

        // 4. Inner shadow
        context.saveGraphicsState()
        Self.loupeInnerShadow.set()
        let holeRect = squareRect.insetBy(dx: -30, dy: -30)
        let innerHole = NSBezierPath(rect: holeRect)
        innerHole.append(NSBezierPath(ovalIn: squareRect).reversed)
        path.addClip()
        NSColor.black.withAlphaComponent(0.8).setFill()
        innerHole.fill()
        context.restoreGraphicsState()
    }

    // MARK: - Translate overlay

    private func drawTranslateOverlay() {
        guard let translatedText = text, !translatedText.isEmpty else { return }

        let rect = boundingRect
        guard rect.width > 2, rect.height > 2 else { return }

        // Background: use `color` (sampled avg color stored at creation time)
        // with a slight blur-like fill behind text
        let bgColor = color
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        bgColor.setFill()
        bgPath.fill()

        // Determine contrasting text color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bgColor.usingColorSpace(.deviceRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let textColor: NSColor = luminance > 0.55 ? .black : .white

        // Fit text into the rect — start at stored fontSize, shrink if needed
        let hPad: CGFloat = 3
        let vPad: CGFloat = 2
        let availW = rect.width - hPad * 2
        let availH = rect.height - vPad * 2

        var fs = max(8, fontSize)
        var attrStr: NSAttributedString
        repeat {
            let font = NSFont.systemFont(ofSize: fs, weight: .medium)
            attrStr = NSAttributedString(string: translatedText, attributes: [
                .font: font,
                .foregroundColor: textColor,
            ])
            let needed = attrStr.boundingRect(
                with: NSSize(width: availW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            if needed.height <= availH || fs <= 8 { break }
            fs -= 1
        } while fs > 8

        // Draw text top-aligned within the block
        let textRect = NSRect(
            x: rect.minX + hPad,
            y: rect.minY + vPad,
            width: availW,
            height: availH
        )
        attrStr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
