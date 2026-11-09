import AVFoundation
import ImageIO
import XCTest

final class GIFExporterTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testRecordingHotkeyConverterUsesPointSizeAndPreservesDuration() async throws {
        let movie = try await RecordingMediaFixture.mixedMovie(in: directory,
            size: CGSize(width: 128, height: 64), frameCount: 60)
        let output = directory.appendingPathComponent("hotkey.gif")
        try await RecordingGIFConverter.convert(source: movie, to: output, fps: 15, scale: 0.5,
            cancellation: MediaExportCancellation(), progress: { _ in })
        let result = try GIFTestMedia.decode(output)
        XCTAssertEqual(result.size, CGSize(width: 64, height: 32))
        XCTAssertEqual(result.delays.reduce(0, +), 2, accuracy: 0.02)
        XCTAssertEqual(result.loopCount, 0)
    }

    private func request(_ built: VideoCompositionBuilder.Result, fps: Int = 30, custom: Bool = false,
                         censors: [VideoCensorSnapshot] = [], output: URL? = nil) throws -> GIFExporter.Request {
        let size = CGSize(width: 64, height: 64)
        let cadence = CMTime(value: 1, timescale: CMTimeScale(fps))
        let composition: AVMutableVideoComposition
        if custom {
            composition = AVMutableVideoComposition()
            composition.customVideoCompositorClass = EffectsVideoCompositor.self
            composition.renderSize = size; composition.frameDuration = cadence
            composition.instructions = [EffectsCompositionInstruction(
                timeRange: CMTimeRange(start: .zero, duration: built.composition.duration),
                videoTrackID: built.videoTrack.trackID, naturalSize: size, renderSize: size,
                baseTransform: .identity, timeMap: built.timeMap, zoomSegments: [], censorSegments: censors)]
        } else {
            composition = try VideoCompositionRendering.scaleComposition(track: built.videoTrack,
                renderSize: size, duration: built.composition.duration, frameDuration: cadence)
        }
        return GIFExporter.Request(asset: built.composition, videoTrack: built.videoTrack, composition: composition,
            timeRange: CMTimeRange(start: .zero, duration: built.composition.duration),
            outputURL: output ?? directory.appendingPathComponent(UUID().uuidString + ".gif"), sourceLease: nil)
    }

    func testCutsSpeedAndFreezeAreAppliedWithAndWithoutCustomEffects() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, pixelsForFrame: { index in
            try GIFTestMedia.pixels(color: index < 15 ? 0 : (index < 30 ? 1 : 2), width: 64, height: 64)
        })
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 2,
                                       cuts: [VideoCutSegment(startTime: 0.2, endTime: 0.4)])
        let pieces = VideoSpeeds.pieces(keptRanges: kept,
            speeds: [VideoSpeedSegment(startTime: 1, endTime: 1.4, speedFactor: 2)],
            freezes: [VideoFreezeSegment(atTime: 0.6, holdDuration: 0.4)])
        let built = try VideoCompositionBuilder.build(asset: AVAsset(url: source), pieces: pieces, includeAudio: false)
        XCTAssertFalse(built.videoTrack.segments.contains(where: \.isEmpty), "Freeze/speed scaling must not leave even a sub-frame hole")
        XCTAssertEqual(built.videoTrack.segments.count, built.timeMap.count)
        // The builder chooses a clock compatible with the source. Converting
        // its Double time map back through a fixed 1 GHz clock rounds valid
        // endpoints; compare on the composition track's actual clock instead.
        let editClock = built.videoTrack.naturalTimeScale
        for (segment, expected) in zip(built.videoTrack.segments, built.timeMap) {
            XCTAssertEqual(CMTimeCompare(segment.timeMapping.target.start,
                CMTime(seconds: expected.compStart, preferredTimescale: editClock)), 0)
            XCTAssertEqual(CMTimeCompare(segment.timeMapping.target.end,
                CMTime(seconds: expected.compEnd, preferredTimescale: editClock)), 0)
        }
        // Keep an exact rational-time check so a real gap or overlap still
        // fails, independently of the Double time map's representation.
        for (previous, next) in zip(built.videoTrack.segments, built.videoTrack.segments.dropFirst()) {
            XCTAssertEqual(CMTimeCompare(previous.timeMapping.target.end, next.timeMapping.target.start), 0)
        }
        for custom in Array(repeating: [false, true], count: 3).flatMap({ $0 }) {
            let request = try request(built, custom: custom)
            try await GIFExporter.export(request)
            let result = try GIFTestMedia.decode(request.outputURL)
            XCTAssertEqual(result.delays.reduce(0, +), 2, accuracy: 0.01)
            // Red loses .2s to the cut, green gains a .4s freeze, and blue
            // loses .2s to speed. Check every displayed frame and its duration.
            var totals = [0.0, 0.0, 0.0]
            for (color, delay) in zip(result.colors, result.delays) { totals[color] += delay }
            for (actual, expected) in zip(totals, [0.3, 0.9, 0.8]) { XCTAssertEqual(actual, expected, accuracy: 0.04) }
            XCTAssertEqual(result.colors.first, 0)
            XCTAssertEqual(result.colors.last, 2)
        }
    }

    func testSparseVariableRateSourceKeepsDurationAndFinalStaticTail() async throws {
        let url = directory.appendingPathComponent("sparse.mp4")
        let queue = DispatchQueue(label: "GIFExporterTests.writer")
        let writer = try MP4WriterSession.make(queue: queue, url: url, width: 64, height: 64, fps: 30,
                                               recordSystemAudio: false, recordMicAudio: false)
        for (color, offset) in [0.0, 0.2, 1.7].enumerated() {
            let pixels = try GIFTestMedia.pixels(color: color, width: 64, height: 64)
            let time = CMTime(seconds: 100 + offset, preferredTimescale: 60_000)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !queue.sync(execute: { writer.handleFrame(pixelBuffer: pixels, presentationTime: time) }) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        writer.requestStop(atSourceTime: CMTime(value: 104, timescale: 1))
        try await writer.finish()
        let built = try VideoCompositionBuilder.build(asset: AVAsset(url: url),
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: 4, compositionDuration: 4)], includeAudio: false)
        let request = try request(built, fps: 15)
        try await GIFExporter.export(request)
        let result = try GIFTestMedia.decode(request.outputURL)
        XCTAssertEqual(result.delays.reduce(0, +), 4, accuracy: 0.01)
        var totals = [0.0, 0.0, 0.0]
        for (color, delay) in zip(result.colors, result.delays) { totals[color] += delay }
        for (actual, expected) in zip(totals, [0.2, 1.5, 2.3]) { XCTAssertEqual(actual, expected, accuracy: 1.0 / 15 + 0.01) }
        XCTAssertLessThan(result.delays.count, 10, "A static tail should not store hundreds of identical frames")
    }

    func testTrimmedFractionalCadenceStartsWithTheCorrectSourceFrame() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, pixelsForFrame: { index in
            let pixels = try RecordingMediaFixture.pixels()
            CVPixelBufferLockBaseAddress(pixels, [])
            defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for y in 8..<56 {
                for bit in 0..<6 {
                    let value: UInt8 = index & (1 << bit) == 0 ? 0 : 255
                    for x in (8 + bit * 8)..<(16 + bit * 8) {
                        let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                        for channel in 0..<3 { bytes[offset + channel] = value }
                    }
                }
            }
            return pixels
        })
        let built = try VideoCompositionBuilder.build(asset: AVAsset(url: source),
            pieces: [.init(kind: .normal, srcStart: 0.5, srcEnd: 1.5, compositionDuration: 1)], includeAudio: false)
        let request = try request(built, fps: 15)
        try await GIFExporter.export(request)
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(request.outputURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 15)
        for index in 0..<15 {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, index, nil))
            var id = 0
            for bit in 0..<6 {
                let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 12 + bit * 8, y: 32, width: 1, height: 1)))
                let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if context.data!.assumingMemoryBound(to: UInt8.self)[0] > 128 { id |= 1 << bit }
            }
            XCTAssertEqual(id, 15 + index * 2, "GIF frame \(index) selected the wrong source frame")
        }
        XCTAssertEqual(try GIFTestMedia.decode(request.outputURL).delays.reduce(0, +), 1, accuracy: 0.001)
    }

    func testSolidCensorSnapshotCoversItsFirstAndLastFrames() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let built = try VideoCompositionBuilder.build(asset: AVAsset(url: source),
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: 2, compositionDuration: 2)], includeAudio: false)
        let censor = VideoCensorSegment(startTime: 0, endTime: 0.5,
                                       rect: CGRect(x: 0, y: 0, width: 1, height: 1), style: .solid)
        let request = try request(built, custom: true, censors: [VideoCensorSnapshot(censor)])
        censor.startTime = 10
        try await GIFExporter.export(request)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(request.outputURL as CFURL, nil))
        let result = try GIFTestMedia.decode(request.outputURL)
        var time = 0.0
        for (index, delay) in result.delays.enumerated() {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, index, nil))
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            if time < 0.5 {
                for channel in 0..<3 { XCTAssertLessThan(bytes[channel], 8) }
            } else {
                XCTAssertGreaterThan(bytes[1], 100)
            }
            time += delay
        }
        XCTAssertEqual(time, 2, accuracy: 0.01)
    }

    func testCancellationBeforeAndDuringExportPreservesOriginalDestination() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let built = try VideoCompositionBuilder.build(asset: AVAsset(url: source),
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: 2, compositionDuration: 2)], includeAudio: false)
        let request = try request(built)
        let original = Data("Existing user's file".utf8)
        try original.write(to: request.outputURL)
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await GIFExporter.export(request)
        }
        do { try await before.value; XCTFail("Pre-cancelled export succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let started = expectation(description: "First frame encoded")
        let gate = DispatchSemaphore(value: 0)
        let during = Task {
            try await GIFExporter.export(request) { fraction in
                if fraction == 0 { started.fulfill(); gate.wait() }
            }
        }
        await fulfillment(of: [started], timeout: 10)
        during.cancel()
        gate.signal()
        do { try await during.value; XCTFail("Cancelled export succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: request.outputURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
