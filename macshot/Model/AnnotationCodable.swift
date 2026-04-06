import Cocoa

// MARK: - Codable conformance for Annotation

/// Intermediate Codable representation of an Annotation.
/// Uses simple types (Data, [CGFloat], etc.) to avoid custom NSColor/NSImage coding.
struct CodableAnnotation: Codable {
    // Core
    let tool: Int  // AnnotationTool.rawValue
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let colorRGBA: [CGFloat]  // [r, g, b, a]
    let strokeWidth: CGFloat

    // Text
    var text: String?
    var attributedTextRTF: Data?  // RTF encoding of NSAttributedString
    var fontSize: CGFloat = 20
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var isStrikethrough: Bool = false
    var textDrawRect: [CGFloat]?  // [x, y, w, h]
    var textBgColorRGBA: [CGFloat]?
    var textOutlineColorRGBA: [CGFloat]?
    var textAlignment: Int = 0  // NSTextAlignment.rawValue
    var fontFamilyName: String?
    var textImagePNG: Data?

    // Number
    var number: Int?
    var numberFormat: Int = 0

    // Points (pencil/marker freeform paths)
    var points: [[CGFloat]]?  // [[x, y], ...]

    // Line/arrow bend points
    var controlPointXY: [CGFloat]?  // [x, y]
    var anchorPoints: [[CGFloat]]?  // [[x, y], ...]

    // Shape style
    var rotation: CGFloat = 0
    var rectCornerRadius: CGFloat = 0
    var lineStyle: Int = 0
    var arrowStyle: Int = 0
    var arrowReversed: Bool = false
    var rectFillStyle: Int = 0
    var outlineColorRGBA: [CGFloat]?

    // Stamp
    var stampImagePNG: Data?

    // Censor (pixelate/blur) baked result
    var bakedBlurPNG: Data?

    // Misc
    var measureInPoints: Bool = false
    var censorMode: Int = 0
    var groupID: String?  // UUID string
}

extension Annotation {

    func toCodable() -> CodableAnnotation {
        var c = CodableAnnotation(
            tool: tool.rawValue,
            startX: startPoint.x,
            startY: startPoint.y,
            endX: endPoint.x,
            endY: endPoint.y,
            colorRGBA: Self.encodeColor(color),
            strokeWidth: strokeWidth
        )

        // Text
        c.text = text
        if let attrText = attributedText {
            c.attributedTextRTF = try? attrText.data(
                from: NSRange(location: 0, length: attrText.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
        c.fontSize = fontSize
        c.isBold = isBold
        c.isItalic = isItalic
        c.isUnderline = isUnderline
        c.isStrikethrough = isStrikethrough
        if textDrawRect != .zero {
            c.textDrawRect = [textDrawRect.origin.x, textDrawRect.origin.y, textDrawRect.width, textDrawRect.height]
        }
        if let bg = textBgColor { c.textBgColorRGBA = Self.encodeColor(bg) }
        if let outline = textOutlineColor { c.textOutlineColorRGBA = Self.encodeColor(outline) }
        c.textAlignment = textAlignment.rawValue
        c.fontFamilyName = fontFamilyName
        if let img = textImage { c.textImagePNG = Self.encodeImage(img) }

        // Number
        c.number = number
        c.numberFormat = numberFormat.rawValue

        // Points
        if let pts = points {
            c.points = pts.map { [$0.x, $0.y] }
        }

        // Control/anchor points
        if let cp = controlPoint { c.controlPointXY = [cp.x, cp.y] }
        if let anchors = anchorPoints {
            c.anchorPoints = anchors.map { [$0.x, $0.y] }
        }

        // Shape style
        c.rotation = rotation
        c.rectCornerRadius = rectCornerRadius
        c.lineStyle = lineStyle.rawValue
        c.arrowStyle = arrowStyle.rawValue
        c.arrowReversed = arrowReversed
        c.rectFillStyle = rectFillStyle.rawValue
        if let oc = outlineColor { c.outlineColorRGBA = Self.encodeColor(oc) }

        // Stamp
        if let stamp = stampImage { c.stampImagePNG = Self.encodeImage(stamp) }

        // Baked censor result (pixelate/blur/erase) — skip loupe since it
        // needs re-baking from the editor's source image at the correct coordinates.
        if tool != .loupe, let baked = bakedBlurNSImage { c.bakedBlurPNG = Self.encodeImage(baked) }

        // Misc
        c.measureInPoints = measureInPoints
        c.censorMode = censorMode.rawValue
        if let gid = groupID { c.groupID = gid.uuidString }

        return c
    }

    static func fromCodable(_ c: CodableAnnotation) -> Annotation? {
        guard let tool = AnnotationTool(rawValue: c.tool) else { return nil }
        let ann = Annotation(
            tool: tool,
            startPoint: NSPoint(x: c.startX, y: c.startY),
            endPoint: NSPoint(x: c.endX, y: c.endY),
            color: decodeColor(c.colorRGBA),
            strokeWidth: c.strokeWidth
        )

        // Text
        ann.text = c.text
        if let rtfData = c.attributedTextRTF {
            ann.attributedText = NSAttributedString(rtf: rtfData, documentAttributes: nil)
        }
        ann.fontSize = c.fontSize
        ann.isBold = c.isBold
        ann.isItalic = c.isItalic
        ann.isUnderline = c.isUnderline
        ann.isStrikethrough = c.isStrikethrough
        if let r = c.textDrawRect, r.count == 4 {
            ann.textDrawRect = NSRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }
        if let rgba = c.textBgColorRGBA { ann.textBgColor = decodeColor(rgba) }
        if let rgba = c.textOutlineColorRGBA { ann.textOutlineColor = decodeColor(rgba) }
        ann.textAlignment = NSTextAlignment(rawValue: c.textAlignment) ?? .left
        ann.fontFamilyName = c.fontFamilyName
        if let data = c.textImagePNG { ann.textImage = NSImage(data: data) }

        // Number
        ann.number = c.number
        ann.numberFormat = NumberFormat(rawValue: c.numberFormat) ?? .decimal

        // Points
        if let pts = c.points {
            ann.points = pts.compactMap { p in
                guard p.count == 2 else { return nil }
                return NSPoint(x: p[0], y: p[1])
            }
        }

        // Control/anchor points
        if let cp = c.controlPointXY, cp.count == 2 {
            ann.controlPoint = NSPoint(x: cp[0], y: cp[1])
        }
        if let anchors = c.anchorPoints {
            ann.anchorPoints = anchors.compactMap { p in
                guard p.count == 2 else { return nil }
                return NSPoint(x: p[0], y: p[1])
            }
        }

        // Shape style
        ann.rotation = c.rotation
        ann.rectCornerRadius = c.rectCornerRadius
        ann.lineStyle = LineStyle(rawValue: c.lineStyle) ?? .solid
        ann.arrowStyle = ArrowStyle(rawValue: c.arrowStyle) ?? .single
        ann.arrowReversed = c.arrowReversed
        ann.rectFillStyle = RectFillStyle(rawValue: c.rectFillStyle) ?? .stroke
        if let rgba = c.outlineColorRGBA { ann.outlineColor = decodeColor(rgba) }

        // Stamp
        if let data = c.stampImagePNG { ann.stampImage = NSImage(data: data) }

        // Baked censor result
        if let data = c.bakedBlurPNG { ann.bakedBlurNSImage = NSImage(data: data) }

        // Misc
        ann.measureInPoints = c.measureInPoints
        ann.censorMode = CensorMode(rawValue: c.censorMode) ?? .pixelate
        if let gidStr = c.groupID { ann.groupID = UUID(uuidString: gidStr) }

        return ann
    }

    // MARK: - Helpers

    private static func encodeColor(_ color: NSColor) -> [CGFloat] {
        // Convert to sRGB to ensure consistent encoding regardless of display profile
        let c = color.usingColorSpace(.sRGB) ?? color
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    private static func decodeColor(_ rgba: [CGFloat]) -> NSColor {
        guard rgba.count >= 4 else { return .red }
        return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
    }

    private static func encodeImage(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Batch encode/decode for history storage

enum AnnotationSerializer {

    static func encode(_ annotations: [Annotation]) -> Data? {
        let codables = annotations.map { $0.toCodable() }
        return try? JSONEncoder().encode(codables)
    }

    static func decode(_ data: Data) -> [Annotation]? {
        guard let codables = try? JSONDecoder().decode([CodableAnnotation].self, from: data) else { return nil }
        let annotations = codables.compactMap { Annotation.fromCodable($0) }
        return annotations.isEmpty ? nil : annotations
    }
}
