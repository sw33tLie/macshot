import AVFoundation
import XCTest

final class VideoTimelineMediaTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func indexedPixels(_ index: Int) throws -> CVPixelBuffer {
        let pixels = try RecordingMediaFixture.pixels()
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for y in 8..<56 {
            for bit in 0..<6 {
                let value: UInt8 = index & (1 << bit) == 0 ? 0 : 255
                for x in (8 + bit * 8)..<(16 + bit * 8) {
                    let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                    for component in 0..<3 { bytes[offset + component] = value }
                }
            }
        }
        return pixels
    }

    private func frameIDs(_ asset: AVAsset) throws -> [(Double, Int)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .video).first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result: [(Double, Int)] = []
        while let sample = output.copyNextSampleBuffer() {
            let pixels = try XCTUnwrap(sample.imageBuffer)
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            var id = 0
            for bit in 0..<6 {
                if bytes[32 * CVPixelBufferGetBytesPerRow(pixels) + (12 + bit * 8) * 4] > 128 { id |= 1 << bit }
            }
            result.append((sample.presentationTimeStamp.seconds, id))
        }
        XCTAssertEqual(reader.status, .completed)
        return result
    }

    private func pcm(_ asset: AVAsset) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .audio).first),
            outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var values: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let data = try XCTUnwrap(sample.dataBuffer)
            var block = [Float](repeating: 0, count: CMBlockBufferGetDataLength(data) / 4)
            block.withUnsafeMutableBytes { bytes in
                XCTAssertEqual(CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes.count,
                                                        destination: bytes.baseAddress!), noErr)
            }
            values.append(contentsOf: block)
        }
        XCTAssertEqual(reader.status, .completed)
        return values
    }

    private func exportPlain(_ built: VideoCompositionBuilder.Result, usingEffects: Bool = false) async throws -> AVAsset {
        let size = CGSize(width: 64, height: 64)
        let composition: AVMutableVideoComposition
        if usingEffects {
            composition = AVMutableVideoComposition()
            composition.customVideoCompositorClass = EffectsVideoCompositor.self
            composition.renderSize = size; composition.frameDuration = built.frameDuration
            composition.instructions = [EffectsCompositionInstruction(
                timeRange: CMTimeRange(start: .zero, duration: built.composition.duration),
                videoTrackID: built.videoTrack.trackID, naturalSize: size, renderSize: size,
                baseTransform: .identity, timeMap: built.timeMap, zoomSegments: [], censorSegments: [])]
        } else {
            composition = try VideoCompositionRendering.scaleComposition(track: built.videoTrack,
                renderSize: size, duration: built.composition.duration, frameDuration: built.frameDuration)
        }
        let destination = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        try await VideoTranscoder.export(.init(asset: built.composition, videoTrack: built.videoTrack,
            audioTracks: built.audioTracks, composition: composition,
            timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), outputURL: destination,
            videoSettings: VideoEncodingSettings.outputSettings(width: 64, height: 64, fps: 30, codec: .h264, quality: .high),
            decodedSize: nil, outputTransform: .identity))
        return AVAsset(url: destination)
    }

    func testCutsSpeedAndFreezeExportTheExpectedFrameIDsAndSilence() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, pixelsForFrame: indexedPixels)
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 2,
                                        cuts: [VideoCutSegment(startTime: 0.5, endTime: 0.75)])
        let pieces = VideoSpeeds.pieces(keptRanges: kept,
            speeds: [VideoSpeedSegment(startTime: 1, endTime: 1.5, speedFactor: 2)],
            freezes: [VideoFreezeSegment(atTime: 1.25, holdDuration: 0.5)])
        let built = try VideoCompositionBuilder.build(asset: asset, pieces: pieces, includeAudio: true)
        XCTAssertEqual(built.duration, 2, accuracy: 0.000001)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = EffectsVideoCompositor.self
        composition.renderSize = CGSize(width: 64, height: 64)
        composition.frameDuration = built.frameDuration
        composition.instructions = [EffectsCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: built.composition.duration),
            videoTrackID: built.videoTrack.trackID, naturalSize: composition.renderSize,
            renderSize: composition.renderSize, baseTransform: .identity, timeMap: built.timeMap,
            zoomSegments: [], censorSegments: [])]
        let destination = directory.appendingPathComponent("timeline.mp4")
        try await VideoTranscoder.export(.init(asset: built.composition, videoTrack: built.videoTrack,
            audioTracks: built.audioTracks, composition: composition,
            timeRange: CMTimeRange(start: .zero, duration: built.composition.duration), outputURL: destination,
            videoSettings: VideoEncodingSettings.outputSettings(width: 64, height: 64, fps: 30, codec: .h264, quality: .high),
            decodedSize: nil, outputTransform: .identity))
        let result = AVAsset(url: destination)
        let ids = try frameIDs(result)
        XCTAssertEqual(ids.count, 60)
        for (time, actualID) in ids {
            // Independent expected timeline: retain [0,.5), [.75,2),
            // speed [1,1.5) at 2x, and add .5s at source 1.25s.
            let sourceTime: Double
            switch time {
            case ..<0.5: sourceTime = time
            case ..<0.75: sourceTime = time + 0.25
            case ..<0.875: sourceTime = 1 + (time - 0.75) * 2
            case ..<1.375: sourceTime = 1.25
            case ..<1.5: sourceTime = 1.25 + (time - 1.375) * 2
            default: sourceTime = time
            }
            let expectedID = min(59, Int(floor(sourceTime * 30 + 0.000001)))
            XCTAssertEqual(actualID, expectedID, "Output \(time)s must show source \(sourceTime)s")
        }
        let frozen = ids.filter { $0.0 >= 0.9 && $0.0 < 1.37 }
        XCTAssertEqual(Set(frozen.map(\.1)), [37])
        XCTAssertEqual(result.tracks(withMediaType: .audio).count, 2)
        let samples = try pcm(result)
        func rms(_ range: Range<Int>) -> Double {
            sqrt(samples[range].reduce(0.0) { $0 + Double($1 * $1) } / Double(range.count))
        }
        XCTAssertGreaterThan(samples.count, 90_000)
        guard samples.count > 90_000 else { return }
        XCTAssertGreaterThan(rms(9_600..<19_200), 0.1)
        XCTAssertLessThan(rms(48_000..<60_000), 0.002, "The middle of a held frame must be silent")
        XCTAssertGreaterThan(rms(76_800..<86_400), 0.1)
    }

    func testInvalidTimelineFailsInsteadOfPublishingAPartialComposition() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory)
        let asset = AVAsset(url: source)
        for pieces: [VideoSpeeds.Piece] in [[],
            [.init(kind: .normal, srcStart: 0, srcEnd: 3, compositionDuration: 3)],
            [.init(kind: .normal, srcStart: .nan, srcEnd: 1, compositionDuration: 1)],
            [.init(kind: .normal, srcStart: 0, srcEnd: 0, compositionDuration: 1)],
            [.init(kind: .normal, srcStart: 0, srcEnd: 1, compositionDuration: .infinity)]] {
            XCTAssertThrowsError(try VideoCompositionBuilder.build(asset: asset, pieces: pieces, includeAudio: true))
        }
    }

    func testCutsAndSpeedKeepFractionalSourceEndAndSkipRemovedFrames() async throws {
        // An endpoint of 32/30 rounds OUTWARD on the old 1 GHz edit clock.
        // Unlike whole-second fixtures, even a single cut used to fail the
        // final source-range containment check and leave preview uncut.
        let url = try await RecordingMediaFixture.mixedMovie(in: directory, frameCount: 32,
                                                            pixelsForFrame: indexedPixels)
        let asset = AVURLAsset(url: url)
        let end = asset.tracks(withMediaType: .video)[0].timeRange.end.seconds
        let cut = VideoCutSegment(startTime: 0.2, endTime: 0.4)
        for speeds: [VideoSpeedSegment] in [[], [.init(startTime: 0.1, endTime: 0.8, speedFactor: 2)]] {
            let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: end, cuts: [cut])
            let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: speeds)
            let built = try VideoCompositionBuilder.build(asset: asset, pieces: pieces, includeAudio: true)
            XCTAssertEqual(built.duration, VideoSpeeds.totalCompositionDuration(pieces), accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(built.timeMap.last).sourceStart +
                (built.timeMap.last!.compEnd - built.timeMap.last!.compStart) * built.timeMap.last!.factor,
                end, accuracy: 0.000001)
            for pair in zip(built.timeMap, built.timeMap.dropFirst()) {
                XCTAssertEqual(pair.0.compEnd, pair.1.compStart)
            }
            let output = try await exportPlain(built, usingEffects: true)
            let frames = try frameIDs(output)
            XCTAssertFalse(frames.isEmpty)
            XCTAssertEqual(frames.last?.1, 31, "The last source frame must survive")
            XCTAssertTrue(frames.allSatisfy { !(6..<12).contains($0.1) }, "Playback/export must skip the cut")
            XCTAssertEqual(output.duration.seconds, built.duration, accuracy: 1.0 / 30)
            XCTAssertEqual(output.tracks(withMediaType: .audio).count, 2)
        }
    }

    func testFreezeAtAnExactRationalFrameBoundaryHoldsThatFrame() async throws {
        let source = try await RecordingMediaFixture.mixedMovie(in: directory, pixelsForFrame: indexedPixels)
        let pieces = VideoSpeeds.pieces(keptRanges: [(0, 2)], speeds: [],
            freezes: [VideoFreezeSegment(atTime: 1.0 / 3, holdDuration: 0.2)])
        let built = try VideoCompositionBuilder.build(asset: AVAsset(url: source), pieces: pieces, includeAudio: false)
        let output = try await exportPlain(built, usingEffects: true)
        let ids = try frameIDs(output)
        let held = ids.filter { $0.0 >= 1.0 / 3 - 0.000001 && $0.0 < 1.0 / 3 + 0.2 - 0.000001 }
        XCTAssertEqual(held.count, 6)
        XCTAssertEqual(Set(held.map(\.1)), [10], "Rounding must not freeze the preceding frame")
        XCTAssertEqual(output.duration.seconds, 2.2, accuracy: 0.000001)
    }

    func testFractionalFrameRateAndExactSourceEndSurviveReencoding() async throws {
        // Write genuine 30000/1001 timestamps. A passthrough export of a
        // scaleTimeRange composition may preserve a 30 fps media timebase
        // plus an edit mapping, which is not the fixture this test needs.
        let url = directory.appendingPathComponent("ntsc.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: VideoEncodingSettings.outputSettings(
            width: 64, height: 64, fps: 30, codec: .h264, quality: .high))
        input.mediaTimeScale = 30_000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<19 {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertTrue(adaptor.append(try indexedPixels(index),
                withPresentationTime: CMTime(value: Int64(index * 1001), timescale: 30_000)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 19 * 1001, timescale: 30_000))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let ntsc = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let sourceFrames = try frameIDs(ntsc)
        XCTAssertEqual(sourceFrames.count, 19)
        for (index, frame) in sourceFrames.enumerated() {
            XCTAssertEqual(frame.0, Double(index) * 1001 / 30_000, accuracy: 0.000001,
                           "The input fixture itself must have genuine NTSC timestamps")
        }
        let built = try VideoCompositionBuilder.build(asset: ntsc,
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: ntsc.duration.seconds,
                           compositionDuration: ntsc.duration.seconds)], includeAudio: false)
        XCTAssertEqual(CMTimeCompare(built.composition.duration, ntsc.duration), 0)
        XCTAssertEqual(built.frameDuration.seconds, 1001.0 / 30_000, accuracy: 0.00000001)
        let customOutput = try await exportPlain(built)
        let highURL = directory.appendingPathComponent("ntsc-high.mp4")
        let highSession = try XCTUnwrap(AVAssetExportSession(asset: built.composition,
            presetName: AVAssetExportPresetHighestQuality))
        highSession.outputURL = highURL; highSession.outputFileType = .mp4
        highSession.videoComposition = try VideoCompositionRendering.scaleComposition(track: built.videoTrack,
            renderSize: CGSize(width: 64, height: 64), duration: built.composition.duration, frameDuration: built.frameDuration)
        await highSession.export()
        XCTAssertEqual(highSession.status, .completed)
        for output in [customOutput, AVAsset(url: highURL)] {
            let frames = try frameIDs(output)
            XCTAssertEqual(frames.count, 19)
            for (index, frame) in frames.enumerated() {
                XCTAssertEqual(frame.0, Double(index) * 1001 / 30_000, accuracy: 0.000001)
                XCTAssertEqual(frame.1, index)
            }
        }
    }

    func testEightHourSparseVideoCanBeReencodedWithoutSampleDurationOverflow() async throws {
        // Three frames spanning eight hours, not an eight-hour endurance run.
        let source = directory.appendingPathComponent("long-static.mp4")
        let queue = DispatchQueue(label: "macshot.tests.long-export")
        let writer = try MP4WriterSession.make(queue: queue, url: source, width: 64, height: 64, fps: 30,
                                               recordSystemAudio: false, recordMicAudio: false)
        for (index, seconds) in [0.0, 0.1].enumerated() {
            let pixels = try indexedPixels(index)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !queue.sync(execute: { writer.handleFrame(pixelBuffer: pixels,
                presentationTime: CMTime(seconds: seconds, preferredTimescale: 60_000)) }) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        writer.requestStop(atSourceTime: CMTime(value: 28_800, timescale: 1))
        try await writer.finish()
        let asset = AVAsset(url: source)
        let video = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let destination = directory.appendingPathComponent("long-export.mp4")
        try await VideoTranscoder.export(.init(asset: asset, videoTrack: video, audioTracks: [], composition: nil,
            timeRange: CMTimeRange(start: .zero, duration: asset.duration), outputURL: destination,
            videoSettings: VideoEncodingSettings.outputSettings(width: 64, height: 64, fps: 30, codec: .h264, quality: .low),
            decodedSize: nil, outputTransform: .identity))
        let output = AVAsset(url: destination)
        let frames = try frameIDs(output)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(frames.map(\.1), [0, 1, 1])
        XCTAssertEqual(output.duration.seconds, 28_800, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(frames.last).0, 28_800 - 1.0 / 30, accuracy: 0.001)
    }
}
