import AVFoundation
import ImageIO
import XCTest

final class VideoOrientationMediaTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func quadrants() throws -> CVPixelBuffer {
        let pixels = try RecordingMediaFixture.pixels(width: 80, height: 48)
        let colors: [[UInt8]] = [[20, 30, 230], [20, 220, 30], [230, 40, 20], [30, 220, 230]] // BGRA
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<48 {
            for x in 0..<80 {
                let color = colors[(y < 24 ? 0 : 2) + (x < 40 ? 0 : 1)]
                let offset = CVPixelBufferGetBytesPerRow(pixels) * y + x * 4
                for component in 0..<3 { base[offset + component] = color[component] }
            }
        }
        return pixels
    }

    private func source(_ asset: AVAsset, transform: CGAffineTransform) async throws -> AVAsset {
        let composition = AVMutableComposition()
        let original = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(original.timeRange, of: original, at: .zero)
        track.preferredTransform = transform
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.outputURL = url; session.outputFileType = .mp4
        await session.export()
        XCTAssertEqual(session.status, .completed, "\(String(describing: session.error))")
        return AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    private func frame(_ asset: AVAsset, size: CGSize) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        return try generator.copyCGImage(at: CMTime(value: 1, timescale: 5), actualTime: nil)
    }

    private func pixel(_ image: CGImage, x: CGFloat, y: CGFloat) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(image.width) * x,
            y: CGFloat(image.height) * y, width: 1, height: 1)))
        var result = [UInt8](repeating: 0, count: 4)
        try result.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return result
    }

    func testRotationsAndMirroringMatchAVFoundationInBothRenderersAfterScaling() async throws {
        let pixels = try quadrants()
        let url = try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 80, height: 48),
                                                              pixelsForFrame: { _ in pixels })
        let raw = AVAsset(url: url)
        let transforms: [CGAffineTransform] = [
            .identity,
            .init(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0),
            .init(a: -1, b: 0, c: 0, d: -1, tx: 80, ty: 48),
            .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 80),
            .init(a: -1, b: 0, c: 0, d: 1, tx: 80, ty: 0),
            .init(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 48),
            .init(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0),
            .init(a: 0, b: -1, c: -1, d: 0, tx: 48, ty: 80),
        ]
        for transform in transforms {
            let asset = try await source(raw, transform: transform)
            let built = try VideoCompositionBuilder.build(asset: asset,
                pieces: [.init(kind: .normal, srcStart: 0, srcEnd: 2, compositionDuration: 2)], includeAudio: false)
            XCTAssertEqual(built.videoTrack.preferredTransform, transform)
            let display = try XCTUnwrap(VideoRenderGeometry.layout(sourceSize: built.videoTrack.naturalSize,
                                                                    preferredTransform: transform)).uprightSize
            let size = CGSize(width: display.width / 2, height: display.height / 2)
            let layout = try XCTUnwrap(VideoRenderGeometry.layout(sourceSize: built.videoTrack.naturalSize,
                preferredTransform: transform, renderSize: size))
            let expected = try frame(asset, size: size)
            for useCoreImage in [false, true] {
                let composition: AVMutableVideoComposition
                if useCoreImage {
                    composition = AVMutableVideoComposition()
                    composition.customVideoCompositorClass = EffectsVideoCompositor.self
                    composition.renderSize = size; composition.frameDuration = built.frameDuration
                    composition.instructions = [EffectsCompositionInstruction(
                        timeRange: CMTimeRange(start: .zero, duration: built.composition.duration),
                        videoTrackID: built.videoTrack.trackID, naturalSize: display, renderSize: size,
                        baseTransform: layout.coreImageTransform, timeMap: built.timeMap,
                        zoomSegments: [], censorSegments: [])]
                } else {
                    composition = try VideoCompositionRendering.scaleComposition(track: built.videoTrack,
                        renderSize: size, duration: built.composition.duration, frameDuration: built.frameDuration)
                }
                for backend in [0, 1, 2] {
                    let destination = directory.appendingPathComponent(UUID().uuidString + (backend == 2 ? ".gif" : ".mp4"))
                    let range = CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 5))
                    if backend == 2 {
                        try await GIFExporter.export(.init(asset: built.composition, videoTrack: built.videoTrack,
                            composition: composition, timeRange: range, outputURL: destination, sourceLease: nil))
                    } else if backend == 1 {
                        let session = try XCTUnwrap(AVAssetExportSession(asset: built.composition,
                            presetName: AVAssetExportPresetHighestQuality))
                        session.outputURL = destination; session.outputFileType = .mp4
                        session.videoComposition = composition; session.timeRange = range
                        await session.export()
                        XCTAssertEqual(session.status, .completed, "\(String(describing: session.error))")
                    } else {
                        try await VideoTranscoder.export(.init(asset: built.composition, videoTrack: built.videoTrack,
                            audioTracks: [], composition: composition, timeRange: range,
                            outputURL: destination, videoSettings: VideoEncodingSettings.outputSettings(
                                width: Int(size.width), height: Int(size.height), fps: 30, codec: .h264, quality: .high),
                            decodedSize: nil, outputTransform: .identity))
                    }
                    let actual: CGImage
                    if backend == 2 {
                        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
                        actual = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, 0, nil))
                    } else {
                        let output = AVAsset(url: destination)
                        XCTAssertEqual(output.tracks(withMediaType: .video).first?.preferredTransform, .identity)
                        actual = try frame(output, size: size)
                    }
                    XCTAssertEqual(actual.width, Int(size.width)); XCTAssertEqual(actual.height, Int(size.height))
                    for y: CGFloat in [0.25, 0.75] {
                        for x: CGFloat in [0.25, 0.75] {
                            let before = try pixel(expected, x: x, y: y), after = try pixel(actual, x: x, y: y)
                            for channel in 0..<3 {
                                XCTAssertEqual(Double(after[channel]), Double(before[channel]), accuracy: 12,
                                    "Transform \(transform), CoreImage \(useCoreImage), Backend \(backend), corner \(x),\(y)")
                            }
                        }
                    }
                }
            }
        }
    }
}
