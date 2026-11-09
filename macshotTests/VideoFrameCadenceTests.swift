import AVFoundation
import XCTest

final class VideoFrameCadenceTests: XCTestCase {
    func testIsolatedShortSamplesDoNotMultiplyExportFrameRate() {
        let motion = [CMTime](repeating: CMTime(value: 1, timescale: 30), count: 300)
        let idle = [CMTime](repeating: CMTime(value: 105, timescale: 100), count: 300)
        for tail in [CMTime(value: 807, timescale: 60_000), CMTime(value: 1, timescale: 60_000)] {
            let cadence = VideoFrameCadence.representativeDuration(intervals: motion + idle + [tail],
                minimum: tail, nominalRate: 15.48)
            XCTAssertEqual(cadence, CMTime(value: 1, timescale: 30))
        }
    }

    func testRecurringFasterMotionSurvivesSlowerSectionsAndRationalCadenceIsExact() {
        let slow = [CMTime](repeating: CMTime(value: 1, timescale: 24), count: 300)
        let fast = [CMTime](repeating: CMTime(value: 1001, timescale: 60_000), count: 80)
        let result = VideoFrameCadence.representativeDuration(intervals: slow + fast + [.invalid, .zero],
            minimum: .invalid, nominalRate: 27)
        XCTAssertEqual(result, CMTime(value: 1001, timescale: 60_000))
        let short = VideoFrameCadence.representativeDuration(
            intervals: [CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 60_000)],
            minimum: CMTime(value: 1, timescale: 60_000), nominalRate: 60)
        XCTAssertEqual(short, CMTime(value: 1, timescale: 30))
    }

    func testDeclaredCadencePreservesRationalsAndRejectsUnusableValues() throws {
        let expected = CMTime(value: 1001, timescale: 30_000)
        XCTAssertEqual(VideoFrameCadence.declaredDuration(in: VideoFrameCadence.metadata(for: expected)), expected)
        XCTAssertTrue(VideoFrameCadence.metadata(for: .invalid).isEmpty)
        let template = try XCTUnwrap(VideoFrameCadence.metadata(for: expected).first)
        for value in ["0/30", "1/0", "-1/30", "1/1000000", "9000000000000/1", "1/30/60", "nan", "1/2147483648"] {
            let item = try XCTUnwrap(template.mutableCopy() as? AVMutableMetadataItem)
            item.value = "macshot; frame-duration=\(value)" as NSString
            XCTAssertNil(VideoFrameCadence.declaredDuration(in: [item]), value)
        }
        let unrelated = try XCTUnwrap(template.mutableCopy() as? AVMutableMetadataItem)
        unrelated.value = "Some App; frame-duration=1/30" as NSString
        XCTAssertNil(VideoFrameCadence.declaredDuration(in: [unrelated]))
    }

    func testUnmarkedVFRMovieUsesRecurringTimingAndRenderedExportKeepsThatCadence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unmarked-vfr.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings:
            VideoEncodingSettings.outputSettings(width: 64, height: 64, fps: 30, codec: .h264, quality: .high))
        input.mediaTimeScale = 60_000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pixels = try RecordingMediaFixture.pixels()
        let times = (0..<60).map { CMTime(value: Int64($0 * 2000), timescale: 60_000) }
            + [CMTime(value: 8, timescale: 1), CMTime(value: 480_001, timescale: 60_000)]
        for time in times {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: time))
        }
        writer.endSession(atSourceTime: CMTime(value: 9, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let asset = AVURLAsset(url: url)
        XCTAssertNil(VideoFrameCadence.declaredDuration(in: asset.metadata))
        let prepared = try await PreparedVideoSource.loadMetadata(for: asset)
        XCTAssertEqual(prepared.encodingSource.frameDuration, CMTime(value: 1, timescale: 30))
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let composition = try VideoCompositionRendering.scaleComposition(track: track,
            renderSize: CGSize(width: 32, height: 32), duration: CMTime(value: 9, timescale: 1),
            frameDuration: prepared.encodingSource.frameDuration)
        // Animated effects need regular output even during a static hold.
        // Static scaling alone is allowed to retain sparse source timing.
        let instruction = try XCTUnwrap(composition.instructions.first as? AVVideoCompositionInstruction)
        let layer = try XCTUnwrap(instruction.layerInstructions.first as? AVMutableVideoCompositionLayerInstruction)
        layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.5,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 9, timescale: 1)))
        XCTAssertTrue(instruction.containsTweening)
        let outputURL = directory.appendingPathComponent("rendered.mp4")
        try await VideoTranscoder.export(.init(asset: asset, videoTrack: track, audioTracks: [],
            composition: composition, timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 9, timescale: 1)),
            outputURL: outputURL, videoSettings: VideoEncodingSettings.outputSettings(
                width: 32, height: 32, fps: 30, codec: .h264, quality: .medium),
            decodedSize: nil, outputTransform: .identity))
        let output = AVURLAsset(url: outputURL)
        XCTAssertEqual(VideoFrameCadence.declaredDuration(in: output.metadata), CMTime(value: 1, timescale: 30))
        let reader = try AVAssetReader(asset: output)
        let frames = AVAssetReaderTrackOutput(track: try XCTUnwrap(output.tracks(withMediaType: .video).first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(frames)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while let frame = frames.copyNextSampleBuffer() {
            XCTAssertNotNil(frame.imageBuffer)
            XCTAssertEqual(frame.presentationTimeStamp.seconds, Double(count) / 30, accuracy: 0.00001)
            count += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(count, 270)
    }

    func testNTSCFrameIntervalsDoNotDriftOnAnEightHourTimeline() {
        for numerator: Int32 in [24_000, 30_000, 60_000, 120_000] {
            let expected = CMTime(value: 1001, timescale: numerator)
            for minimum in [CMTime.invalid, expected] {
                let actual = VideoFrameCadence.duration(minimum: minimum, nominalRate: Float(numerator) / 1001)
                XCTAssertEqual(CMTimeCompare(actual, expected), 0)
                let frameCount = Int32(floor(28_800 / expected.seconds))
                XCTAssertEqual(CMTimeCompare(CMTimeMultiply(actual, multiplier: frameCount),
                    CMTimeMultiply(expected, multiplier: frameCount)), 0)
            }
        }
    }

    func testSampleCadenceTakesPrecedenceAndInvalidMetadataHasAFiniteFallback() {
        XCTAssertEqual(VideoFrameCadence.duration(minimum: CMTime(value: 1, timescale: 60), nominalRate: 29.97),
                       CMTime(value: 1, timescale: 60))
        for nominal: Float in [.nan, .infinity, -1, 0, 1001] {
            XCTAssertEqual(VideoFrameCadence.duration(minimum: .invalid, nominalRate: nominal),
                           CMTime(value: 1, timescale: 30))
        }
    }

    func testContainerClockPreservesNTSCPeriodsWithoutOverflowingLongStaticSamples() {
        for numerator: Int32 in [24_000, 30_000, 60_000] {
            for hours in [1, 4, 8] {
                let frame = CMTime(value: 1001, timescale: numerator)
                let duration = CMTime(value: Int64(hours * 3600), timescale: 1)
                let scale = VideoFrameCadence.mediaTimeScale(frameDuration: frame, duration: duration)
                XCTAssertEqual(CMTimeCompare(CMTimeConvertScale(frame, timescale: scale, method: .default), frame), 0)
                XCTAssertLessThanOrEqual(Int64(scale) * duration.value, Int64(Int32.max))
            }
        }
    }
}
