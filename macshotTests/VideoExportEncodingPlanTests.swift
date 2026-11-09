import AVFoundation
import XCTest

@MainActor
final class VideoExportEncodingPlanTests: XCTestCase {
    private func source(rate: Double = 2_000_000, codec: CMVideoCodecType? = kCMVideoCodecType_H264,
                        fps: Double = 30, period: Double = 1.0 / 30,
                        size: CGSize = CGSize(width: 1920, height: 1080)) -> VideoExportEncodingPlan.Source {
        .init(size: size, averageBitrate: rate, codec: codec, nominalFPS: fps, minimumFrameDuration: period)
    }

    private func plan(_ source: VideoExportEncodingPlan.Source, quality: VideoQuality = .medium,
                      scale: Double = 1, sourceDuration: Double = 120,
                      outputDuration: Double = 120) throws -> VideoExportEncodingPlan {
        try XCTUnwrap(VideoExportEncodingPlan.make(source: source, scale: scale, quality: quality,
            sourceDuration: sourceDuration, outputDuration: outputDuration))
    }

    func testCompressedH264DoesNotInheritLiveRecordingBitrateFloor() throws {
        let medium = try plan(source())
        let low = try plan(source(), quality: .low)
        XCTAssertEqual(medium.videoBitrate, 1_600_000)
        XCTAssertEqual(low.videoBitrate, 1_000_000)
        XCTAssertLessThan(medium.videoBitrate, VideoQuality.medium.minBitrate)
        let compression = try XCTUnwrap(medium.outputSettings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(compression[AVVideoAverageBitRateKey] as? Int, medium.videoBitrate)
        XCTAssertEqual(medium.outputSettings[AVVideoWidthKey] as? Int, 1920)
    }

    func testSparseAndDifferentCodecSourcesDoNotUseMisleadingAverageAsACap() throws {
        let sparse = try plan(source(rate: 1_200, fps: 1))
        let unknownRate = try plan(source(rate: .nan))
        XCTAssertEqual(sparse.videoBitrate, unknownRate.videoBitrate)
        XCTAssertEqual(sparse.fps, 30)
        for codec: CMVideoCodecType? in [nil, kCMVideoCodecType_HEVC, kCMVideoCodecType_AppleProRes422] {
            XCTAssertEqual(try plan(source(rate: 1_200, codec: codec)).videoBitrate, unknownRate.videoBitrate)
        }
        let ntsc = try plan(source(fps: 30_000.0 / 1001, period: 1001.0 / 30_000))
        XCTAssertEqual(ntsc.videoBitrate, 1_600_000)
    }

    func testResolvedCadenceControlsBudgetInsteadOfAShortHeartbeatInterval() throws {
        var recording = source(rate: 430_000, fps: 15.48, period: 0.01345)
        recording.frameDuration = CMTime(value: 1, timescale: 30)
        let actual = try plan(recording)
        XCTAssertEqual(actual.fps, 30)
        XCTAssertEqual(actual.videoBitrate, try plan(source(rate: .nan)).videoBitrate)
        XCTAssertNil(actual.estimatedBytes(duration: 3600, audioTrackCount: 2, audioBitrate: 128_000))
    }

    func testSizeEstimatesRequireAComparableSourceRatherThanOnlyAnEncoderBudget() throws {
        for input in [source(rate: 1_200, fps: 1), source(rate: .nan),
                      source(codec: kCMVideoCodecType_HEVC), source(codec: nil)] {
            let target = try plan(input)
            XCTAssertGreaterThan(target.videoBitrate, 0, "encoding still has a valid target")
            XCTAssertNil(target.estimatedBytes(duration: 3600, audioTrackCount: 2, audioBitrate: 128_000))
        }
        XCTAssertNil(try plan(source(), quality: .high)
            .estimatedBytes(duration: 60, audioTrackCount: 1, audioBitrate: 128_000))
        XCTAssertNotNil(try plan(source(), quality: .low)
            .estimatedBytes(duration: 60, audioTrackCount: 1, audioBitrate: 128_000))
    }

    func testDownscalingReducesBudgetAndFasterMotionGetsAllowance() throws {
        let full = try plan(source())
        let half = try plan(source(), scale: 0.5)
        XCTAssertEqual(half.width, 960)
        XCTAssertEqual(half.height, 540)
        XCTAssertLessThan(half.videoBitrate, full.videoBitrate)
        let accelerated = try plan(source(), sourceDuration: 120, outputDuration: 60)
        XCTAssertEqual(accelerated.videoBitrate, full.videoBitrate * 2)
        let held = try plan(source(), sourceDuration: 120, outputDuration: 240)
        XCTAssertEqual(held.videoBitrate, full.videoBitrate)
    }

    func testEstimatesUseEditedDurationAndEveryAudioTrackEvenAtEightHours() throws {
        let plan = try plan(source())
        let short = try XCTUnwrap(plan.estimatedBytes(duration: 60, audioTrackCount: 0, audioBitrate: 128_000))
        let long = try XCTUnwrap(plan.estimatedBytes(duration: 28_800, audioTrackCount: 2, audioBitrate: 128_000))
        XCTAssertEqual(short, 12_376_384)
        XCTAssertEqual(long, 6_882_064_384)
        XCTAssertNil(plan.estimatedBytes(duration: .infinity, audioTrackCount: 1, audioBitrate: 128_000))
        XCTAssertNil(plan.estimatedBytes(duration: Double.greatestFiniteMagnitude, audioTrackCount: Int.max,
                                        audioBitrate: Int.max))
        XCTAssertNil(plan.estimatedBytes(duration: 1, audioTrackCount: -1, audioBitrate: 128_000))
    }

    func testMalformedMetadataNeverTrapsOrCreatesAnUnboundedEncoderTarget() throws {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1, 0] {
            XCTAssertNil(VideoExportEncodingPlan.make(source: source(), scale: value, quality: .medium,
                sourceDuration: 120, outputDuration: 120))
            XCTAssertNil(VideoExportEncodingPlan.make(source: source(size: CGSize(width: value, height: 1080)),
                scale: 1, quality: .medium, sourceDuration: 120, outputDuration: 120))
            let result = try plan(source(rate: value, fps: value, period: value))
            XCTAssertGreaterThanOrEqual(result.videoBitrate, 128_000)
            XCTAssertLessThanOrEqual(result.videoBitrate, VideoQuality.medium.maxBitrate)
            XCTAssertEqual(result.fps, 30)
        }
    }

    func testPreparedMetadataAndPlannedWriterProduceDecodableAudioAndVideo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = try await RecordingMediaFixture.mixedMovie(in: directory)
        let asset = AVURLAsset(url: sourceURL)
        let metadata = try await PreparedVideoSource.loadMetadata(for: asset)
        XCTAssertEqual(metadata.audioTrackCount, 2)
        XCTAssertEqual(metadata.encodingSource.codec, kCMVideoCodecType_H264)
        XCTAssertGreaterThan(metadata.encodingSource.averageBitrate, 0)
        for quality: VideoQuality in [.low, .medium] {
            let plan = try plan(metadata.encodingSource, quality: quality)
            let outputURL = directory.appendingPathComponent("\(quality.rawValue).mp4")
            try await VideoTranscoder.export(.init(asset: asset,
                videoTrack: try XCTUnwrap(asset.tracks(withMediaType: .video).first),
                audioTracks: asset.tracks(withMediaType: .audio), composition: nil,
                timeRange: CMTimeRange(start: .zero, duration: asset.duration), outputURL: outputURL,
                videoSettings: plan.outputSettings, decodedSize: nil, outputTransform: .identity))
            let output = AVAsset(url: outputURL)
            XCTAssertEqual(output.duration.seconds, 2, accuracy: 0.025)
            XCTAssertEqual(output.tracks(withMediaType: .audio).count, 2)
            let reader = try AVAssetReader(asset: output)
            let frames = AVAssetReaderTrackOutput(track: try XCTUnwrap(output.tracks(withMediaType: .video).first),
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(frames)
            XCTAssertTrue(reader.startReading())
            var count = 0
            while let frame = frames.copyNextSampleBuffer() {
                XCTAssertNotNil(frame.imageBuffer)
                count += 1
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertEqual(count, 60)
        }
    }
}
