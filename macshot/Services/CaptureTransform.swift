import AppKit

/// Rotates or flips a finished capture while keeping timestamp burn-in upright.
@MainActor
enum CaptureTransform {
    static func apply(
        _ transform: ImageContextTransform,
        to image: NSImage,
        annotationData: CaptureAnnotationData?
    ) -> (image: NSImage, annotationData: CaptureAnnotationData?)? {
        guard let data = annotationData,
              let editState = data.editState,
              let capturedAt = editState.capturedAt
        else {
            guard let transformed = image.macshotTransformed(transform) else { return nil }
            return (transformed, nil)
        }

        guard let unstamped = compose(data, editState: editState),
              let transformed = transformedBitmap(
                unstamped,
                transform,
                scale: pixelScale(of: data.rawImage))
        else { return nil }

        return (
            TimestampOverlay.stamp(transformed, capturedAt: capturedAt),
            .timestampOnly(rawImage: transformed, capturedAt: capturedAt)
        )
    }

    /// Recreates the editor export immediately before timestamp burn-in.
    private static func compose(_ data: CaptureAnnotationData, editState: CaptureEditState) -> NSImage? {
        var result = data.rawImage
        if !data.annotations.isEmpty {
            guard let composited = composite(data.annotations, onto: data.rawImage) else { return nil }
            result = composited
        }
        if editState.hasEffects {
            result = ImageEffects.apply(to: result, config: editState.effectsConfig)
        }
        if editState.beautifyEnabled {
            result = BeautifyRenderer.render(image: result, config: editState.beautifyConfig())
        }
        return result
    }

    private static func composite(_ annotations: [Annotation], onto rawImage: NSImage) -> NSImage? {
        let bounds = NSRect(origin: .zero, size: rawImage.size)
        var proposed = bounds
        guard bounds.width > 0, bounds.height > 0,
              let raw = rawImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = bitmapContext(width: raw.width, height: raw.height, colorSpace: raw.colorSpace)
        else { return nil }

        // The source annotations may still belong to an open editor.
        let prepared = annotations.map { annotation -> Annotation in
            let copy = annotation.clone()
            let needsSource = copy.tool == .loupe
                || ((copy.tool == .pixelate || copy.tool == .blur) && copy.bakedBlurNSImage == nil)
            if needsSource {
                copy.sourceImage = rawImage
                copy.sourceImageBounds = bounds
                if copy.tool == .loupe { copy.bakeLoupe() } else { copy.bakePixelate() }
            }
            return copy
        }

        context.interpolationQuality = .none
        context.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        context.scaleBy(x: CGFloat(raw.width) / bounds.width, y: CGFloat(raw.height) / bounds.height)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        Annotation.drawComposited(prepared, in: graphicsContext, highlightDimBounds: bounds)
        NSGraphicsContext.restoreGraphicsState()

        guard let composited = context.makeImage() else { return nil }
        return NSImage(cgImage: composited, size: bounds.size)
    }

    private static func transformedBitmap(
        _ image: NSImage,
        _ transform: ImageContextTransform,
        scale: CGFloat
    ) -> NSImage? {
        var proposed = NSRect(origin: .zero, size: image.size)
        let transformHint = NSAffineTransform()
        transformHint.scale(by: scale)
        guard proposed.width > 0, proposed.height > 0,
              let source = image.cgImage(
                forProposedRect: &proposed,
                context: nil,
                hints: [.ctm: transformHint])
        else { return nil }

        let rotates = transform == .rotateLeft || transform == .rotateRight
        guard let context = bitmapContext(
            width: rotates ? source.height : source.width,
            height: rotates ? source.width : source.height,
            colorSpace: source.colorSpace)
        else { return nil }

        context.interpolationQuality = .none
        switch transform {
        case .rotateLeft:
            context.translateBy(x: CGFloat(source.height), y: 0)
            context.rotate(by: .pi / 2)
        case .rotateRight:
            context.translateBy(x: 0, y: CGFloat(source.width))
            context.rotate(by: -.pi / 2)
        case .flipHorizontal:
            context.translateBy(x: CGFloat(source.width), y: 0)
            context.scaleBy(x: -1, y: 1)
        case .flipVertical:
            context.translateBy(x: 0, y: CGFloat(source.height))
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))

        guard let transformed = context.makeImage() else { return nil }
        let size = rotates
            ? NSSize(width: image.size.height, height: image.size.width)
            : image.size
        return NSImage(cgImage: transformed, size: size)
    }

    private static func pixelScale(of image: NSImage) -> CGFloat {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard image.size.width > 0,
              let pixels = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return 1 }
        return CGFloat(pixels.width) / image.size.width
    }

    private static func bitmapContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let (bytesPerRow, overflow) = width.multipliedReportingOverflow(by: 4)
        let space = colorSpace?.model == .rgb ? colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard width > 0, height > 0, !overflow, let space else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
