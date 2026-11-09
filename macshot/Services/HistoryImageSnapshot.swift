import AppKit
import ImageIO

/// AppKit images and live annotations never cross the history writer queue.
/// Each image is rasterized into separately owned pixels before enqueueing.
struct HistoryImageSnapshot: Sendable {
    /// ImageIO downsamples legacy originals without materializing their full
    /// decoded bitmap. AppKit images are constructed by the main-thread caller.
    nonisolated static func preview(at urls: [URL], maximumPixels: Int = 480) -> CGImage? {
        guard maximumPixels > 0 else { return nil }
        for url in urls {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                  ] as CFDictionary) else { continue }
            return image
        }
        return nil
    }

    struct Image: Sendable {
        nonisolated let pixels: CGImage
        let pointSize: CGSize

        @MainActor init(_ image: NSImage) throws {
            let size = image.size
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            pixels = try Self.render(source, width: source.width, height: source.height)
            pointSize = size
        }

        nonisolated static func render(_ source: CGImage, width: Int, height: Int) throws -> CGImage {
            let (stride, overflow) = width.multipliedReportingOverflow(by: 4)
            let colorSpace = source.colorSpace?.model == .rgb ? source.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
            guard width > 0, height > 0, !overflow, let colorSpace,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: stride, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CocoaError(.fileWriteUnknown)
            }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let result = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            return result
        }

        nonisolated func writePNG(to url: URL, maximumPointDimension: Int? = nil) throws {
            let output: CGImage
            if let maximumPointDimension {
                // Cache enough pixels for Retina while keeping menu icons at
                // their intended point size. Never enlarge the source bitmap.
                let scale = min(1, Double(maximumPointDimension) * 2 / Double(max(pixels.width, pixels.height)))
                output = try Self.render(pixels, width: max(1, Int((Double(pixels.width) * scale).rounded())),
                    height: max(1, Int((Double(pixels.height) * scale).rounded())))
            } else { output = pixels }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let properties: [CFString: Any] = maximumPointDimension == nil ? [
                kCGImagePropertyDPIWidth: Double(pixels.width) / pointSize.width * 72,
                kCGImagePropertyDPIHeight: Double(pixels.height) / pointSize.height * 72,
            ] : [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
            CGImageDestinationAddImage(destination, output, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    let composited: Image
    let raw: Image?
    let annotations: Data?
    let editState: Data?
    nonisolated var isEditable: Bool { raw != nil && (annotations != nil || editState != nil) }
    /// Account for retained pixels and serialized sidecars, not compressed file
    /// sizes. Saturation keeps malformed dimensions from wrapping the budget.
    nonisolated var retainedBytes: Int {
        var total = 0
        for image in [composited, raw].compactMap({ $0 }) {
            let (bytes, overflow) = image.pixels.bytesPerRow.multipliedReportingOverflow(by: image.pixels.height)
            let (sum, sumOverflow) = total.addingReportingOverflow(bytes)
            if overflow || sumOverflow { return Int.max }
            total = sum
        }
        for data in [annotations, editState].compactMap({ $0 }) {
            let (sum, overflow) = total.addingReportingOverflow(data.count)
            if overflow { return Int.max }
            total = sum
        }
        return total
    }

    @MainActor init(image: NSImage, rawImage: NSImage?, annotations: [Annotation]?, editState: CaptureEditState?) throws {
        composited = try Image(image)
        let needsAnnotations = !(annotations?.isEmpty ?? true)
        let needsEditState = editState?.hasPostProcessing == true
        if needsAnnotations || needsEditState {
            guard let rawImage else { throw CocoaError(.fileWriteUnknown) }
            raw = try Image(rawImage)
        } else { raw = nil }
        if needsAnnotations {
            guard let encoded = AnnotationSerializer.encode(annotations!) else { throw CocoaError(.fileWriteUnknown) }
            self.annotations = encoded
        } else { self.annotations = nil }
        self.editState = needsEditState ? try JSONEncoder().encode(editState!) : nil
    }
}
