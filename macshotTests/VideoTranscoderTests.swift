import AVFoundation
import XCTest

final class VideoTranscoderTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func request(source: URL, composition: AVVideoComposition? = nil,
                         audio: Bool = true) throws -> VideoTranscoder.Request {
        let asset = AVAsset(url: source)
        return VideoTranscoder.Request(asset: asset,
            videoTrack: try XCTUnwrap(asset.tracks(withMediaType: .video).first),
            audioTracks: audio ? asset.tracks(withMediaType: .audio) : [], composition: composition,
            timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 2), duration: CMTime(value: 1, timescale: 1)),
            outputURL: directory.appendingPathComponent(UUID().uuidString + ".mp4"),
            videoSettings: VideoEncodingSettings.outputSettings(width: 64, height: 64, fps: 30,
                                                                 codec: .h264, quality: .medium),
            decodedSize: nil, outputTransform: .identity)
    }

    func testNonzeroTrimStartsAtZeroAndDrainsBothAudioTracks() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let request = try request(source: source)
        try await VideoTranscoder.export(request)
        let boxes = try MP4Boxes.topLevel(request.outputURL)
        XCTAssertTrue(try MP4Boxes.isFastStart(request.outputURL), "exports put the index first (#452): \(boxes)")
        let asset = AVAsset(url: request.outputURL)
        XCTAssertEqual(asset.duration.seconds, 1, accuracy: 1.0 / 30)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 2)
        let channels = try asset.tracks(withMediaType: .audio).map { track in
            let format = try XCTUnwrap((track.formatDescriptions as? [CMAudioFormatDescription])?.first)
            return try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee.mChannelsPerFrame
        }
        XCTAssertEqual(channels, [1, 2], "Export must keep the microphone mono and system audio stereo")
        let tracks = asset.tracks
        XCTAssertEqual(tracks.count, 3)
        for track in tracks {
            XCTAssertEqual(track.timeRange.start.seconds, 0, accuracy: 0.025)
            XCTAssertEqual(track.timeRange.duration.seconds, 1, accuracy: 0.025)
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = track.mediaType == .video
                ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                : [AVFormatIDKey: kAudioFormatLinearPCM]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var first: Double?, end = 0.0, samples = 0
            while let sample = output.copyNextSampleBuffer() {
                if first == nil { first = sample.presentationTimeStamp.seconds }
                // Decoded video buffers may omit duration. Check their last
                // presentation time separately from PCM's sample duration.
                let tail = track.mediaType == .video ? sample.presentationTimeStamp
                    : CMTimeAdd(sample.presentationTimeStamp, sample.duration)
                XCTAssertTrue(tail.isNumeric)
                end = max(end, tail.seconds)
                samples += sample.numSamples
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(try XCTUnwrap(first), 0, accuracy: 0.025)
            XCTAssertEqual(end, track.mediaType == .video ? 29.0 / 30 : 1, accuracy: 0.025)
            XCTAssertGreaterThanOrEqual(samples, track.mediaType == .video ? 29 : 47_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCompositorUsesSnapshotAndCoversFirstAndLastCensorFrames() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let asset = AVAsset(url: source)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let censor = VideoCensorSegment(startTime: 0.5, endTime: 1.5,
                                        rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), style: .solid)
        let size = CGSize(width: 64, height: 64)
        let instruction = EffectsCompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: asset.duration),
            videoTrackID: track.trackID, naturalSize: size, renderSize: size, baseTransform: .identity,
            timeMap: [.init(compStart: 0, compEnd: 2, sourceStart: 0, factor: 1)],
            zoomSegments: [], censorSegments: [VideoCensorSnapshot(censor)])
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = EffectsVideoCompositor.self
        composition.instructions = [instruction]
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        censor.startTime = 10; censor.rect = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let request = try request(source: source, composition: composition, audio: false)
        try await VideoTranscoder.export(request)
        let result = AVAsset(url: request.outputURL)
        XCTAssertTrue(result.tracks(withMediaType: .audio).isEmpty)
        let reader = try AVAssetReader(asset: result)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(result.tracks(withMediaType: .video).first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            let pixels = try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let left = CVPixelBufferGetBytesPerRow(pixels) * 32 + 16 * 4
            let right = CVPixelBufferGetBytesPerRow(pixels) * 32 + 48 * 4
            for component in 0..<3 { XCTAssertLessThan(base[left + component], 8, "Frame \(count) exposes censored pixels") }
            XCTAssertGreaterThan(base[right + 1], 100)
            count += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, 30)
    }

    func testCancelledOrExistingDestinationExportPreservesFiles() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let request = try request(source: source)
        let bytes = Data("existing destination".utf8)
        try bytes.write(to: request.outputURL)
        do {
            try await VideoTranscoder.export(request)
            XCTFail("An existing destination must never be deleted by the encoder")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: request.outputURL), bytes)
        let cancelled = try self.request(source: source)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await VideoTranscoder.export(cancelled)
        }
        do { try await task.value; XCTFail("Cancelled export succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
