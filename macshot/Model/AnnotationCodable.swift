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
    var textGlyphStrokeColorRGBA: [CGFloat]?
    var textAlignment: Int = 0  // NSTextAlignment.rawValue
    var fontFamilyName: String?
    var textImagePNG: Data?

    // Number
    var number: Int?
    var numberFormat: Int = 0

    // Points (pencil/marker freeform paths)
    var points: [[CGFloat]]?  // [[x, y], ...]
    var pressures: [CGFloat]?  // per-point pressure (parallel to points)

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
    var isCaptureStamp: Bool?  // optional: absent in captures saved before the flag existed

    // Censor (pixelate/blur) baked result
    var bakedBlurPNG: Data?

    // Loupe
    var loupeMagnification: CGFloat?
    var loupeSourceRect: [CGFloat]?      // [x, y, w, h] for the rooted source circle
    var loupeOutlineEnabled: Bool = false

    // Misc
    var measureInPoints: Bool = false
    var censorMode: Int = 0
    var groupID: String?  // UUID string
    var randomSeed: UInt32 = 0  // 0 = legacy capture, regenerate at decode
    var dimOpacity: CGFloat = 0.55  // highlight (spotlight) dim strength

    init(
        tool: Int, startX: CGFloat, startY: CGFloat, endX: CGFloat, endY: CGFloat,
        colorRGBA: [CGFloat], strokeWidth: CGFloat
    ) {
        self.tool = tool
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
        self.colorRGBA = colorRGBA
        self.strokeWidth = strokeWidth
    }

    /// Decoded field by field so a capture saved by an older build — which has
    /// no key for a field added later — still loads. See `LenientDecoding.swift`:
    /// the synthesized decoder would throw `keyNotFound` and take every
    /// annotation in the capture down with it.
    ///
    /// Only `tool` is required; an annotation whose tool is unknown can't be
    /// drawn at all. Everything else falls back to the default above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(Int.self, forKey: .tool)
        startX = c.decode(.startX, or: 0)
        startY = c.decode(.startY, or: 0)
        endX = c.decode(.endX, or: 0)
        endY = c.decode(.endY, or: 0)
        colorRGBA = c.decode(.colorRGBA, or: [1, 0, 0, 1])
        strokeWidth = c.decode(.strokeWidth, or: 3)

        text = c.decodeOptional(.text)
        attributedTextRTF = c.decodeOptional(.attributedTextRTF)
        fontSize = c.decode(.fontSize, or: 20)
        isBold = c.decode(.isBold, or: false)
        isItalic = c.decode(.isItalic, or: false)
        isUnderline = c.decode(.isUnderline, or: false)
        isStrikethrough = c.decode(.isStrikethrough, or: false)
        textDrawRect = c.decodeOptional(.textDrawRect)
        textBgColorRGBA = c.decodeOptional(.textBgColorRGBA)
        textOutlineColorRGBA = c.decodeOptional(.textOutlineColorRGBA)
        textGlyphStrokeColorRGBA = c.decodeOptional(.textGlyphStrokeColorRGBA)
        textAlignment = c.decode(.textAlignment, or: 0)
        fontFamilyName = c.decodeOptional(.fontFamilyName)
        textImagePNG = c.decodeOptional(.textImagePNG)

        number = c.decodeOptional(.number)
        numberFormat = c.decode(.numberFormat, or: 0)

        points = c.decodeOptional(.points)
        pressures = c.decodeOptional(.pressures)

        controlPointXY = c.decodeOptional(.controlPointXY)
        anchorPoints = c.decodeOptional(.anchorPoints)

        rotation = c.decode(.rotation, or: 0)
        rectCornerRadius = c.decode(.rectCornerRadius, or: 0)
        lineStyle = c.decode(.lineStyle, or: 0)
        arrowStyle = c.decode(.arrowStyle, or: 0)
        arrowReversed = c.decode(.arrowReversed, or: false)
        rectFillStyle = c.decode(.rectFillStyle, or: 0)
        outlineColorRGBA = c.decodeOptional(.outlineColorRGBA)

        stampImagePNG = c.decodeOptional(.stampImagePNG)
        isCaptureStamp = c.decodeOptional(.isCaptureStamp)

        bakedBlurPNG = c.decodeOptional(.bakedBlurPNG)

        loupeMagnification = c.decodeOptional(.loupeMagnification)
        loupeSourceRect = c.decodeOptional(.loupeSourceRect)
        loupeOutlineEnabled = c.decode(.loupeOutlineEnabled, or: false)

        measureInPoints = c.decode(.measureInPoints, or: false)
        censorMode = c.decode(.censorMode, or: 0)
        groupID = c.decodeOptional(.groupID)
        randomSeed = c.decode(.randomSeed, or: 0)
        dimOpacity = c.decode(.dimOpacity, or: 0.55)
    }
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
        if let glyph = textGlyphStrokeColor { c.textGlyphStrokeColorRGBA = Self.encodeColor(glyph) }
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
        c.pressures = pressures

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
        if isCaptureStamp { c.isCaptureStamp = true }

        // Baked censor result (pixelate/blur/erase) — skip loupe since it
        // needs re-baking from the editor's source image at the correct coordinates.
        if tool != .loupe, let baked = bakedBlurNSImage { c.bakedBlurPNG = Self.encodeImage(baked) }

        // Loupe
        c.loupeMagnification = loupeMagnification
        if let r = loupeSourceRect {
            c.loupeSourceRect = [r.origin.x, r.origin.y, r.size.width, r.size.height]
        }
        c.loupeOutlineEnabled = loupeOutlineEnabled

        // Misc
        c.measureInPoints = measureInPoints
        c.censorMode = censorMode.rawValue
        if let gid = groupID { c.groupID = gid.uuidString }
        c.randomSeed = randomSeed
        c.dimOpacity = dimOpacity

        return c
    }

    static func fromCodable(_ c: CodableAnnotation) -> Annotation? {
        guard let tool = AnnotationTool(rawValue: c.tool),
              let start = SavedCaptureValidation.point([c.startX, c.startY]),
              let end = SavedCaptureValidation.point([c.endX, c.endY]) else { return nil }
        let ann = Annotation(
            tool: tool,
            startPoint: start,
            endPoint: end,
            color: decodeColor(c.colorRGBA),
            strokeWidth: SavedCaptureValidation.bounded(c.strokeWidth, 0...1024, fallback: 3)
        )

        // Text
        guard (c.text?.utf8.count ?? 0) <= SavedCaptureValidation.maximumRTFBytes else { return nil }
        ann.text = c.text
        if let rtfData = c.attributedTextRTF {
            guard rtfData.count <= SavedCaptureValidation.maximumRTFBytes,
                  let decoded = NSAttributedString(rtf: rtfData, documentAttributes: nil) else { return nil }
            // Convert any legacy centered .strokeWidth glyph stroke (from files
            // saved before #257) into the outside-outline attribute so it renders
            // through OutlineTextLayoutManager instead of the old thin stroke.
            let mutable = NSMutableAttributedString(attributedString: decoded)
            OutlineTextRenderer.normalizeLegacyStroke(mutable)
            ann.attributedText = mutable
        }
        ann.fontSize = SavedCaptureValidation.bounded(c.fontSize, 1...4096, fallback: 20)
        ann.isBold = c.isBold
        ann.isItalic = c.isItalic
        ann.isUnderline = c.isUnderline
        ann.isStrikethrough = c.isStrikethrough
        if let r = c.textDrawRect { ann.textDrawRect = SavedCaptureValidation.rect(r) ?? .zero }
        if let rgba = c.textBgColorRGBA { ann.textBgColor = decodeColor(rgba) }
        if let rgba = c.textOutlineColorRGBA { ann.textOutlineColor = decodeColor(rgba) }
        if let rgba = c.textGlyphStrokeColorRGBA { ann.textGlyphStrokeColor = decodeColor(rgba) }
        ann.textAlignment = NSTextAlignment(rawValue: c.textAlignment) ?? .left
        ann.fontFamilyName = c.fontFamilyName
        if let data = c.textImagePNG {
            guard let image = SavedCaptureValidation.image(data) else { return nil }
            ann.textImage = image
        }

        // Number
        ann.number = c.number
        ann.numberFormat = NumberFormat(rawValue: c.numberFormat) ?? .decimal

        // Points
        if let pts = c.points {
            ann.points = pts.compactMap { SavedCaptureValidation.point($0) }
        }
        // Preserve pressure-to-point correspondence when dropping a malformed
        // point; never shift later pressures onto the wrong segment.
        if let pressures = c.pressures, let points = c.points {
            ann.pressures = points.enumerated().compactMap { index, point in
                guard SavedCaptureValidation.point(point) != nil else { return nil }
                return SavedCaptureValidation.bounded(index < pressures.count ? pressures[index] : 1, 0...1, fallback: 1)
            }
        }

        // Control/anchor points
        if let cp = c.controlPointXY { ann.controlPoint = SavedCaptureValidation.point(cp) }
        if let anchors = c.anchorPoints {
            ann.anchorPoints = anchors.compactMap { SavedCaptureValidation.point($0) }
        }

        // Shape style
        ann.rotation = SavedCaptureValidation.bounded(c.rotation, -1_000_000...1_000_000, fallback: 0)
        ann.rectCornerRadius = SavedCaptureValidation.bounded(c.rectCornerRadius, 0...1024, fallback: 0)
        ann.lineStyle = LineStyle(rawValue: c.lineStyle) ?? .solid
        ann.arrowStyle = ArrowStyle(rawValue: c.arrowStyle) ?? .single
        ann.arrowReversed = c.arrowReversed
        ann.rectFillStyle = RectFillStyle(rawValue: c.rectFillStyle) ?? .stroke
        if let rgba = c.outlineColorRGBA { ann.outlineColor = decodeColor(rgba) }

        // Stamp
        if let data = c.stampImagePNG {
            guard let image = SavedCaptureValidation.image(data) else { return nil }
            ann.stampImage = image
        }
        ann.isCaptureStamp = c.isCaptureStamp ?? false

        // Baked censor result
        if let data = c.bakedBlurPNG {
            guard let image = SavedCaptureValidation.image(data) else { return nil }
            ann.bakedBlurNSImage = image
        }

        // Loupe
        ann.loupeMagnification = SavedCaptureValidation.bounded(c.loupeMagnification ?? 2, 0.1...100, fallback: 2)
        if let r = c.loupeSourceRect { ann.loupeSourceRect = SavedCaptureValidation.rect(r) }
        ann.loupeOutlineEnabled = c.loupeOutlineEnabled

        // Misc
        ann.measureInPoints = c.measureInPoints
        ann.censorMode = CensorMode(rawValue: c.censorMode) ?? .pixelate
        // Highlight dim strength; older captures lack the field (decodes to the
        // struct default 0.55). Guard against a zero/invalid value.
        ann.dimOpacity = c.dimOpacity.isFinite && c.dimOpacity > 0 ? min(1, c.dimOpacity) : 0.55
        if let gidStr = c.groupID { ann.groupID = UUID(uuidString: gidStr) }
        // Legacy captures have seed=0; assign a fresh one so sketchy variation
        // remains deterministic per-load even for old data.
        ann.randomSeed = c.randomSeed != 0 ? c.randomSeed : UInt32.random(in: 1...UInt32.max)

        // Files saved before #257 cached a text image with the old centered
        // glyph stroke. Re-render stroked text through the outside-outline path
        // so reloaded annotations look correct (no-op for text without a stroke).
        if ann.tool == .text, ann.textGlyphStrokeColor != nil,
           ann.attributedText != nil, ann.textDrawRect != .zero {
            guard ann.reRenderTextImage() else { return nil }
        }

        return ann
    }

    // MARK: - Helpers

    private static func encodeColor(_ color: NSColor) -> [CGFloat] {
        // Convert to sRGB to ensure consistent encoding regardless of display profile
        let c = color.usingColorSpace(.sRGB) ?? color
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    private static func decodeColor(_ rgba: [CGFloat]) -> NSColor {
        guard rgba.count >= 4, rgba.prefix(4).allSatisfy(\.isFinite) else { return .red }
        let clamped = rgba.prefix(4).map { min(1, max(0, $0)) }
        return NSColor(srgbRed: clamped[0], green: clamped[1], blue: clamped[2], alpha: clamped[3])
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

    static func decode(_ data: Data, requireAll: Bool = false) -> [Annotation]? {
        if requireAll {
            // Editing raw pixels must not silently omit an unreadable annotation
            // (particularly a censor). The caller can use the flattened capture.
            guard let codables = try? JSONDecoder().decode([CodableAnnotation].self, from: data) else { return nil }
            let annotations = codables.compactMap { Annotation.fromCodable($0) }
            return annotations.count == codables.count ? annotations : nil
        }
        // Element-wise so one unreadable annotation costs that annotation
        // rather than every annotation in the capture.
        guard let codables = LenientArrayDecoder.decode(CodableAnnotation.self, from: data) else { return nil }
        let annotations = codables.compactMap { Annotation.fromCodable($0) }
        return annotations.isEmpty ? nil : annotations
    }
}
