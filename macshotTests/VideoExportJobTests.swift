import AVFoundation
import XCTest

@MainActor
final class VideoExportJobTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func prepare(source: URL, high: Bool, lease: TemporaryMediaLease? = nil) throws -> VideoExportJob {
        let asset = AVAsset(url: source)
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 2), duration: CMTime(value: 1, timescale: 1))
        if high {
            let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
            session.outputURL = directory.appendingPathComponent("unused-high.mp4")
            session.outputFileType = .mp4
            session.timeRange = range
            return VideoExportJob(session: session, sourceLease: lease)
        }
        let request = VideoTranscoder.Request(asset: asset,
            videoTrack: try XCTUnwrap(asset.tracks(withMediaType: .video).first),
            audioTracks: asset.tracks(withMediaType: .audio), composition: nil,
            timeRange: range, outputURL: directory.appendingPathComponent("unused-medium.mp4"),
            videoSettings: VideoEncodingSettings.outputSettings(width: 64, height: 64, fps: 30,
                                                                 codec: .h264, quality: .medium),
            decodedSize: nil, outputTransform: .identity)
        return VideoExportJob(request: request, sourceLease: lease)
    }

    func testBothBackendsRetainSourceAcrossDestinationSetupAndAreSingleUse() async throws {
        for high in [false, true] {
            let source = try await RecordingMediaFixture.mixedMovie(in: directory)
            let cleanup = DispatchQueue(label: "VideoExportJobTests.cleanup")
            var lease: TemporaryMediaLease? = TemporaryMediaLease(url: source, cleanupQueue: cleanup)
            var job: VideoExportJob? = try prepare(source: source, high: high, lease: lease)
            // Simulate the editor releasing its disposable source while the
            // destination is still being prepared on another queue.
            lease = nil
            await Task.yield()
            cleanup.sync {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

            let output = directory.appendingPathComponent(UUID().uuidString + ".mp4")
            let save = try AtomicMediaSave(destinationURL: output)
            try await XCTUnwrap(job).export(to: save.stagingURL)
            try save.commit()
            let result = AVAsset(url: output)
            XCTAssertEqual(result.duration.seconds, 1, accuracy: 1.0 / 30)
            XCTAssertEqual(result.tracks(withMediaType: .audio).count, 2)
            let reader = try AVAssetReader(asset: result)
            let video = AVAssetReaderTrackOutput(track: try XCTUnwrap(result.tracks(withMediaType: .video).first),
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(video)
            XCTAssertTrue(reader.startReading())
            var count = 0
            while let frame = video.copyNextSampleBuffer() {
                XCTAssertNotNil(frame.imageBuffer)
                count += 1
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(count, 30)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unused-high.mp4").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unused-medium.mp4").path))

            let duplicate = directory.appendingPathComponent("duplicate.mp4")
            do { try await XCTUnwrap(job).export(to: duplicate); XCTFail("A prepared job ran twice") } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
            job = nil
            cleanup.sync {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testBothBackendsPreserveExistingDestination() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let output = directory.appendingPathComponent("existing.mp4")
        let original = Data("Existing user's file".utf8)
        try original.write(to: output)
        for high in [false, true] {
            let job = try prepare(source: source, high: high)
            do { try await job.export(to: output); XCTFail("An existing file was replaced") } catch {}
            XCTAssertEqual(try Data(contentsOf: output), original)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testBothBackendsHonorCancellationBeforeCreatingOutput() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        for high in [false, true] {
            let job = try prepare(source: source, high: high)
            let output = directory.appendingPathComponent(UUID().uuidString + ".mp4")
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await job.export(to: output)
            }
            do { try await task.value; XCTFail("Cancelled export succeeded") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
}
