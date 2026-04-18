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

    /// Dedicated subfolder for the clipboard-paste temp file. Isolated so
    /// we can sweep it without worrying about matching user-configured
    /// filename templates. Created lazily by `clipboardTmpDirectory`.
    private static let clipboardTmpSubfolder = "macshot-clipboard"

    /// Path to the clipboard temp subfolder. Always exists after first
    /// access — created on demand with `createDirectory(withIntermediateDirectories: true)`.
    /// Also adopts any file already in the folder as the "current" one so
    /// a clean restart (no crash, but app did quit) doesn't end up with
    /// two clipboard files after the next copy: the *one* leftover is
    /// treated as our previous file and replaced on next write.
    static let clipboardTmpDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(clipboardTmpSubfolder)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Adopt any leftover file so the next copy replaces it. If the
        // folder has several files (shouldn't happen, but defensively),
        // pick the newest by modification date and delete the rest.
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), !contents.isEmpty {
            let sorted = contents.sorted { lhs, rhs in
                let ld = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rd = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return ld > rd
            }
            clipboardLock.lock()
            currentClipboardFileURL = sorted.first
            clipboardLock.unlock()
            // Delete every file *except* the adopted one.
            for stale in sorted.dropFirst() {
                try? FileManager.default.removeItem(at: stale)
            }
        }
        return dir
    }()

    /// Lock protecting `currentClipboardFileURL` — writes happen on a
    /// background queue while `copyToClipboard` gets called from the main
    /// queue, so the pointer needs synchronization.
    private static let clipboardLock = NSLock()
    private static var currentClipboardFileURL: URL?

    /// Copy image to pasteboard as PNG.
    /// Explicitly sets PNG data so receiving apps (browsers, editors) get
    /// a lossless PNG instead of the TIFF that NSImage.writeObjects provides.
    /// Also writes a temp file so Finder paste (Cmd+V in a folder) works
    /// and the pasted file has a nice date-stamped filename instead of
    /// something like `macshot-clipboard.png`.
    ///
    /// Disk hygiene:
    ///   - At most ONE clipboard temp file exists at any time. The
    ///     previous copy's file is deleted just before the new one is
    ///     written — the pasteboard's file-URL reference is updated in
    ///     lockstep so no paste ever points at a deleted file.
    ///   - The file lives in `tmp/macshot-clipboard/` so launch-time
    ///     cleanup can wipe the whole folder if we miss the delete for
    ///     any reason (crash, force-quit) without needing to match
    ///     user-controlled filename patterns.
    static func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bitmap = makeBitmap(image),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

            // Compute the new file path with a date-stamped filename so
            // Finder pastes land as a nicely named file. A counter suffix
            // guards the very unlikely case where two copies in the same
            // second produce the same name and we somehow haven't cleaned
            // up the previous file yet.
            let dir = clipboardTmpDirectory
            var candidate = dir.appendingPathComponent(FilenameFormatter.defaultImageFilename())
            var counter = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                let base = FilenameFormatter.defaultImageFilename()
                    .replacingOccurrences(of: ".\(ImageEncoder.fileExtension)", with: "")
                candidate = dir.appendingPathComponent("\(base) (\(counter)).\(ImageEncoder.fileExtension)")
                counter += 1
                if counter > 1000 { break }  // sanity
            }
            let newURL = candidate

            // Write the new file first (atomic → no partial reads by any
            // in-flight Finder paste); only delete the previous one once
            // the write succeeded so there's never a window where no file
            // is on disk yet the pasteboard points at one.
            let writeOK = (try? pngData.write(to: newURL, options: .atomic)) != nil

            clipboardLock.lock()
            let oldURL = currentClipboardFileURL
            currentClipboardFileURL = writeOK ? newURL : oldURL
            clipboardLock.unlock()

            if writeOK, let old = oldURL, old != newURL {
                // Best-effort: any failure here is harmless — the launch
                // sweep is a backstop.
                try? FileManager.default.removeItem(at: old)
            }

            let fileURL = writeOK ? newURL : nil
            DispatchQueue.main.async {
                var types: [NSPasteboard.PasteboardType] = [.png]
                if fileURL != nil { types.append(.fileURL) }
                pasteboard.declareTypes(types, owner: nil)
                pasteboard.setData(pngData, forType: .png)
                if let url = fileURL {
                    pasteboard.setString(url.absoluteString, forType: .fileURL)
                }
            }
        }
    }
}
