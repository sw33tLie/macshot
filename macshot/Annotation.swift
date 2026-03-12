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
    var fontSize: CGFloat = 16
    var isBold: Bool = false
    var isItalic: Bool = false
    var groupID: UUID?  // for batch undo (e.g. auto-redact)
    var isUnderline: Bool = false
    var isStrikethrough: Bool = false

    init(tool: AnnotationTool, startPoint: NSPoint, endPoint: NSPoint, color: NSColor, strokeWidth: CGFloat) {
        self.tool = tool
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.color = color
        self.strokeWidth = strokeWidth
    }

    var boundingRect: NSRect {
        return NSRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    func draw(in context: NSGraphicsContext) {
        NSGraphicsContext.current = context

        switch tool {
        case .pencil:
            drawFreeform(alpha: 1.0, width: strokeWidth)
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
            drawFreeform(alpha: 0.35, width: max(20, strokeWidth * 6))
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
        }
    }

    // MARK: - Drawing methods

    private func drawFreeform(alpha: CGFloat, width: CGFloat) {
        guard let points = points, points.count > 1 else { return }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.withAlphaComponent(alpha).setStroke()
        path.move(to: points[0])
        for i in 1..<points.count {
            path.line(to: points[i])
        }
        path.stroke()
    }

    private func drawStraightLine() {
        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.move(to: startPoint)
        path.line(to: endPoint)
        path.stroke()
    }

    private func drawArrow() {
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
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
        color.setStroke()
        path.move(to: startPoint)
        path.line(to: lineEnd)
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
        if filled {
            color.setFill()
            NSBezierPath(rect: rect).fill()
        } else {
            let path = NSBezierPath(rect: rect)
            path.lineWidth = strokeWidth
            color.setStroke()
            path.stroke()
        }
    }

    private func drawEllipse() {
        let rect = boundingRect
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = strokeWidth
        color.setStroke()
        path.stroke()
    }

    private func drawText() {
        // Prefer rich attributed text if available
        if let attrText = attributedText, attrText.length > 0 {
            attrText.draw(at: startPoint)
            return
        }

        guard let text = text, !text.isEmpty else { return }

        var font: NSFont
        if isBold && isItalic {
            font = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: fontSize, weight: .bold),
                toHaveTrait: .italicFontMask
            )
        } else if isItalic {
            font = NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: fontSize, weight: .regular),
                toHaveTrait: .italicFontMask
            )
        } else {
            font = NSFont.systemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        if isUnderline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if isStrikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        (text as NSString).draw(at: startPoint, withAttributes: attrs)
    }

    private func drawNumber() {
        guard let number = number else { return }
        let radius: CGFloat = max(14, strokeWidth * 4)
        let center = startPoint
        let circleRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        color.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        let fontSize = radius * 1.1
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: NSColor.white
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
        let pixelBlock = 16
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
}
