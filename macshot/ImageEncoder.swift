import Cocoa
import UniformTypeIdentifiers
import ImageIO
import WebP

/// Shared image encoding with user-configurable format, quality, and resolution.
enum ImageEncoder {

    enum Format: String {
        case png = "png"
        case jpeg = "jpeg"
        case heic = "heic"
        case webp = "webp"
    }

    static var format: Format {
        if let raw = UserDefaults.standard.string(forKey: "imageFormat"),
           let fmt = Format(rawValue: raw) {
            return fmt
        }
        return .png
    }

    /// Lossy quality 0.0–1.0 (used for JPEG, HEIC, and WebP)
    static var quality: CGFloat {
        if let q = UserDefaults.standard.object(forKey: "imageQuality") as? Double {
            return CGFloat(max(0.1, min(1.0, q)))
        }
        return 0.85
    }

    /// Whether to downscale Retina (2x) screenshots to standard (1x) resolution.
    static var downscaleRetina: Bool {
        UserDefaults.standard.bool(forKey: "downscaleRetina")
    }

    /// Whether to embed an sRGB ICC color profile in saved images.
    static var embedColorProfile: Bool {
        let val = UserDefaults.standard.object(forKey: "embedColorProfile") as? Bool
        return val ?? true  // on by default
    }

    static var fileExtension: String {
        switch format {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }

    static var utType: UTType {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .webp: return .webP
        }
    }

    // MARK: - Shared bitmap creation

    /// Create a bitmap representation from an NSImage, optionally downscaling from Retina.
    /// This is the single conversion point — all encode paths go through here.
    private static func makeBitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        if downscaleRetina {
            let logicalW = Int(image.size.width)
            let logicalH = Int(image.size.height)
            let pixelW = bitmap.pixelsWide
            let pixelH = bitmap.pixelsHigh

            if pixelW > logicalW && pixelH > logicalH {
                guard let cgImage = bitmap.cgImage else { return bitmap }
                let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                guard let ctx = CGContext(
                    data: nil,
                    width: logicalW, height: logicalH,
                    bitsPerComponent: 8,
                    bytesPerRow: logicalW * 4,
                    space: cs,
                    bitmapInfo: bitmapInfo
                ) else { return bitmap }
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: logicalW, height: logicalH))
                guard let downscaled = ctx.makeImage() else { return bitmap }
                return NSBitmapImageRep(cgImage: downscaled)
            }
        }

        return bitmap
    }

    // MARK: - Encoding

    /// Encode an NSImage to Data in the configured format.
    static func encode(_ image: NSImage) -> Data? {
        guard let bitmap = makeBitmap(image) else { return nil }

        switch format {
        case .png:
            return encodePNG(bitmap: bitmap)
        case .jpeg:
            return encodeJPEG(bitmap: bitmap, quality: quality)
        case .heic:
            return encodeHEIC(bitmap: bitmap, quality: quality)
        case .webp:
            return encodeWebP(bitmap: bitmap, quality: quality)
        }
    }

    /// Encode PNG, optionally embedding sRGB profile via CGImageDestination.
    private static func encodePNG(bitmap: NSBitmapImageRep) -> Data? {
        if embedColorProfile, let cgImage = bitmap.cgImage {
            return encodeWithCGImageDestination(cgImage: cgImage, type: "public.png", lossyQuality: nil)
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Encode JPEG, optionally embedding sRGB profile via CGImageDestination.
    private static func encodeJPEG(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        if embedColorProfile, let cgImage = bitmap.cgImage {
            return encodeWithCGImageDestination(cgImage: cgImage, type: "public.jpeg", lossyQuality: quality)
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Encode HEIC via CGImageDestination (NSBitmapImageRep doesn't support HEIC).
    private static func encodeHEIC(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard let cgImage = bitmap.cgImage else { return nil }
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.heic", lossyQuality: quality)
    }

    /// Encode WebP via Swift-WebP (libwebp).
    private static func encodeWebP(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard let cgImage = bitmap.cgImage else { return nil }
        let encoder = WebPEncoder()
        let config = WebPEncoderConfig.preset(.picture, quality: Float(quality * 100))
        return try? encoder.encode(RGBA: cgImage, config: config)
    }

    /// Generic CGImageDestination encoder — handles sRGB profile embedding.
    private static func encodeWithCGImageDestination(cgImage: CGImage, type: String, lossyQuality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }

        var properties: [String: Any] = [:]
        if let q = lossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = q
        }

        // Embed sRGB color profile by converting the image's color space
        var imageToEncode = cgImage
        if embedColorProfile, let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
            if let profiled = cgImage.copy(colorSpace: sRGB) {
                imageToEncode = profiled
            }
        }

        CGImageDestinationAddImage(dest, imageToEncode, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: - Clipboard

    /// Copy image to pasteboard in the configured format.
    /// Uses a single bitmap conversion to avoid redundant encoding.
    static func copyToClipboard(_ image: NSImage) {
        guard let bitmap = makeBitmap(image) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch format {
        case .png:
            if let data = encodePNG(bitmap: bitmap) {
                pasteboard.setData(data, forType: .png)
            }
        case .jpeg:
            if let data = encodeJPEG(bitmap: bitmap, quality: quality) {
                pasteboard.setData(data, forType: .init("public.jpeg"))
            }
        case .heic:
            if let data = encodeHEIC(bitmap: bitmap, quality: quality) {
                pasteboard.setData(data, forType: .init("public.heic"))
            }
            // Also include PNG for apps that don't understand HEIC
            if let pngFallback = bitmap.representation(using: .png, properties: [:]) {
                pasteboard.setData(pngFallback, forType: .png)
            }
        case .webp:
            if let data = encodeWebP(bitmap: bitmap, quality: quality) {
                pasteboard.setData(data, forType: .init("org.webmproject.webp"))
            }
            // Also include PNG for apps that don't understand WebP
            if let pngFallback = bitmap.representation(using: .png, properties: [:]) {
                pasteboard.setData(pngFallback, forType: .png)
            }
        }
    }
}
