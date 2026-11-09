import Cocoa
import ImageIO

/// Limits at the editable-history boundary. The flattened capture remains
/// available if a sidecar cannot be restored. These are allocation limits,
/// independent of the smaller ranges offered by the toolbar controls.
enum SavedCaptureValidation {
    static let maximumImagePixels = 128 * 1024 * 1024
    static let maximumImageBytes = 128 * 1024 * 1024
    static let maximumRTFBytes = 4 * 1024 * 1024
    // Far beyond the supported screen/editor sizes, while keeping distances,
    // tessellation counts and pixel conversions in the renderer representable.
    static let maximumCoordinate: CGFloat = 1_000_000

    static func bounded<T: BinaryFloatingPoint>(_ value: T, _ range: ClosedRange<T>, fallback: T) -> T {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    static func image(_ data: Data, maximumPixels: Int = maximumImagePixels) -> NSImage? {
        guard maximumPixels > 0, data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w > 0, h > 0,
              w * h <= Double(maximumPixels),
              let pixels = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        func points(_ pixels: Double, dpi: Any?) -> Double {
            guard let dpi = (dpi as? NSNumber)?.doubleValue, dpi.isFinite, dpi > 0 else { return pixels }
            let size = pixels * 72 / dpi
            return size.isFinite && size > 0 && size <= Double(maximumImagePixels) ? size : pixels
        }
        return NSImage(cgImage: pixels, size: NSSize(
            width: points(w, dpi: properties[kCGImagePropertyDPIWidth]),
            height: points(h, dpi: properties[kCGImagePropertyDPIHeight])))
    }

    static func point(_ values: [CGFloat]) -> NSPoint? {
        guard values.count == 2, values.allSatisfy({ $0.isFinite && abs($0) <= maximumCoordinate }) else { return nil }
        return NSPoint(x: values[0], y: values[1])
    }

    static func rect(_ values: [CGFloat]) -> NSRect? {
        guard values.count == 4,
              values.allSatisfy({ $0.isFinite && abs($0) <= maximumCoordinate }), values[2] >= 0, values[3] >= 0,
              (values[0] + values[2]).isFinite, (values[1] + values[3]).isFinite else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    static func canRenderText(size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width * size.height * 4 <= CGFloat(maximumImagePixels)
    }
}
