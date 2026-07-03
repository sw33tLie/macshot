import Cocoa
import UniformTypeIdentifiers
import ImageIO
import WebP

/// Shared image encoding with user-configurable format, quality, and resolution.
enum ImageEncoder {

    enum Format: String, CaseIterable {
        case png = "png"
        case jpeg = "jpeg"
        case heic = "heic"
        case webp = "webp"
        case avif = "avif"

        nonisolated var hasQuality: Bool {
            switch self {
            case .png: return false
            case .jpeg, .heic, .webp, .avif: return true
            }
        }

        nonisolated var displayName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .heic: return "HEIC"
            case .webp: return "WebP"
            case .avif: return "AVIF"
            }
        }
    }

    static var format: Format {
        if let raw = UserDefaults.standard.string(forKey: "imageFormat"),
           let fmt = Format(rawValue: raw),
           isFormatAvailable(fmt) {
            return fmt
        }
        return .png
    }

    /// Lossy quality 0.0–1.0 (used for JPEG, HEIC, WebP, and AVIF)
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

    static var fileExtension: String {
        switch format {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        case .avif: return "avif"
        }
    }

    static var utType: UTType {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .webp: return .webP
        case .avif: return UTType("public.avif") ?? .image
        }
    }

    nonisolated static var availableFormats: [Format] {
        Format.allCases.filter { isFormatAvailable($0) }
    }

    nonisolated static func isFormatAvailable(_ format: Format) -> Bool {
        switch format {
        case .png, .jpeg, .heic, .webp:
            return true
        case .avif:
            // Native ImageIO AVIF encode support is OS-provided. Keep the UI and
            // saved default gated so older supported macOS versions never expose
            // a format that cannot be written.
            guard #available(macOS 13.0, *) else { return false }
            let identifiers = CGImageDestinationCopyTypeIdentifiers() as NSArray
            return identifiers.contains("public.avif")
        }
    }

    // MARK: - Shared bitmap creation

    /// Create a bitmap representation from an NSImage, optionally downscaling from Retina.
    /// This is the single conversion point — all encode paths go through here.
    /// Uses cgImage(forProposedRect:) instead of tiffRepresentation to preserve
    /// exact pixel data regardless of the current display's backing scale factor.
    private static func makeBitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Fallback for images without a CGImage backing (e.g. PDF/EPS vectors)
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
            return bitmap
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        if downscaleRetina {
            let logicalW = Int(image.size.width)
            let logicalH = Int(image.size.height)
            let pixelW = bitmap.pixelsWide
            let pixelH = bitmap.pixelsHigh

            if pixelW > logicalW && pixelH > logicalH {
                let cs = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
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
        case .avif:
            return encodeAVIF(bitmap: bitmap, quality: quality)
        }
    }

    /// Encode PNG with native color profile embedded.
    private static func encodePNG(bitmap: NSBitmapImageRep) -> Data? {
        guard let cgImage = bitmap.cgImage else {
            return bitmap.representation(using: .png, properties: [:])
        }
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.png", lossyQuality: nil)
    }

    /// Encode JPEG with native color profile embedded.
    private static func encodeJPEG(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard let cgImage = bitmap.cgImage else {
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.jpeg", lossyQuality: quality)
    }

    /// Encode HEIC via CGImageDestination (NSBitmapImageRep doesn't support HEIC).
    private static func encodeHEIC(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard let cgImage = bitmap.cgImage else { return nil }
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.heic", lossyQuality: quality)
    }

    /// Encode AVIF via native ImageIO/CGImageDestination.
    private static func encodeAVIF(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard isFormatAvailable(.avif), let cgImage = bitmap.cgImage else { return nil }
        return encodeWithCGImageDestination(cgImage: cgImage, type: "public.avif", lossyQuality: quality)
    }

    /// Encode WebP via Swift-WebP (libwebp).
    /// Uses the CGImage RGBA path directly — the library's NSImage path has a bug
    /// (assumes RGB stride and logical size instead of pixel size).
    private static func encodeWebP(bitmap: NSBitmapImageRep, quality: CGFloat) -> Data? {
        guard let srcImage = bitmap.cgImage else { return nil }
        let w = srcImage.width
        let h = srcImage.height
        // Re-render into a known premultipliedLast RGBA context (preserving source color space)
        let cs = srcImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(srcImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rgbaImage = ctx.makeImage() else { return nil }

        let encoder = WebPEncoder()
        let config = WebPEncoderConfig.preset(.picture, quality: Float(quality * 100))
        return try? encoder.encode(RGBA: rgbaImage, config: config)
    }

    /// Generic CGImageDestination encoder — embeds the source color profile.
    /// The CGImage already carries its display's ICC profile (e.g. Display P3).
    /// CGImageDestination embeds it automatically — no pixel conversion needed.
    private static func encodeWithCGImageDestination(cgImage: CGImage, type: String, lossyQuality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else { return nil }

        var properties: [String: Any] = [:]
        if let q = lossyQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = q
        }

        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: - Clipboard

    private static let clipboardGenerationLock = NSLock()
    private static var clipboardGeneration = 0

    /// Copy image to pasteboard as PNG.
    /// Explicitly sets PNG data so receiving apps (browsers, editors) get
    /// a lossless PNG instead of the TIFF that NSImage.writeObjects provides.
    /// Also writes a retained backing file so Finder paste works and clipboard
    /// history tools do not keep references to deleted `/tmp` files.
    static func copyToClipboard(_ image: NSImage, sourceFileURL: URL? = nil) {
        let pasteboard = NSPasteboard.general
        let generation = beginClipboardCopy()

        DispatchQueue.global(qos: .userInitiated).async {
            let validSourceURL = reusableSourceURL(sourceFileURL)
            guard let bitmap = makeBitmap(image),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                if let validSourceURL {
                    DispatchQueue.main.async {
                        guard isCurrentClipboardCopy(generation) else { return }
                        pasteboard.clearContents()
                        pasteboard.writeObjects([validSourceURL as NSURL])
                    }
                }
                return
            }

            let backingURL = validSourceURL ?? ClipboardBackingStore.writeImageData(pngData)
            let tiffData = bitmap.representation(using: .tiff, properties: [:])

            DispatchQueue.main.async {
                guard isCurrentClipboardCopy(generation) else { return }
                writeImagePasteboard(
                    pasteboard,
                    backingURL: backingURL,
                    pngData: pngData,
                    tiffData: tiffData
                )
            }
        }
    }

    private static func beginClipboardCopy() -> Int {
        clipboardGenerationLock.lock()
        defer { clipboardGenerationLock.unlock() }
        clipboardGeneration += 1
        return clipboardGeneration
    }

    private static func isCurrentClipboardCopy(_ generation: Int) -> Bool {
        clipboardGenerationLock.lock()
        defer { clipboardGenerationLock.unlock() }
        return generation == clipboardGeneration
    }

    private static func reusableSourceURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard !downscaleRetina else { return nil }
        guard url.pathExtension.lowercased() == "png" else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func writeImagePasteboard(
        _ pasteboard: NSPasteboard,
        backingURL: URL?,
        pngData: Data,
        tiffData: Data?
    ) {
        pasteboard.clearContents()

        if let backingURL, pasteboard.writeObjects([backingURL as NSURL]) {
            var extraTypes: [NSPasteboard.PasteboardType] = [.png]
            if tiffData != nil {
                extraTypes.append(.tiff)
            }
            pasteboard.addTypes(extraTypes, owner: nil)
            pasteboard.setData(pngData, forType: .png)
            if let tiffData {
                pasteboard.setData(tiffData, forType: .tiff)
            }
            return
        }

        var types: [NSPasteboard.PasteboardType] = [.png]
        if tiffData != nil {
            types.append(.tiff)
        }
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setData(pngData, forType: .png)
        if let tiffData {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }
}
