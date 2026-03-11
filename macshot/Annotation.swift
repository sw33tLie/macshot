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
    var bakedPixelateImage: CGImage?  // baked pixelated result (sourceImage released after bake)
    var fontSize: CGFloat = 16
    var isBold: Bool = false
    var isItalic: Bool = false
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

    /// Bake the processed image from source, then release the source screenshot reference.
    /// Called once when the annotation is finalized (mouseUp).
    func bakePixelate() {
        if tool == .blur {
            bakeBlur()
            return
        }
        guard tool == .pixelate, bakedPixelateImage == nil, let sourceImage = sourceImage else { return }

        let rect = boundingRect
        guard rect.width > 4, rect.height > 4 else { return }

        var cgImage: CGImage?
        if let imgRef = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cgImage = imgRef
        } else if let tiffData = sourceImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) {
            cgImage = bitmap.cgImage
        }
        guard let srcCG = cgImage else { return }

        let imgW = CGFloat(srcCG.width)
        let imgH = CGFloat(srcCG.height)
        let boundsW = sourceImageBounds.width
        let boundsH = sourceImageBounds.height
        let scaleX = imgW / boundsW
        let scaleY = imgH / boundsH

        let pixelX = Int((rect.minX - sourceImageBounds.minX) * scaleX)
        let pixelY = Int((boundsH - (rect.maxY - sourceImageBounds.minY)) * scaleY)
        let pixelW = Int(rect.width * scaleX)
        let pixelH = Int(rect.height * scaleY)
        guard pixelW > 0, pixelH > 0 else { return }

        let cropRect = CGRect(
            x: max(0, pixelX), y: max(0, pixelY),
            width: min(pixelW, Int(imgW) - max(0, pixelX)),
            height: min(pixelH, Int(imgH) - max(0, pixelY))
        )
        guard cropRect.width > 0, cropRect.height > 0,
              let cropped = srcCG.cropping(to: cropRect) else { return }

        let blockSize = max(10, Int(min(rect.width, rect.height) / 6))
        let tinyW = max(1, Int(cropRect.width) / blockSize)
        let tinyH = max(1, Int(cropRect.height) / blockSize)
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

        let finalW = max(1, Int(rect.width * 2))  // store at 2x for quality
        let finalH = max(1, Int(rect.height * 2))
        guard let ctx3 = CGContext(data: nil, width: finalW, height: finalH,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return }
        ctx3.interpolationQuality = .none
        ctx3.draw(tiny2, in: CGRect(x: 0, y: 0, width: finalW, height: finalH))

        bakedPixelateImage = ctx3.makeImage()

        // Release the full screenshot reference
        self.sourceImage = nil
    }

    private func drawPixelate(in context: NSGraphicsContext) {
        let rect = boundingRect
        guard rect.width > 4, rect.height > 4 else { return }

        // Use baked image if available (finalized annotation)
        if let baked = bakedPixelateImage {
            let cgCtx = context.cgContext
            cgCtx.saveGState()
            cgCtx.translateBy(x: rect.minX, y: rect.maxY)
            cgCtx.scaleBy(x: 1, y: -1)
            cgCtx.draw(baked, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            cgCtx.restoreGState()
            return
        }

        // Live preview while drawing — use sourceImage directly
        guard let sourceImage = sourceImage else { return }

        var cgImage: CGImage?
        if let imgRef = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cgImage = imgRef
        } else if let tiffData = sourceImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) {
            cgImage = bitmap.cgImage
        }
        guard let srcCG = cgImage else { return }

        let imgW = CGFloat(srcCG.width)
        let imgH = CGFloat(srcCG.height)
        let boundsW = sourceImageBounds.width
        let boundsH = sourceImageBounds.height
        let scaleX = imgW / boundsW
        let scaleY = imgH / boundsH

        let pixelX = Int((rect.minX - sourceImageBounds.minX) * scaleX)
        let pixelY = Int((boundsH - (rect.maxY - sourceImageBounds.minY)) * scaleY)
        let pixelW = Int(rect.width * scaleX)
        let pixelH = Int(rect.height * scaleY)
        guard pixelW > 0, pixelH > 0 else { return }

        let cropRect = CGRect(
            x: max(0, pixelX), y: max(0, pixelY),
            width: min(pixelW, Int(imgW) - max(0, pixelX)),
            height: min(pixelH, Int(imgH) - max(0, pixelY))
        )
        guard cropRect.width > 0, cropRect.height > 0,
              let cropped = srcCG.cropping(to: cropRect) else { return }

        let blockSize = max(10, Int(min(rect.width, rect.height) / 6))
        let tinyW = max(1, Int(cropRect.width) / blockSize)
        let tinyH = max(1, Int(cropRect.height) / blockSize)
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

        let finalW = max(1, Int(rect.width))
        let finalH = max(1, Int(rect.height))
        guard let ctx3 = CGContext(data: nil, width: finalW, height: finalH,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: bitmapInfo) else { return }
        ctx3.interpolationQuality = .none
        ctx3.draw(tiny2, in: CGRect(x: 0, y: 0, width: finalW, height: finalH))
        guard let pixelated = ctx3.makeImage() else { return }

        let cgCtx = context.cgContext
        cgCtx.saveGState()
        cgCtx.translateBy(x: rect.minX, y: rect.maxY)
        cgCtx.scaleBy(x: 1, y: -1)
        cgCtx.draw(pixelated, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        cgCtx.restoreGState()
    }

    // MARK: - Blur

    private func cropFromSource() -> CGImage? {
        guard let sourceImage = sourceImage else { return nil }
        let rect = boundingRect
        guard rect.width > 4, rect.height > 4 else { return nil }

        var cgImage: CGImage?
        if let imgRef = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cgImage = imgRef
        } else if let tiffData = sourceImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) {
            cgImage = bitmap.cgImage
        }
        guard let srcCG = cgImage else { return nil }

        let imgW = CGFloat(srcCG.width)
        let imgH = CGFloat(srcCG.height)
        let boundsW = sourceImageBounds.width
        let boundsH = sourceImageBounds.height
        let scaleX = imgW / boundsW
        let scaleY = imgH / boundsH

        let pixelX = Int((rect.minX - sourceImageBounds.minX) * scaleX)
        let pixelY = Int((boundsH - (rect.maxY - sourceImageBounds.minY)) * scaleY)
        let pixelW = Int(rect.width * scaleX)
        let pixelH = Int(rect.height * scaleY)
        guard pixelW > 0, pixelH > 0 else { return nil }

        let cropRect = CGRect(
            x: max(0, pixelX), y: max(0, pixelY),
            width: min(pixelW, Int(imgW) - max(0, pixelX)),
            height: min(pixelH, Int(imgH) - max(0, pixelY))
        )
        guard cropRect.width > 0, cropRect.height > 0 else { return nil }
        return srcCG.cropping(to: cropRect)
    }

    private func applyGaussianBlur(to cgImage: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        let radius = max(10.0, min(Double(cgImage.width), Double(cgImage.height)) * 0.03)

        // Clamp edges to avoid dark border artifacts from blur sampling beyond image bounds
        guard let clamp = CIFilter(name: "CIAffineClamp") else { return nil }
        clamp.setValue(ciImage, forKey: kCIInputImageKey)
        clamp.setValue(NSAffineTransform(), forKey: kCIInputTransformKey)
        guard let clamped = clamp.outputImage else { return nil }

        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(clamped, forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage else { return nil }

        // Crop back to original extent (blur expands the image)
        let cropped = output.cropped(to: extent)
        let ciContext = CIContext()
        return ciContext.createCGImage(cropped, from: extent)
    }

    private func bakeBlur() {
        guard tool == .blur, bakedPixelateImage == nil else { return }
        guard let cropped = cropFromSource() else { return }
        bakedPixelateImage = applyGaussianBlur(to: cropped)
        self.sourceImage = nil
    }

    private func drawBlur(in context: NSGraphicsContext) {
        let rect = boundingRect
        guard rect.width > 4, rect.height > 4 else { return }

        if let baked = bakedPixelateImage {
            let cgCtx = context.cgContext
            cgCtx.saveGState()
            cgCtx.translateBy(x: rect.minX, y: rect.maxY)
            cgCtx.scaleBy(x: 1, y: -1)
            cgCtx.draw(baked, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            cgCtx.restoreGState()
            return
        }

        // Live preview while dragging: frosted overlay indicator (real blur applied on mouseUp)
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: rect).fill()

        // Dashed border to show the blur region
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        let pattern: [CGFloat] = [4, 4]
        border.setLineDash(pattern, count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        border.stroke()
    }
}
