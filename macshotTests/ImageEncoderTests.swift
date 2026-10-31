import Cocoa
import UniformTypeIdentifiers
import XCTest

/// Encoding is the last step before a capture reaches the user's disk or
/// clipboard, so a silent failure here loses the screenshot itself.
final class ImageEncoderTests: XCTestCase {

    private func encode(format: ImageEncoder.Format, quality: Double? = nil,
                        downscale: Bool = false, image: NSImage) throws -> Data {
        var defaults: [String: Any?] = [
            "imageFormat": format.rawValue,
            "downscaleRetina": downscale,
        ]
        defaults["imageQuality"] = quality
        var data: Data?
        withDefaults(defaults) {
            data = ImageEncoder.encode(image)
        }
        return try XCTUnwrap(data, "\(format) produced no data")
    }

    // MARK: - Every format encodes something a decoder accepts

    func testEveryAvailableFormatProducesADecodableImage() throws {
        let source = ImageProbe.quadrantImage(width: 64, height: 48)
        for format in ImageEncoder.availableFormats {
            let data = try encode(format: format, image: source)
            XCTAssertFalse(data.isEmpty, "\(format) encoded to an empty file")

            let decoded = try XCTUnwrap(NSImage(data: data), "\(format) produced data macOS can't read back")
            let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: decoded))
            XCTAssertEqual(bitmap.pixelsWide, 64, "\(format) changed the width")
            XCTAssertEqual(bitmap.pixelsHigh, 48, "\(format) changed the height")
        }
    }

    func testUnavailableFormatsAreNeverOffered() {
        for format in ImageEncoder.Format.allCases where !ImageEncoder.availableFormats.contains(format) {
            XCTAssertFalse(ImageEncoder.isFormatAvailable(format))
        }
        XCTAssertTrue(ImageEncoder.availableFormats.contains(.png), "PNG must always be available")
    }

    func testFormatFallsBackToPNGForAnUnknownSetting() {
        withDefaults(["imageFormat": "tga-from-the-future"]) {
            XCTAssertEqual(ImageEncoder.format, .png)
            XCTAssertEqual(ImageEncoder.fileExtension, "png")
        }
    }

    func testFileExtensionAndTypeMatchTheSelectedFormat() {
        let expected: [ImageEncoder.Format: (String, UTType)] = [
            .png: ("png", .png),
            .jpeg: ("jpg", .jpeg),
            .heic: ("heic", .heic),
            .webp: ("webp", .webP),
        ]
        for (format, (ext, type)) in expected {
            withDefaults(["imageFormat": format.rawValue]) {
                XCTAssertEqual(ImageEncoder.fileExtension, ext)
                XCTAssertEqual(ImageEncoder.utType, type)
            }
        }
    }

    func testOnlyLossyFormatsExposeAQualitySlider() {
        XCTAssertFalse(ImageEncoder.Format.png.hasQuality, "PNG is lossless — showing a quality slider would be a lie")
        for format in ImageEncoder.Format.allCases where format != .png {
            XCTAssertTrue(format.hasQuality, "\(format) is a lossy codec and needs a quality control")
        }
    }

    // MARK: - PNG is exact

    func testPNGPreservesPixelsExactly() throws {
        let source = ImageProbe.quadrantImage(width: 40, height: 40)
        let data = try encode(format: .png, image: source)
        let decoded = try XCTUnwrap(NSImage(data: data))

        // Probe coordinates count from the top: red is the bottom-left
        // quadrant, white the top-right one.
        let red = try XCTUnwrap(ImageProbe.pixelColor(decoded, x: 5, y: 35))
        XCTAssertEqual(red.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(red.greenComponent, 0, accuracy: 0.01)

        let white = try XCTUnwrap(ImageProbe.pixelColor(decoded, x: 35, y: 5))
        XCTAssertEqual(white.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(white.blueComponent, 1, accuracy: 0.01)
    }

    func testPNGIgnoresTheQualitySetting() throws {
        let source = ImageProbe.quadrantImage()
        let low = try XCTUnwrap(NSImage(data: try encode(format: .png, quality: 0.1, image: source)))
        let high = try XCTUnwrap(NSImage(data: try encode(format: .png, quality: 1.0, image: source)))
        // Compare pixels rather than byte counts: PNG is lossless, so the
        // quality slider must not change what comes back, while file size can
        // legitimately differ by embedded metadata.
        XCTAssertEqual(FieldDescriber.describe(low), FieldDescriber.describe(high),
                       "PNG is lossless — quality must not change the image")
    }

    // MARK: - Quality

    func testLowerQualityMakesSmallerJPEGs() throws {
        // A photo-ish gradient, since flat colors compress the same at any quality.
        let source = gradientImage(width: 120, height: 120)
        let low = try encode(format: .jpeg, quality: 0.1, image: source)
        let high = try encode(format: .jpeg, quality: 1.0, image: source)
        XCTAssertLessThan(low.count, high.count, "the quality slider has to actually change the file size")
    }

    func testQualityIsClampedToAUsableRange() {
        withDefaults(["imageQuality": 5.0]) { XCTAssertEqual(ImageEncoder.quality, 1.0) }
        withDefaults(["imageQuality": -2.0]) { XCTAssertEqual(ImageEncoder.quality, 0.1) }
        withDefaults(["imageQuality": nil]) { XCTAssertEqual(ImageEncoder.quality, 0.85) }
        withDefaults(["imageQuality": Double.nan]) { XCTAssertEqual(ImageEncoder.quality, 0.85) }
    }

    func testPreparedImageOwnsPixelsFormatAndResolutionBeforeBackgroundEncoding() async throws {
        let image = retinaImage(logicalWidth: 20, logicalHeight: 15, scale: 2)
        var prepared: ImageEncoder.PreparedImage?
        try withDefaults(["imageFormat": "png", "imageQuality": 0.2, "downscaleRetina": true]) {
            prepared = try ImageEncoder.PreparedImage(image)
        }
        // Simulate the editor changing while a save panel/worker is pending.
        for representation in image.representations { image.removeRepresentation(representation) }
        image.size = NSSize(width: 5, height: 5)
        let replacement = ImageProbe.solidImage(width: 5, height: 5)
        for representation in replacement.representations { image.addRepresentation(representation) }
        let request = try XCTUnwrap(prepared)
        let data = try await MediaExportIO.perform { try XCTUnwrap(request.encode()) }
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let decoded = try XCTUnwrap(NSImage(data: data))
        let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: decoded))
        XCTAssertEqual(bitmap.pixelsWide, 20)
        XCTAssertEqual(bitmap.pixelsHigh, 15)
        let red = try XCTUnwrap(ImageProbe.pixelColor(decoded, x: 2, y: 12))
        XCTAssertEqual(red.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(red.greenComponent, 0, accuracy: 0.01)
    }

    func testEveryAvailableFormatCanEncodePreparedPixelsOnAWorker() async throws {
        let source = ImageProbe.quadrantImage(width: 32, height: 24)
        for format in ImageEncoder.availableFormats {
            var prepared: ImageEncoder.PreparedImage?
            try withDefaults(["imageFormat": format.rawValue]) { prepared = try ImageEncoder.PreparedImage(source) }
            let request = try XCTUnwrap(prepared)
            let data = try await MediaExportIO.perform { try XCTUnwrap(request.encode()) }
            let decoded = try XCTUnwrap(NSImage(data: data), "Worker encoding failed for \(format)")
            XCTAssertEqual(try XCTUnwrap(ImageProbe.bitmap(from: decoded)).pixelsWide, 32)
        }
    }

    // MARK: - Clipboard flavors (#309, #373, #393)

    private func clipboardTypes(format: ImageEncoder.Format, optIn: Bool) throws -> [NSPasteboard.PasteboardType] {
        var prepared: ImageEncoder.PreparedImage?
        try withDefaults(["imageFormat": format.rawValue]) {
            prepared = try ImageEncoder.PreparedImage(ImageProbe.quadrantImage(width: 16, height: 12))
        }
        let representations = ImageEncoder.clipboardRepresentations(for: try XCTUnwrap(prepared), includeConfiguredFormat: optIn)
        for representation in representations {
            XCTAssertNotNil(NSImage(data: representation.data), "\(representation.type.rawValue) must decode")
        }
        return representations.map(\.type)
    }

    func testClipboardDefaultsToPNGAndTIFFOnlyForEveryFormat() throws {
        for format in ImageEncoder.availableFormats {
            XCTAssertEqual(try clipboardTypes(format: format, optIn: false), [.png, .tiff], "\(format)")
        }
    }

    func testClipboardOptInPutsConfiguredFormatFirstAndKeepsPNGAndTIFF() throws {
        for format in ImageEncoder.availableFormats where format != .png {
            let expected = NSPasteboard.PasteboardType(format.utType.identifier)
            XCTAssertEqual(try clipboardTypes(format: format, optIn: true), [expected, .png, .tiff], "\(format)")
        }
        XCTAssertEqual(try clipboardTypes(format: .png, optIn: true), [.png, .tiff], "PNG is never listed twice")
    }

    func testClipboardWriteKeepsFlavorOrderAndDataWithoutAFileURL() throws {
        var prepared: ImageEncoder.PreparedImage?
        try withDefaults(["imageFormat": "jpeg"]) {
            prepared = try ImageEncoder.PreparedImage(ImageProbe.quadrantImage(width: 16, height: 12))
        }
        let representations = ImageEncoder.clipboardRepresentations(for: try XCTUnwrap(prepared), includeConfiguredFormat: true)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macshot.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("stale", forType: .string)
        let changeCount = pasteboard.changeCount
        ImageEncoder.writeImagePasteboard(pasteboard, representations: representations)
        XCTAssertEqual(pasteboard.changeCount, changeCount + 1, "one copy is one clipboard change (#483)")
        XCTAssertNil(pasteboard.string(forType: .string), "the previous contents are cleared")
        // AppKit adds legacy aliases (e.g. "Apple PNG pasteboard type"); the UTIs keep our order.
        let utis = (pasteboard.types ?? []).filter { $0.rawValue.hasPrefix("public.") }
        XCTAssertEqual(utis, [NSPasteboard.PasteboardType("public.jpeg"), .png, .tiff])
        XCTAssertNil(pasteboard.string(forType: .fileURL), "a sandbox file URL breaks Teams and RDP paste")
        for representation in representations {
            XCTAssertEqual(pasteboard.data(forType: representation.type), representation.data)
        }
    }

    func testWebPKeepsSemiTransparentColorsInsteadOfDarkeningThem() throws {
        let translucent = ImageProbe.solidImage(width: 16, height: 16,
                                                color: CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.5))
        let png = try XCTUnwrap(NSImage(data: try encode(format: .png, image: translucent)))
        let webp = try XCTUnwrap(NSImage(data: try encode(format: .webp, quality: 1.0, image: translucent)))
        let expected = try XCTUnwrap(ImageProbe.pixelColor(png, x: 8, y: 8)?.usingColorSpace(.sRGB))
        let actual = try XCTUnwrap(ImageProbe.pixelColor(webp, x: 8, y: 8)?.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.02)
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.05, "premultiplied bytes darken WebP edges")
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.05)
    }

    func testWebPRefusesImagesBeyondItsSizeLimitInsteadOfAllocating() {
        let tall = ImageProbe.solidImage(width: 2, height: ImageEncoder.webPMaximumDimension + 1)
        withDefaults(["imageFormat": "webp"]) { XCTAssertNil(ImageEncoder.encode(tall)) }
        let edge = ImageProbe.solidImage(width: 2, height: ImageEncoder.webPMaximumDimension)
        withDefaults(["imageFormat": "webp"]) { XCTAssertNotNil(ImageEncoder.encode(edge)) }
    }

    func testUnpremultiplyRestoresStraightAlpha() {
        var pixels: [UInt8] = [128, 64, 0, 128,  10, 20, 30, 255,  0, 0, 0, 0,  255, 255, 255, 255]
        pixels.withUnsafeMutableBufferPointer { ImageEncoder.unpremultiplyRGBA($0) }
        XCTAssertEqual(pixels, [255, 128, 0, 128,  10, 20, 30, 255,  0, 0, 0, 0,  255, 255, 255, 255])
    }

    // MARK: - Retina downscaling

    func testRetinaDownscaleHalvesATwoTimesCapture() throws {
        let retina = retinaImage(logicalWidth: 50, logicalHeight: 40, scale: 2)
        let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: retina))
        XCTAssertEqual(bitmap.pixelsWide, 100, "fixture should be 2x")

        let data = try encode(format: .png, downscale: true, image: retina)
        let decoded = try XCTUnwrap(ImageProbe.bitmap(from: try XCTUnwrap(NSImage(data: data))))
        XCTAssertEqual(decoded.pixelsWide, 50)
        XCTAssertEqual(decoded.pixelsHigh, 40)
    }

    func testRetinaDownscaleLeavesANonRetinaCaptureAlone() throws {
        let plain = ImageProbe.quadrantImage(width: 30, height: 20)
        let data = try encode(format: .png, downscale: true, image: plain)
        let decoded = try XCTUnwrap(ImageProbe.bitmap(from: try XCTUnwrap(NSImage(data: data))))
        XCTAssertEqual(decoded.pixelsWide, 30, "a 1x capture must not be shrunk further")
        XCTAssertEqual(decoded.pixelsHigh, 20)
    }

    func testDownscaleOffKeepsEveryPixel() throws {
        let retina = retinaImage(logicalWidth: 50, logicalHeight: 40, scale: 2)
        let data = try encode(format: .png, downscale: false, image: retina)
        let decoded = try XCTUnwrap(ImageProbe.bitmap(from: try XCTUnwrap(NSImage(data: data))))
        XCTAssertEqual(decoded.pixelsWide, 100)
    }

    // MARK: - Degenerate input

    func testEmptyImageDoesNotCrashTheEncoder() {
        let empty = NSImage(size: .zero)
        withDefaults(["imageFormat": "png"]) {
            // Either nil or empty data is acceptable; a crash is not.
            _ = ImageEncoder.encode(empty)
        }
    }

    func testOnePixelImageEncodes() throws {
        let dot = ImageProbe.solidImage(width: 1, height: 1, color: CGColor(gray: 0, alpha: 1))
        let data = try encode(format: .png, image: dot)
        let decoded = try XCTUnwrap(ImageProbe.bitmap(from: try XCTUnwrap(NSImage(data: data))))
        XCTAssertEqual(decoded.pixelsWide, 1)
        XCTAssertEqual(decoded.pixelsHigh, 1)
    }

    func testTransparencySurvivesPNGAndIsFlattenedByJPEG() throws {
        let transparent = ImageProbe.transparentImage(width: 10, height: 10)

        let png = try XCTUnwrap(NSImage(data: try encode(format: .png, image: transparent)))
        let pngPixel = try XCTUnwrap(ImageProbe.pixelColor(png, x: 5, y: 5))
        XCTAssertEqual(pngPixel.alphaComponent, 0, accuracy: 0.01, "PNG must keep the alpha channel")

        let jpeg = try XCTUnwrap(NSImage(data: try encode(format: .jpeg, image: transparent)))
        let jpegPixel = try XCTUnwrap(ImageProbe.pixelColor(jpeg, x: 5, y: 5))
        XCTAssertEqual(jpegPixel.alphaComponent, 1, accuracy: 0.01, "JPEG has no alpha, so it flattens")
    }

    // MARK: - Fixtures

    private func gradientImage(width: Int, height: Int) -> NSImage {
        ImageProbe.makeImage(width: width, height: height) { context in
            for x in 0..<width {
                for y in stride(from: 0, to: height, by: 4) {
                    context.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(width),
                                                 green: CGFloat(y) / CGFloat(height),
                                                 blue: CGFloat((x * y) % 255) / 255,
                                                 alpha: 1))
                    context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 4))
                }
            }
        }
    }

    /// An image whose pixel buffer is `scale`x its logical size — what a capture
    /// from a Retina display looks like.
    private func retinaImage(logicalWidth: Int, logicalHeight: Int, scale: Int) -> NSImage {
        let pixels = ImageProbe.quadrantImage(width: logicalWidth * scale, height: logicalHeight * scale)
        guard let cgImage = pixels.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return pixels }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: logicalWidth, height: logicalHeight))
        return image
    }
}
