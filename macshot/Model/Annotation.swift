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
    case stamp           // emoji or image stamp
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
            // Center dashes on the path start so the pattern wraps symmetrically
            path.setLineDash(pattern, count: 2, phase: adjDash / 2)
        case .dotted:
            path.lineCapStyle = .round
            let gap = max(path.lineWidth * 2, 6)
            let count = max(1, round(pathLength / gap))
            let adjustedGap = pathLength / count
            let pattern: [CGFloat] = [0, adjustedGap]
            // Offset by half a gap so dots are centered on each side, not bunched at the path start
            path.setLineDash(pattern, count: 2, phase: adjustedGap / 2)
        }
    }
}

enum RectFillStyle: Int, CaseIterable {
    case stroke = 0         // outline only
    case strokeAndFill = 1  // outline + semi-transparent fill
    case fill = 2           // filled only (respects color opacity)
}

enum NumberFormat: Int, CaseIterable {
    case decimal = 0    // 1, 2, 3
    case roman = 1      // I, II, III
    case alpha = 2      // A, B, C
    case alphaLower = 3 // a, b, c

    func format(_ number: Int) -> String {
        switch self {
        case .decimal: return "\(number)"
        case .roman: return Self.toRoman(number)
        case .alpha: return Self.toAlpha(number, uppercase: true)
        case .alphaLower: return Self.toAlpha(number, uppercase: false)
        }
    }

    var label: String {
        switch self {
        case .decimal: return "1"
        case .roman: return "I"
        case .alpha: return "A"
        case .alphaLower: return "a"
        }
    }

    private static func toRoman(_ n: Int) -> String {
        let values = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
        var result = ""
        var remaining = max(1, min(n, 3999))
        for (value, numeral) in values {
            while remaining >= value {
                result += numeral
                remaining -= value
            }
        }
        return result
    }

    private static func toAlpha(_ n: Int, uppercase: Bool) -> String {
        let base = uppercase ? Character("A") : Character("a")
        let idx = ((max(1, n) - 1) % 26)
        return String(Character(UnicodeScalar(base.asciiValue! + UInt8(idx))))
    }
}

enum CensorMode: Int, CaseIterable {
    case pixelate = 0
    case blur = 1
    case solid = 2

    var label: String {
        switch self {
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .solid: return "Solid"
        }
    }
}

enum ArrowStyle: Int, CaseIterable {
    case single = 0     // arrowhead at end only
    case thick = 1      // solid filled banner arrow shape
    case double = 2     // arrowheads at both ends
    case open = 3       // open/unfilled chevron arrowhead
    case tail = 4       // filled arrowhead at end + circle at start
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
    var numberFormat: NumberFormat = .decimal
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
    var rotation: CGFloat = 0         // rotation angle in radians

    var supportsRotation: Bool {
        switch tool {
        case .rectangle, .filledRectangle, .ellipse, .stamp, .text, .number, .pixelate, .blur:
            return true
        default:
            return false
        }
    }
    var controlPoint: NSPoint? = nil  // optional bend point for line/arrow (legacy single bend)
    /// Ordered waypoints for multi-anchor lines/arrows: [start, anchor1, anchor2, ..., end].
    /// When set, overrides startPoint/endPoint/controlPoint for rendering.
    var anchorPoints: [NSPoint]?

    /// Returns the full ordered path: anchorPoints if set, otherwise [start, end].
    /// Legacy controlPoint is NOT included — it uses the original bezier rendering.
    var waypoints: [NSPoint] {
        if let anchors = anchorPoints, anchors.count >= 2 {
            return anchors
        }
        return [startPoint, endPoint]
    }

    /// Whether this annotation uses multi-anchor points (vs legacy single bend).
    var hasMultiAnchor: Bool { anchorPoints != nil && (anchorPoints?.count ?? 0) >= 3 }

    var isRounded: Bool = false       // legacy — kept for compat, see rectCornerRadius
    var rectCornerRadius: CGFloat = 0 // 0..30, actual corner radius for rect tools
    var lineStyle: LineStyle = .solid // line/arrow/rect/ellipse stroke style
    var arrowStyle: ArrowStyle = .single // arrow head style
    var arrowReversed: Bool = false      // head at start instead of end
    var rectFillStyle: RectFillStyle = .stroke // rectangle fill mode
    var stampImage: NSImage?          // rendered emoji or loaded picture for stamp tool
    var measureInPoints: Bool = false  // true = show pt, false = show px
    var censorMode: CensorMode = .pixelate
    var textBgColor: NSColor?         // background pill color (nil = no background)
    var textOutlineColor: NSColor?    // text outline/stroke color (nil = no outline)
    var textAlignment: NSTextAlignment = .left // text alignment within the box
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
        c.numberFormat = numberFormat
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
        c.rotation = rotation
        c.controlPoint = controlPoint
        c.anchorPoints = anchorPoints
        c.isRounded = isRounded
        c.rectCornerRadius = rectCornerRadius
        c.lineStyle = lineStyle
        c.arrowStyle = arrowStyle
        c.arrowReversed = arrowReversed
        c.rectFillStyle = rectFillStyle
        c.stampImage = stampImage
        c.measureInPoints = measureInPoints
        c.censorMode = censorMode
        c.textBgColor = textBgColor
        c.textOutlineColor = textOutlineColor
        c.textAlignment = textAlignment
        c.fontFamilyName = fontFamilyName
        return c
    }

    /// Copy all visual/style properties from another annotation (for undo/redo of property edits).
    func copyProperties(from src: Annotation) {
        color = src.color
        strokeWidth = src.strokeWidth
        lineStyle = src.lineStyle
        arrowStyle = src.arrowStyle
        arrowReversed = src.arrowReversed
        rectFillStyle = src.rectFillStyle
        rectCornerRadius = src.rectCornerRadius
        fontSize = src.fontSize
        isBold = src.isBold
        isItalic = src.isItalic
        isUnderline = src.isUnderline
        isStrikethrough = src.isStrikethrough
        textBgColor = src.textBgColor
        textOutlineColor = src.textOutlineColor
        textAlignment = src.textAlignment
        fontFamilyName = src.fontFamilyName
        numberFormat = src.numberFormat
        measureInPoints = src.measureInPoints
        censorMode = src.censorMode
    }

    var boundingRect: NSRect {
        var minX = min(startPoint.x, endPoint.x)
        var minY = min(startPoint.y, endPoint.y)
        var maxX = max(startPoint.x, endPoint.x)
        var maxY = max(startPoint.y, endPoint.y)
        if let anchors = anchorPoints {
            for p in anchors {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
        }
        if let cp = controlPoint {
            minX = min(minX, cp.x); minY = min(minY, cp.y)
            maxX = max(maxX, cp.x); maxY = max(maxY, cp.y)
        }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
        // For rotated annotations, un-rotate the test point around the annotation's center
        var point = point
        if rotation != 0 && supportsRotation {
            let center = NSPoint(x: boundingRect.midX, y: boundingRect.midY)
            let dx = point.x - center.x
            let dy = point.y - center.y
            let cosR = cos(-rotation)
            let sinR = sin(-rotation)
            point = NSPoint(x: center.x + dx * cosR - dy * sinR,
                            y: center.y + dx * sinR + dy * cosR)
        }
        switch tool {
        case .pencil, .marker:
            guard let points = points else { return false }
            let strokeRadius = (tool == .marker ? strokeWidth * 6 : strokeWidth) / 2
            let effectiveThreshold = max(threshold, strokeRadius)
            for p in points {
                if hypot(p.x - point.x, p.y - point.y) < effectiveThreshold { return true }
            }
            return false
        case .line, .measure:
            if hasMultiAnchor {
                return distanceToPolyline(point: point, waypoints: waypoints) < threshold
            }
            if let cp = controlPoint {
                return distanceToQuadCurve(point: point, from: startPoint, control: cp, to: endPoint) < threshold
            }
            return distanceToLineSegment(point: point, from: startPoint, to: endPoint) < threshold
        case .arrow:
            if arrowStyle == .thick {
                let totalLen = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
                let sizeScale = min(1.0, max(0.2, totalLen / 120))
                // Match the actual drawn shape width: shaft is strokeWidth*1.5, head is strokeWidth*3
                let shaftHalf = max(4, strokeWidth * 1.5) * sizeScale
                let hitThreshold = max(threshold, shaftHalf + 4)
                if hasMultiAnchor {
                    return distanceToPolyline(point: point, waypoints: waypoints) < hitThreshold
                }
                if let cp = controlPoint {
                    return distanceToQuadCurve(point: point, from: startPoint, control: cp, to: endPoint) < hitThreshold
                }
                return distanceToLineSegment(point: point, from: startPoint, to: endPoint) < hitThreshold
            }
            if hasMultiAnchor {
                return distanceToPolyline(point: point, waypoints: waypoints) < threshold
            }
            if let cp = controlPoint {
                return distanceToQuadCurve(point: point, from: startPoint, control: cp, to: endPoint) < threshold
            }
            return distanceToLineSegment(point: point, from: startPoint, to: endPoint) < threshold
        case .rectangle, .filledRectangle:
            let rect = boundingRect
            if tool == .filledRectangle || rectFillStyle == .fill || rectFillStyle == .strokeAndFill {
                return rect.insetBy(dx: -threshold, dy: -threshold).contains(point)
            }
            // For outlined rect, check proximity to edges
            let outer = rect.insetBy(dx: -threshold, dy: -threshold)
            let inner = rect.insetBy(dx: threshold, dy: threshold)
            return outer.contains(point) && (inner.width < 0 || inner.height < 0 || !inner.contains(point))
        case .ellipse:
            let rect = boundingRect
            guard rect.width > 0, rect.height > 0 else { return false }
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width / 2, ry = rect.height / 2
            let nx = (point.x - cx) / rx, ny = (point.y - cy) / ry
            let d = nx * nx + ny * ny
            if rectFillStyle == .fill || rectFillStyle == .strokeAndFill {
                return d <= 1.0 + (threshold / min(rx, ry))
            }
            let rNorm = threshold / min(rx, ry)
            return abs(d - 1.0) < rNorm * 2
        case .loupe:
            let rect = boundingRect
            guard rect.width > 0, rect.height > 0 else { return false }
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width / 2, ry = rect.height / 2
            let nx = (point.x - cx) / rx, ny = (point.y - cy) / ry
            let d = nx * nx + ny * ny
            let rNorm = threshold / min(rx, ry)
            return abs(d - 1.0) < rNorm * 2
        case .text:
            return textDrawRect.insetBy(dx: -threshold, dy: -threshold).contains(point)
        case .number:
            let radius = 8 + strokeWidth * 3 + threshold
            return hypot(point.x - startPoint.x, point.y - startPoint.y) < radius
        case .stamp:
            return boundingRect.insetBy(dx: -threshold, dy: -threshold).contains(point)
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
        if var anchors = anchorPoints {
            for i in 0..<anchors.count {
                anchors[i].x += dx
                anchors[i].y += dy
            }
            anchorPoints = anchors
        }
        // If it's a loupe, we need to clear the baked image so it re-renders the new magnified area
        if tool == .loupe {
            bakedBlurNSImage = nil
        }
    }

    /// Draw a selection highlight around this annotation
    func drawSelectionHighlight() {
        // Pencil/marker: trace the actual stroke path with a glowing outline
        if tool == .pencil || tool == .marker {
            guard let points = points, points.count >= 2 else { return }
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            ctx?.setAlpha(0.35)
            ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
            let path = NSBezierPath()
            path.move(to: points[0])
            for i in 1..<points.count { path.line(to: points[i]) }
            let effectiveWidth = tool == .marker ? strokeWidth * 6 : strokeWidth
            path.lineWidth = effectiveWidth + 6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            ToolbarLayout.accentColor.setStroke()
            path.stroke()
            ctx?.endTransparencyLayer()
            ctx?.restoreGState()
            return
        }

        let highlightRect: NSRect
        switch tool {
        case .text:
            highlightRect = textDrawRect != .zero ? textDrawRect : boundingRect
        case .number:
            let radius = 8 + strokeWidth * 3
            highlightRect = NSRect(x: startPoint.x - radius, y: startPoint.y - radius, width: radius * 2, height: radius * 2)
        case .loupe:
            highlightRect = boundingRect
        default:
            // Expand by half the stroke width so the highlight matches the visible shape
            let strokePad = strokeWidth / 2
            highlightRect = boundingRect.insetBy(dx: -strokePad, dy: -strokePad)
        }

        let padded = highlightRect.insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(roundedRect: padded, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        let pattern: [CGFloat] = [4, 4]
        path.setLineDash(pattern, count: 2, phase: 0)
        ToolbarLayout.accentColor.withAlphaComponent(0.6).setStroke()
        path.stroke()
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

    /// Minimum distance from a point to the smooth curve through waypoints.
    private func distanceToPolyline(point: NSPoint, waypoints pts: [NSPoint]) -> CGFloat {
        guard pts.count >= 2 else { return .greatestFiniteMagnitude }
        if pts.count == 2 {
            return distanceToLineSegment(point: point, from: pts[0], to: pts[1])
        }
        // Sample the Catmull-Rom spline for distance check
        let steps = pts.count * 15
        var minDist = CGFloat.greatestFiniteMagnitude
        var prev = pts[0]
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let totalSegments = CGFloat(pts.count - 1)
            let segF = t * totalSegments
            let seg = min(Int(segF), pts.count - 2)
            let localT = segF - CGFloat(seg)

            let p0 = seg > 0 ? pts[seg - 1] : pts[seg]
            let p1 = pts[seg]
            let p2 = pts[seg + 1]
            let p3 = seg + 2 < pts.count ? pts[seg + 2] : pts[seg + 1]

            let cp1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)

            let u = 1 - localT
            let px = u*u*u*p1.x + 3*u*u*localT*cp1.x + 3*u*localT*localT*cp2.x + localT*localT*localT*p2.x
            let py = u*u*u*p1.y + 3*u*u*localT*cp1.y + 3*u*localT*localT*cp2.y + localT*localT*localT*p2.y
            let cur = NSPoint(x: px, y: py)

            let d = distanceToLineSegment(point: point, from: prev, to: cur)
            if d < minDist { minDist = d }
            prev = cur
        }
        return minDist
    }

    func draw(in context: NSGraphicsContext) {
        NSGraphicsContext.current = context

        // Apply rotation around annotation center
        if rotation != 0 && supportsRotation {
            let center = NSPoint(x: boundingRect.midX, y: boundingRect.midY)
            let xform = NSAffineTransform()
            xform.translateX(by: center.x, yBy: center.y)
            xform.rotate(byRadians: rotation)
            xform.translateX(by: -center.x, yBy: -center.y)
            context.cgContext.saveGState()
            xform.concat()
        }

        switch tool {
        case .pencil:
            drawFreeform(alpha: color.alphaComponent, width: strokeWidth)
        case .line:
            drawStraightLine()
        case .arrow:
            drawArrow()
        case .rectangle:
            drawRectangle()
        case .filledRectangle:
            drawRectangle(forceFilled: true)
        case .ellipse:
            drawEllipse()
        case .marker:
            drawFreeform(alpha: 0.35, width: strokeWidth * 6)
        case .text:
            drawText()
        case .number:
            drawNumber()
        case .pixelate:
            drawCensor(in: context)
        case .blur:
            // Legacy: existing blur annotations from before the merge
            censorMode = .blur
            drawCensor(in: context)
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
        case .stamp:
            drawStamp()
        }

        if rotation != 0 && supportsRotation {
            context.cgContext.restoreGState()
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

    /// Build a smooth Catmull-Rom spline path through the given points.
    /// For 2 points: straight line. For 3+: smooth curves through all points.
    private static func smoothPath(through pts: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard pts.count >= 2 else { return path }
        path.move(to: pts[0])
        if pts.count == 2 {
            path.line(to: pts[1])
            return path
        }
        // Catmull-Rom → cubic Bezier conversion
        // For each segment i→i+1, compute control points from surrounding points
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]

            let cp1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
        }
        return path
    }

    /// Approximate length of a smooth path through waypoints.
    private static func smoothPathLength(_ pts: [NSPoint]) -> CGFloat {
        guard pts.count >= 2 else { return 0 }
        if pts.count == 2 {
            return hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
        }
        // Sample the Catmull-Rom spline
        let steps = pts.count * 20
        var length: CGFloat = 0
        var prev = pts[0]
        for s in 1...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let totalSegments = CGFloat(pts.count - 1)
            let segF = t * totalSegments
            let seg = min(Int(segF), pts.count - 2)
            let localT = segF - CGFloat(seg)

            let p0 = seg > 0 ? pts[seg - 1] : pts[seg]
            let p1 = pts[seg]
            let p2 = pts[seg + 1]
            let p3 = seg + 2 < pts.count ? pts[seg + 2] : pts[seg + 1]

            let cp1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)

            let u = 1 - localT
            let px = u*u*u*p1.x + 3*u*u*localT*cp1.x + 3*u*localT*localT*cp2.x + localT*localT*localT*p2.x
            let py = u*u*u*p1.y + 3*u*u*localT*cp1.y + 3*u*localT*localT*cp2.y + localT*localT*localT*p2.y
            let cur = NSPoint(x: px, y: py)
            length += hypot(cur.x - prev.x, cur.y - prev.y)
            prev = cur
        }
        return length
    }

    private func drawStraightLine() {
        // Multi-anchor: smooth Catmull-Rom spline
        if hasMultiAnchor {
            let pts = waypoints
            let path = Self.smoothPath(through: pts)
            path.lineWidth = strokeWidth
            path.lineCapStyle = .round
            if lineStyle != .solid {
                lineStyle.applyFitted(to: path, pathLength: Self.smoothPathLength(pts))
            }
            color.setStroke()
            path.stroke()
            return
        }

        // Legacy: straight line or single bezier bend
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
        // Thick style is a completely different shape — handle separately
        if arrowStyle == .thick {
            drawThickArrow()
            return
        }

        let pts = arrowReversed ? waypoints.reversed() : waypoints
        guard pts.count >= 2 else { return }
        let firstPt = pts.first!
        let lastPt = pts.last!

        let fullArrowLen: CGFloat = max(14, strokeWidth * 5)
        let totalLen = hypot(lastPt.x - firstPt.x, lastPt.y - firstPt.y)
        let maxHead = totalLen * 0.45
        let arrowLen: CGFloat = min(fullArrowLen, max(4, maxHead))
        let arrowAngle: CGFloat = .pi / 6

        // End arrowhead angle
        let endAngle: CGFloat
        if hasMultiAnchor {
            let preLast = pts.count >= 2 ? pts[pts.count - 2] : firstPt
            endAngle = atan2(lastPt.y - preLast.y, lastPt.x - preLast.x)
        } else if let cp = controlPoint {
            endAngle = atan2(lastPt.y - cp.y, lastPt.x - cp.x)
        } else {
            endAngle = atan2(lastPt.y - firstPt.y, lastPt.x - firstPt.x)
        }
        let ep1 = NSPoint(x: lastPt.x - arrowLen * cos(endAngle - arrowAngle),
                           y: lastPt.y - arrowLen * sin(endAngle - arrowAngle))
        let ep2 = NSPoint(x: lastPt.x - arrowLen * cos(endAngle + arrowAngle),
                           y: lastPt.y - arrowLen * sin(endAngle + arrowAngle))
        let endBase = NSPoint(x: (ep1.x + ep2.x) / 2, y: (ep1.y + ep2.y) / 2)

        // Start arrowhead geometry (for double style)
        var startBase = firstPt
        var sp1 = firstPt, sp2 = firstPt
        if arrowStyle == .double {
            let startAngle: CGFloat
            if hasMultiAnchor {
                let postFirst = pts.count >= 2 ? pts[1] : lastPt
                startAngle = atan2(firstPt.y - postFirst.y, firstPt.x - postFirst.x)
            } else if let cp = controlPoint {
                startAngle = atan2(firstPt.y - cp.y, firstPt.x - cp.x)
            } else {
                startAngle = atan2(firstPt.y - lastPt.y, firstPt.x - lastPt.x)
            }
            sp1 = NSPoint(x: firstPt.x - arrowLen * cos(startAngle - arrowAngle),
                           y: firstPt.y - arrowLen * sin(startAngle - arrowAngle))
            sp2 = NSPoint(x: firstPt.x - arrowLen * cos(startAngle + arrowAngle),
                           y: firstPt.y - arrowLen * sin(startAngle + arrowAngle))
            startBase = NSPoint(x: (sp1.x + sp2.x) / 2, y: (sp1.y + sp2.y) / 2)
        }

        // Tail circle radius
        let tailRadius: CGFloat = max(4, strokeWidth * 2)
        let lineStart = arrowStyle == .double ? startBase : firstPt

        // Draw the line shaft
        let path: NSBezierPath
        if hasMultiAnchor {
            // Multi-anchor: smooth Catmull-Rom spline
            var shaftPts = pts
            shaftPts[0] = lineStart
            shaftPts[shaftPts.count - 1] = endBase
            path = Self.smoothPath(through: shaftPts)
        } else {
            // Legacy: straight or single bezier bend
            path = NSBezierPath()
            path.move(to: lineStart)
            if let cp = controlPoint {
                path.curve(to: endBase, controlPoint1: cp, controlPoint2: cp)
            } else {
                path.line(to: endBase)
            }
        }
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        if lineStyle != .solid {
            let length = hasMultiAnchor ? Self.smoothPathLength(pts) :
                (controlPoint != nil ? Annotation.approxBezierLength(from: lineStart, cp1: controlPoint!, cp2: controlPoint!, to: endBase) :
                 hypot(endBase.x - lineStart.x, endBase.y - lineStart.y))
            lineStyle.applyFitted(to: path, pathLength: length)
        }
        color.setStroke()
        path.stroke()

        // Draw arrowhead(s)
        color.setFill()
        color.setStroke()
        switch arrowStyle {
        case .single, .tail:
            let head = NSBezierPath()
            head.move(to: lastPt)
            head.line(to: ep1)
            head.line(to: ep2)
            head.close()
            head.fill()
        case .double:
            let endHead = NSBezierPath()
            endHead.move(to: lastPt)
            endHead.line(to: ep1)
            endHead.line(to: ep2)
            endHead.close()
            endHead.fill()
            let startHead = NSBezierPath()
            startHead.move(to: firstPt)
            startHead.line(to: sp1)
            startHead.line(to: sp2)
            startHead.close()
            startHead.fill()
        case .open:
            let head = NSBezierPath()
            head.lineWidth = strokeWidth
            head.lineCapStyle = .round
            head.lineJoinStyle = .round
            head.move(to: ep1)
            head.line(to: lastPt)
            head.line(to: ep2)
            head.stroke()
        case .thick:
            break // handled by early return above
        }

        // Tail: circle at start
        if arrowStyle == .tail {
            let circleRect = NSRect(x: firstPt.x - tailRadius, y: firstPt.y - tailRadius,
                                    width: tailRadius * 2, height: tailRadius * 2)
            NSBezierPath(ovalIn: circleRect).fill()
        }
    }

    /// Sample a point and tangent along the annotation's curve at parameter t (0..1).
    /// Works for legacy bezier (controlPoint) and multi-anchor (Catmull-Rom).
    /// Returns (position, tangent) where tangent is unnormalized.
    private func sampleCurve(t: CGFloat, from start: NSPoint, to end: NSPoint) -> (pos: NSPoint, tan: NSPoint) {
        if hasMultiAnchor {
            let pts = waypoints
            let totalSegs = CGFloat(pts.count - 1)
            let segF = t * totalSegs
            let seg = min(Int(segF), pts.count - 2)
            let lt = segF - CGFloat(seg)

            let p0 = seg > 0 ? pts[seg - 1] : pts[seg]
            let p1 = pts[seg]
            let p2 = pts[seg + 1]
            let p3 = seg + 2 < pts.count ? pts[seg + 2] : pts[seg + 1]

            let cp1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let cp2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)

            let u = 1 - lt
            let px = u*u*u*p1.x + 3*u*u*lt*cp1.x + 3*u*lt*lt*cp2.x + lt*lt*lt*p2.x
            let py = u*u*u*p1.y + 3*u*u*lt*cp1.y + 3*u*lt*lt*cp2.y + lt*lt*lt*p2.y
            // Derivative of cubic bezier
            let tx = 3*u*u*(cp1.x-p1.x) + 6*u*lt*(cp2.x-cp1.x) + 3*lt*lt*(p2.x-cp2.x)
            let ty = 3*u*u*(cp1.y-p1.y) + 6*u*lt*(cp2.y-cp1.y) + 3*lt*lt*(p2.y-cp2.y)
            return (NSPoint(x: px, y: py), NSPoint(x: tx, y: ty))
        } else if let cp = controlPoint {
            // Legacy quadratic bezier (cp1 == cp2)
            let mt = 1 - t
            let bx = mt * mt * start.x + 2 * mt * t * cp.x + t * t * end.x
            let by = mt * mt * start.y + 2 * mt * t * cp.y + t * t * end.y
            let tx = 2 * mt * (cp.x - start.x) + 2 * t * (end.x - cp.x)
            let ty = 2 * mt * (cp.y - start.y) + 2 * t * (end.y - cp.y)
            return (NSPoint(x: bx, y: by), NSPoint(x: tx, y: ty))
        } else {
            // Straight line
            let bx = start.x + t * (end.x - start.x)
            let by = start.y + t * (end.y - start.y)
            let tx = end.x - start.x
            let ty = end.y - start.y
            return (NSPoint(x: bx, y: by), NSPoint(x: tx, y: ty))
        }
    }

    private func drawThickArrow() {
        let pts = arrowReversed ? waypoints.reversed() : waypoints
        let firstPt = pts.first ?? startPoint
        let lastPt = pts.last ?? endPoint
        let totalLen = hasMultiAnchor ? Self.smoothPathLength(pts) : hypot(lastPt.x - firstPt.x, lastPt.y - firstPt.y)
        guard totalLen > 1 else { return }

        // End angle: direction of the last segment approaching the tip
        let preLast = pts.count >= 2 ? pts[pts.count - 2] : firstPt
        let endAngle: CGFloat
        if hasMultiAnchor {
            endAngle = atan2(lastPt.y - preLast.y, lastPt.x - preLast.x)
        } else if let cp = controlPoint {
            endAngle = atan2(lastPt.y - cp.y, lastPt.x - cp.x)
        } else {
            endAngle = atan2(lastPt.y - firstPt.y, lastPt.x - firstPt.x)
        }
        let epx = -sin(endAngle), epy = cos(endAngle)

        // Start angle: direction leaving the tail
        let postFirst = pts.count >= 2 ? pts[1] : lastPt
        let startAngle: CGFloat
        if hasMultiAnchor {
            startAngle = atan2(postFirst.y - firstPt.y, postFirst.x - firstPt.x)
        } else if let cp = controlPoint {
            startAngle = atan2(cp.y - firstPt.y, cp.x - firstPt.x)
        } else {
            startAngle = endAngle
        }
        let spx = -sin(startAngle), spy = cos(startAngle)

        // Sizing — scale everything down when arrow is short
        let sizeScale = min(1.0, max(0.2, totalLen / 120))
        let tailHalf = max(2, strokeWidth * 0.5) * sizeScale
        let shaftHalf = max(4, strokeWidth * 1.5) * sizeScale
        let headHalf = shaftHalf * 2.0
        let headLen = min(totalLen * 0.35, headHalf * 1.8)
        let r: CGFloat = min(headLen * 0.22, headHalf * 0.3)  // corner rounding

        // Head base point
        let headBase = NSPoint(x: lastPt.x - headLen * cos(endAngle),
                               y: lastPt.y - headLen * sin(endAngle))

        // Sample points along the shaft (tail → headBase), offset perpendicular for taper
        // More samples for multi-anchor curves to avoid self-intersection at tight bends
        let steps = hasMultiAnchor ? max(64, pts.count * 32) : 64
        var leftPts: [NSPoint] = []
        var rightPts: [NSPoint] = []

        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let bx, by, tx, ty: CGFloat

            if hasMultiAnchor {
                // Sample a modified curve where the last point is headBase
                var shaftPts = pts
                shaftPts[shaftPts.count - 1] = headBase
                let totalSegs = CGFloat(shaftPts.count - 1)
                let segF = t * totalSegs
                let seg = min(Int(segF), shaftPts.count - 2)
                let lt = segF - CGFloat(seg)
                let p0 = seg > 0 ? shaftPts[seg - 1] : shaftPts[seg]
                let p1 = shaftPts[seg]
                let p2 = shaftPts[seg + 1]
                let p3 = seg + 2 < shaftPts.count ? shaftPts[seg + 2] : shaftPts[seg + 1]
                let cp1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let cp2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                let u = 1 - lt
                bx = u*u*u*p1.x + 3*u*u*lt*cp1.x + 3*u*lt*lt*cp2.x + lt*lt*lt*p2.x
                by = u*u*u*p1.y + 3*u*u*lt*cp1.y + 3*u*lt*lt*cp2.y + lt*lt*lt*p2.y
                tx = 3*u*u*(cp1.x-p1.x) + 6*u*lt*(cp2.x-cp1.x) + 3*lt*lt*(p2.x-cp2.x)
                ty = 3*u*u*(cp1.y-p1.y) + 6*u*lt*(cp2.y-cp1.y) + 3*lt*lt*(p2.y-cp2.y)
            } else if let cp = controlPoint {
                let mt = 1.0 - t
                bx = mt * mt * firstPt.x + 2 * mt * t * cp.x + t * t * headBase.x
                by = mt * mt * firstPt.y + 2 * mt * t * cp.y + t * t * headBase.y
                tx = 2 * (1 - t) * (cp.x - firstPt.x) + 2 * t * (headBase.x - cp.x)
                ty = 2 * (1 - t) * (cp.y - firstPt.y) + 2 * t * (headBase.y - cp.y)
            } else {
                bx = firstPt.x + t * (headBase.x - firstPt.x)
                by = firstPt.y + t * (headBase.y - firstPt.y)
                tx = headBase.x - firstPt.x
                ty = headBase.y - firstPt.y
            }

            let tLen = max(hypot(tx, ty), 0.001)
            let nx = -ty / tLen, ny = tx / tLen
            let half = tailHalf + (shaftHalf - tailHalf) * t
            leftPts.append(NSPoint(x: bx + nx * half, y: by + ny * half))
            rightPts.append(NSPoint(x: bx - nx * half, y: by - ny * half))
        }

        // Head wing points (the 3 triangle corners)
        let endPoint = lastPt
        let headLeft  = NSPoint(x: headBase.x + epx * headHalf, y: headBase.y + epy * headHalf)
        let headRight = NSPoint(x: headBase.x - epx * headHalf, y: headBase.y - epy * headHalf)
        let shaftLeftEnd  = leftPts.last!
        let shaftRightEnd = rightPts.last!

        // Helper: point along segment from A to B at distance d from A
        func along(_ a: NSPoint, _ b: NSPoint, _ d: CGFloat) -> NSPoint {
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let t = min(d / len, 0.45)
            return NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }

        // Build single unified path
        let path = NSBezierPath()

        // Left shaft edge (tail → head base)
        path.move(to: leftPts[0])
        for p in leftPts.dropFirst() { path.line(to: p) }

        // Corner 1: left wing (shaftLeftEnd → headLeft → endPoint)
        // Approach headLeft from shaft side, curve through headLeft, continue toward tip
        let wL1 = along(headLeft, shaftLeftEnd, r)   // before the corner, on shaft→wing edge
        let wL2 = along(headLeft, endPoint, r)        // after the corner, on wing→tip edge
        path.line(to: wL1)
        path.curve(to: wL2, controlPoint1: headLeft, controlPoint2: headLeft)

        // Corner 2: tip (headLeft → endPoint → headRight)
        let tL = along(endPoint, headLeft, r)         // before tip, on left wing→tip edge
        let tR = along(endPoint, headRight, r)        // after tip, on tip→right wing edge
        path.line(to: tL)
        path.curve(to: tR, controlPoint1: endPoint, controlPoint2: endPoint)

        // Corner 3: right wing (endPoint → headRight → shaftRightEnd)
        let wR1 = along(headRight, endPoint, r)       // before the corner, on tip→wing edge
        let wR2 = along(headRight, shaftRightEnd, r)  // after the corner, on wing→shaft edge
        path.line(to: wR1)
        path.curve(to: wR2, controlPoint1: headRight, controlPoint2: headRight)

        // Right shaft edge (head base → tail)
        path.line(to: shaftRightEnd)
        for p in rightPts.reversed().dropFirst() { path.line(to: p) }

        path.close()

        color.setFill()
        path.fill()
    }

    private func drawRectangle(forceFilled: Bool = false) {
        let rect = boundingRect
        guard rect.width > 0, rect.height > 0 else { return }
        let cornerRadius: CGFloat = rectCornerRadius > 0 ? rectCornerRadius : (isRounded ? min(rect.width, rect.height) * 0.2 : 0)
        let style = forceFilled ? RectFillStyle.fill : rectFillStyle

        switch style {
        case .fill:
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        case .strokeAndFill:
            // Fill at half the color's current alpha
            let fillAlpha = color.alphaComponent * 0.5
            color.withAlphaComponent(fillAlpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            // Stroke on top
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            path.lineWidth = strokeWidth
            if lineStyle != .solid {
                let r = min(cornerRadius, min(rect.width, rect.height) / 2)
                let perimeter = 2 * (rect.width - 2 * r) + 2 * (rect.height - 2 * r) + 2 * .pi * r
                lineStyle.applyFitted(to: path, pathLength: perimeter)
            }
            color.setStroke()
            path.stroke()

        case .stroke:
            if lineStyle == .dotted && cornerRadius < 1 {
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

        switch rectFillStyle {
        case .fill:
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()

        case .strokeAndFill:
            let fillAlpha = color.alphaComponent * 0.5
            color.withAlphaComponent(fillAlpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = strokeWidth
            if lineStyle != .solid {
                let a = rect.width / 2
                let b = rect.height / 2
                let perimeter = CGFloat.pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b)))
                lineStyle.applyFitted(to: path, pathLength: perimeter)
            }
            color.setStroke()
            path.stroke()

        case .stroke:
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = strokeWidth
            if lineStyle != .solid {
                let a = rect.width / 2
                let b = rect.height / 2
                let perimeter = CGFloat.pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b)))
                lineStyle.applyFitted(to: path, pathLength: perimeter)
            } else {
                lineStyle.apply(to: path)
            }
            color.setStroke()
            path.stroke()
        }
    }

    private func drawText() {
        guard let image = textImage, textDrawRect != .zero else { return }
        let pad: CGFloat = 4
        let pillRect = textDrawRect.insetBy(dx: -pad, dy: -pad)
        let cornerR: CGFloat = 4

        // Background pill
        if let bg = textBgColor {
            bg.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR).fill()
        }

        // Outline
        if let outline = textOutlineColor {
            outline.setStroke()
            let outlinePath = NSBezierPath(roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR)
            outlinePath.lineWidth = 2
            outlinePath.stroke()
        }

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
        let str = numberFormat.format(number) as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }

    private func drawStamp() {
        guard let image = stampImage else { return }
        let rect = boundingRect
        guard rect.width > 0, rect.height > 0 else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }

    private func drawMeasure() {
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

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
        let unit = measureInPoints ? "pt" : "px"
        let s = measureInPoints ? 1.0 : scale
        let dispDistance = Int(distance * s)
        let dispWidth = Int(abs(dx) * s)
        let dispHeight = Int(abs(dy) * s)
        let labelText: String
        if dispWidth < 3 {
            labelText = "\(dispHeight)\(unit)"
        } else if dispHeight < 3 {
            labelText = "\(dispWidth)\(unit)"
        } else {
            labelText = "\(dispDistance)\(unit) (\(dispWidth) × \(dispHeight))"
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

        let srcBounds = sourceImageBounds
        let regionImage = NSImage(size: rect.size, flipped: false) { _ in
            sourceImage.draw(in: NSRect(x: -rect.minX, y: -rect.minY,
                                         width: srcBounds.width, height: srcBounds.height),
                             from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        return regionImage
    }

    // MARK: - Pixelate

    /// Bake the processed image from source, then release the source screenshot reference.
    /// Called once when the annotation is finalized (mouseUp).
    /// Bake the censored region (pixelate, blur, or solid fill).
    /// Called by commitAnnotation() on finalization. Also handles legacy `.blur` tool.
    func bakePixelate() {
        // Legacy blur annotations + unified pixelate tool
        guard (tool == .pixelate || tool == .blur), bakedBlurNSImage == nil else { return }
        // Legacy .blur tool → set censorMode so drawing dispatches correctly
        if tool == .blur { censorMode = .blur }

        let mode = censorMode
        let rect = boundingRect

        // Solid mode: no source image needed — just a filled rect
        if mode == .solid {
            let img = NSImage(size: rect.size, flipped: false) { drawRect in
                self.color.setFill()
                NSBezierPath(rect: drawRect).fill()
                return true
            }
            bakedBlurNSImage = img
            self.sourceImage = nil
            return
        }

        guard let _ = sourceImage, let regionImage = cropRegionFromSource() else { return }
        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

        if mode == .blur {
            guard let blurredCG = applyGaussianBlur(to: cgImage) else { return }
            bakedBlurNSImage = NSImage(cgImage: blurredCG, size: rect.size)
        } else {
            // Pixelate: down-sample → up-scale with nearest-neighbor
            let pixelBlock = 8
            let tinyW = max(1, cgImage.width / pixelBlock)
            let tinyH = max(1, cgImage.height / pixelBlock)
            let cs = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

            guard let ctx1 = CGContext(data: nil, width: tinyW, height: tinyH,
                                        bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return }
            ctx1.interpolationQuality = .low
            ctx1.draw(cgImage, in: CGRect(x: 0, y: 0, width: tinyW, height: tinyH))
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
        }
        self.sourceImage = nil
    }

    /// Unified censor drawing — dispatches based on censorMode.
    private func drawCensor(in context: NSGraphicsContext) {
        let rect = boundingRect
        guard rect.width > 4, rect.height > 4 else { return }

        // Baked (finalized) — draw the result
        if let baked = bakedBlurNSImage {
            baked.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return
        }

        // Live preview while drawing
        switch censorMode {
        case .pixelate:
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(rect: rect).fill()
        case .blur:
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: rect).fill()
        case .solid:
            color.setFill()
            NSBezierPath(rect: rect).fill()
            return  // no border for solid
        }

        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        let pattern: [CGFloat] = [4, 4]
        border.setLineDash(pattern, count: 2, phase: 0)
        NSColor.white.withAlphaComponent(censorMode == .blur ? 0.7 : 0.5).setStroke()
        border.stroke()
    }

    private static let ciContext = CIContext()

    private func applyGaussianBlur(to cgImage: CGImage) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        let radius = max(10.0, min(Double(w), Double(h)) * 0.03)

        let ciImage = CIImage(cgImage: cgImage)

        guard let clamp = CIFilter(name: "CIAffineClamp") else { return nil }
        clamp.setValue(ciImage, forKey: kCIInputImageKey)
        clamp.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
        guard let clamped = clamp.outputImage else { return nil }

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(clamped, forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage else { return nil }

        let outputRect = CGRect(x: 0, y: 0, width: w, height: h)
        return Annotation.ciContext.createCGImage(output, from: outputRect)
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
        
        let magnifiedImage = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            if let ctx = NSGraphicsContext.current {
                ctx.imageInterpolation = .high
            }
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                       from: cropRect,
                       operation: .copy,
                       fraction: 1.0)
            return true
        }
        
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

extension NSColor {
    var bestContrastColor: NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return .white }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return (luminance * a) > 0.5 ? .black : .white
    }
}
