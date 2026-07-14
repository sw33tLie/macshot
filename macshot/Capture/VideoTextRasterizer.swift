import AppKit

/// Pure rasterizer: turns a `VideoTextSegment` spec into a CGImage sized to
/// fill its rect at the composition's render resolution. The result is then
/// wrapped in a `CIImage` and composited per-frame by the video compositor.
///
/// The rasterizer is called only when something visible changes (text,
/// font family/size, weight, color, bg style/color, outline, alignment,
/// or the rect's pixel size). At per-frame time the compositor reuses the
/// cached CGImage, so font shaping and glyph drawing do not run at video
/// frame rate.
enum VideoTextRasterizer {

    /// Snapshot of inputs that affect the rendered pixels. Two specs that
    /// compare equal produce identical CGImages, so the caller can use this
    /// as a cache key to decide whether to re-rasterize.
    struct Spec: Hashable {
        let text: String
        let fontSize: CGFloat       // logical pt at 1080p reference
        let bold: Bool
        let italic: Bool
        /// Font family name; "System" = the system UI font.
        let fontFamily: String
        let textColor: VideoTextSegment.RGBA
        let bgStyle: VideoTextSegment.BackgroundStyle
        let bgColor: VideoTextSegment.RGBA
        /// Glyph outline (stroke rendered behind the fill). Width is
        /// logical pt at the same 1080p reference as `fontSize`.
        let outlineEnabled: Bool
        let outlineColor: VideoTextSegment.RGBA
        let outlineWidth: CGFloat
        let alignment: VideoTextSegment.Alignment
        /// Pixel width of the target rect in render space.
        let pixelWidth: Int
        /// Pixel height of the target rect in render space.
        let pixelHeight: Int
        /// Total render-canvas height in pixels (i.e. the composition's
        /// renderSize.height). The rasterizer scales fontSize against
        /// 1080 so the visual text size is consistent across export
        /// resolutions; this lives in the spec so the cache invalidates
        /// when the render resolution changes.
        let renderHeight: Int
    }

    /// Build a Spec from a segment + the rect's pixel size in render space.
    static func spec(for segment: VideoTextSegment,
                     pixelWidth: Int,
                     pixelHeight: Int,
                     renderHeight: Int) -> Spec {
        Spec(text: segment.text,
             fontSize: segment.fontSize,
             bold: segment.bold,
             italic: segment.italic,
             fontFamily: segment.fontFamily,
             textColor: segment.textColor,
             bgStyle: segment.bgStyle,
             bgColor: segment.bgColor,
             outlineEnabled: segment.outlineEnabled,
             outlineColor: segment.outlineColor,
             outlineWidth: segment.outlineWidth,
             alignment: segment.alignment,
             pixelWidth: pixelWidth,
             pixelHeight: pixelHeight,
             renderHeight: renderHeight)
    }

    /// Rasterize. Returns nil if the canvas is degenerate (e.g. zero pixels
    /// in either dimension, which can happen during initial layout before
    /// the renderSize is known).
    static func render(_ spec: Spec, referenceHeight1080: CGFloat = 1080) -> CGImage? {
        guard spec.pixelWidth > 0, spec.pixelHeight > 0 else { return nil }

        let pxW = spec.pixelWidth
        let pxH = spec.pixelHeight

        // Scale the logical font size to actual pixels. fontSize is given at
        // a 1080p reference height; scale by the canvas's render height so
        // 720p exports get smaller text and 4K exports get larger text in
        // the same logical position. Default to 1× if renderHeight is
        // missing (avoids zero-size text on early-render edge cases).
        let renderH = CGFloat(max(spec.renderHeight, 1))
        let scale = renderH / referenceHeight1080
        var pxFontSize = max(8, spec.fontSize * scale)

        // Cap font size to the rect's height so very tall rects don't draw
        // text that immediately gets clipped by the canvas. This is a
        // practical ceiling, not a quality knob — single-line text fits
        // comfortably within ~80% of the rect's height.
        let maxByRect = CGFloat(pxH) * 0.78
        if pxFontSize > maxByRect { pxFontSize = max(8, maxByRect) }

        // Use deviceRGB with premultipliedFirst so the result composites
        // cleanly when wrapped in CIImage. Same byte order as the
        // compositor's pixel buffer (kCVPixelFormatType_32BGRA).
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil,
                                   width: pxW,
                                   height: pxH,
                                   bitsPerComponent: 8,
                                   bytesPerRow: 0,
                                   space: colorSpace,
                                   bitmapInfo: bitmapInfo) else {
            return nil
        }

        // Drive AppKit drawing into our context.
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let fullRect = NSRect(x: 0, y: 0, width: CGFloat(pxW), height: CGFloat(pxH))

        // Clear (CGContext starts with garbage memory).
        ctx.clear(fullRect)

        // 1. Background fill.
        switch spec.bgStyle {
        case .none:
            break
        case .solid:
            nsColor(spec.bgColor).setFill()
            NSBezierPath(rect: fullRect).fill()
        case .rounded:
            // Radius = ~25% of the shorter side, capped at 16% of height.
            // This gives a proper "pill" feel on tall labels and a soft
            // rounded rect on short ones.
            let shortSide = min(fullRect.width, fullRect.height)
            let radius = min(shortSide * 0.25, fullRect.height * 0.30)
            nsColor(spec.bgColor).setFill()
            NSBezierPath(roundedRect: fullRect, xRadius: radius, yRadius: radius).fill()
        }

        // 2. Text.
        let descriptor = NSFontDescriptor(name: "", size: pxFontSize)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if spec.bold { traits.insert(.bold) }
        if spec.italic { traits.insert(.italic) }
        let font: NSFont = {
            // Custom family: resolve by name (NSFont accepts family names
            // for most installed fonts), falling back to an explicit family
            // lookup, then apply bold/italic via NSFontManager — descriptor
            // trait synthesis is unreliable for third-party families.
            // Missing families fall through to the system-font path below.
            if spec.fontFamily != "System" {
                let fm = NSFontManager.shared
                let named = NSFont(name: spec.fontFamily, size: pxFontSize)
                    ?? fm.font(withFamily: spec.fontFamily, traits: [], weight: 5, size: pxFontSize)
                if var f = named {
                    if spec.bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
                    if spec.italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
                    return f
                }
            }
            // Start from the system font so we get SF/the default UI font,
            // then apply traits via descriptor. Fall back to plain system
            // font of the same weight if descriptor synthesis fails.
            let base = NSFont.systemFont(ofSize: pxFontSize,
                                          weight: spec.bold ? .bold : .regular)
            if !traits.isEmpty {
                let d = base.fontDescriptor.withSymbolicTraits(traits)
                if let f = NSFont(descriptor: d, size: pxFontSize) { return f }
            }
            return base
        }()

        let para = NSMutableParagraphStyle()
        switch spec.alignment {
        case .left:   para.alignment = .left
        case .center: para.alignment = .center
        case .right:  para.alignment = .right
        }
        para.lineBreakMode = .byTruncatingTail

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColor(spec.textColor),
            .paragraphStyle: para,
        ]
        let attributed = NSAttributedString(string: spec.text, attributes: attrs)

        // Inset the text rect slightly inside the bg so descenders / italics
        // don't kiss the edges. Pad relative to font size so it scales.
        let pad = pxFontSize * 0.18
        let textRect = fullRect.insetBy(dx: pad, dy: pad * 0.5)

        // Compute the natural drawing height (one or more lines word-wrapped
        // to textRect.width) so we can vertically center it. Use a generous
        // wrapping width with `usedRect` to get the actual rendered size.
        let layoutSize = NSSize(width: textRect.width,
                                 height: CGFloat.greatestFiniteMagnitude)
        let bounding = attributed.boundingRect(
            with: layoutSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let drawY = textRect.midY - bounding.height / 2
        // Clamp so we never draw outside the canvas — better to truncate
        // than to clip mid-glyph. NSAttributedString.draw(in:) already does
        // its own clipping.
        let drawRect = NSRect(x: textRect.minX,
                              y: max(textRect.minY, drawY),
                              width: textRect.width,
                              height: min(textRect.height, bounding.height + 2))

        // Glyph outline — a stroke-only pass drawn *under* the fill. A
        // positive .strokeWidth strokes the glyph path without filling; the
        // fill pass on top then covers the inner half of the stroke, leaving
        // a clean outer rim. .strokeWidth is expressed in percent of the
        // font size, so convert the logical width (1080p-reference points,
        // scaled like fontSize, doubled because half of the centered stroke
        // hides under the fill) to a percentage.
        if spec.outlineEnabled, spec.outlineWidth > 0 {
            let pxOutline = max(0.5, spec.outlineWidth * scale)
            let strokePercent = (pxOutline * 2 / pxFontSize) * 100
            var strokeAttrs = attrs
            strokeAttrs[.strokeColor] = nsColor(spec.outlineColor)
            strokeAttrs[.strokeWidth] = strokePercent
            NSAttributedString(string: spec.text, attributes: strokeAttrs)
                .draw(with: drawRect,
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        }

        attributed.draw(with: drawRect,
                        options: [.usesLineFragmentOrigin, .usesFontLeading])

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func nsColor(_ c: VideoTextSegment.RGBA) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
