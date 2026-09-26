import AVFoundation
import CoreImage
import XCTest

final class VideoStudioMediaTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func videoSample(_ pixels: CVPixelBuffer, at time: CMTime) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                                    formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func presentationTimes(_ url: URL) throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .video).first),
                                              outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { times.append(sample.presentationTimeStamp.seconds) }
        }
        return times.sorted()
    }

    func testWriterReportsTheFirstFramesHostTime() async throws {
        let queue = DispatchQueue(label: "test.writer")
        let started = Locked<CMTime?>(nil)
        let writer = try MP4WriterSession.make(queue: queue, url: directory.appendingPathComponent("a.mp4"),
            width: 64, height: 64, fps: 30, recordSystemAudio: false, recordMicAudio: false,
            onSessionStart: { started.value = $0 })
        let pixels = try RecordingMediaFixture.pixels()
        for tick in 0..<5 {
            let time = CMTime(value: 3000 + Int64(tick), timescale: 30)
            _ = queue.sync { writer.handleFrame(pixelBuffer: pixels, presentationTime: time) }
        }
        writer.requestStop(atSourceTime: CMTime(value: 3005, timescale: 30))
        try await writer.finish()
        XCTAssertEqual(started.value?.seconds ?? 0, 100, accuracy: 0.0001)
    }

    func testCameraRecorderAlignsToTheScreenAndRemovesPauses() async throws {
        let recorder = VideoCameraRecorder()
        recorder.open(directory: directory)
        recorder.markStart(hostTime: 100)
        let pixels = try RecordingMediaFixture.pixels(width: 64, height: 48)
        // Frames before the screen's first frame are dropped.
        recorder.append(try videoSample(pixels, at: CMTime(value: 1, timescale: 30)), hostTime: 99.5)
        for i in 0..<30 {
            let host = 100 + Double(i) / 30
            recorder.append(try videoSample(pixels, at: CMTime(value: Int64(i), timescale: 30)), hostTime: host)
            try await Task.sleep(nanoseconds: 15_000_000) // real-time pacing
        }
        recorder.pause()
        recorder.append(try videoSample(pixels, at: CMTime(value: 40, timescale: 30)), hostTime: 101.5)
        recorder.resume(pausedDuration: 2)
        for i in 0..<15 {
            let host = 103 + Double(i) / 30
            recorder.append(try videoSample(pixels, at: CMTime(value: Int64(90 + i), timescale: 30)), hostTime: host)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        await recorder.finish()
        // Real-time encoding may drop a frame under load; timing must hold.
        XCTAssertGreaterThanOrEqual(recorder.frameCount, 35)
        let times = try presentationTimes(directory.appendingPathComponent(VideoCameraRecorder.filename))
        XCTAssertEqual(times.count, recorder.frameCount)
        XCTAssertEqual(times.first ?? -1, 0, accuracy: 0.05)
        XCTAssertEqual(times, times.sorted())
        XCTAssertLessThan(times.last ?? 99, 1.5, "the 2 s pause is removed")
        // After the pause, host 103 continues at media 1.0 with no gap before it.
        let resumed = try XCTUnwrap(times.first { $0 >= 0.99 })
        XCTAssertEqual(resumed, 1.0, accuracy: 0.07)
        XCTAssertFalse(times.contains { $0 > 1.5 && $0 < 3 })
        XCTAssertEqual(VideoCameraRecorder.mediaTime(host: 99, anchor: 100, pausedTotal: 0), nil)
    }

    func testCameraRecorderWritesBubbleMovesOnTheMediaClock() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let recorder = VideoCameraRecorder()
        recorder.open(directory: directory)
        // Placed before the screen's first frame: the take starts there.
        recorder.recordPlacement(frame: CGRect(x: 12, y: 12, width: 100, height: 100), in: bounds, hostTime: 50)
        recorder.markStart(hostTime: 100)
        let pixels = try RecordingMediaFixture.pixels(width: 64, height: 48)
        for i in 0..<10 {
            let host = 100 + Double(i) / 10
            recorder.append(try videoSample(pixels, at: CMTime(value: Int64(i), timescale: 10)), hostTime: host)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        recorder.recordPlacement(frame: CGRect(x: 450, y: 200, width: 100, height: 100), in: bounds, hostTime: 100.5)
        recorder.pause(hostTime: 101)
        // Moved while paused: takes effect where the take resumes.
        recorder.recordPlacement(frame: CGRect(x: 800, y: 300, width: 200, height: 200), in: bounds, hostTime: 101.8)
        recorder.resume(pausedDuration: 2)
        for i in 0..<5 {
            let host = 103 + Double(i) / 10
            recorder.append(try videoSample(pixels, at: CMTime(value: Int64(30 + i), timescale: 10)), hostTime: host)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        await recorder.finish()

        let track = try XCTUnwrap(CameraPlacementTrack.load(url: directory.appendingPathComponent(CameraPlacementTrack.filename)))
        XCTAssertEqual(track.samples.count, 3)
        let times = track.samples.map(\.time)
        XCTAssertEqual(times[0], 0)
        XCTAssertEqual(times[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(times[2], 1.0, accuracy: 1e-6)
        XCTAssertEqual(track.samples[0].centerY, 0.876, accuracy: 1e-6)
        XCTAssertEqual(track.samples[1].centerX, 0.5, accuracy: 1e-6)
        XCTAssertEqual(track.samples[2].size, 0.4, accuracy: 1e-6)
    }

    func testCameraWithoutFramesLeavesNoFile() async {
        let recorder = VideoCameraRecorder()
        recorder.open(directory: directory)
        recorder.markStart(hostTime: 1)
        await recorder.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(VideoCameraRecorder.filename).path))
    }

    func testCameraTrackFollowsCutsAndSpeed() async throws {
        let screen = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory))
        let camera = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 48, height: 48)))
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 2, cuts: [VideoCutSegment(startTime: 0.5, endTime: 1)])
        let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: [VideoSpeedSegment(startTime: 1, endTime: 1.5, speedFactor: 2)])
        let built = try VideoCompositionBuilder.build(asset: screen, pieces: pieces, includeAudio: false, camera: camera)
        let track = try XCTUnwrap(built.cameraTrack)
        XCTAssertEqual(built.duration, 1.25, accuracy: 0.0001)
        XCTAssertEqual(track.timeRange.end.seconds, built.duration, accuracy: 0.02)
        // Every edited instant with screen video also has camera video.
        for t in stride(from: 0.05, to: 1.2, by: 0.1) {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            let segment = track.segment(forTrackTime: time)
            XCTAssertFalse(segment?.isEmpty ?? true, "camera missing at \(t)")
        }
    }

    func testFreezeHoldsASingleCameraFrame() async throws {
        let screen = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory))
        let camera = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 48, height: 48)))
        let pieces = VideoSpeeds.pieces(keptRanges: [(0, 2)], speeds: [],
                                        freezes: [VideoFreezeSegment(atTime: 1, holdDuration: 1)])
        let built = try VideoCompositionBuilder.build(asset: screen, pieces: pieces, includeAudio: false, camera: camera)
        let track = try XCTUnwrap(built.cameraTrack)
        let hold = try XCTUnwrap(track.segment(forTrackTime: CMTime(seconds: 1.5, preferredTimescale: 600)))
        XCTAssertFalse(hold.isEmpty)
        // One camera frame (1/30 s) stretched across the whole one-second hold.
        XCTAssertEqual(hold.timeMapping.source.duration.seconds, 1.0 / 30, accuracy: 0.002)
        XCTAssertEqual(hold.timeMapping.target.duration.seconds, 1, accuracy: 0.002)
    }

    func testFramedSceneExportsCanvasWithBackgroundAndRecording() async throws {
        let source = AVURLAsset(url: try await RecordingMediaFixture.mixedMovie(in: directory, size: CGSize(width: 160, height: 96)))
        let track = try XCTUnwrap(source.tracks(withMediaType: .video).first)
        var frame = VideoFrameStyle()
        frame.enabled = true
        frame.padding = 0.25
        frame.cornerRadius = 0
        let layout = try XCTUnwrap(VideoSceneGeometry.layout(contentSize: CGSize(width: 160, height: 96),
                                                             crop: CGRect(x: 0, y: 0, width: 1, height: 1), frame: frame))
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(origin: .zero, size: layout.canvasSize))
        let scene = VideoSceneSnapshot(layout: layout, background: background, foreground: nil, camera: .empty,
                                       cameraMotionBlur: 0, cursor: nil, keystrokes: [], keystrokeStyle: VideoKeystrokeStyle(),
                                       captions: [], captionStyle: VideoCaptionStyle(), webcam: nil)
        let composition = try VideoCompositionRendering.sceneComposition(asset: source, track: track,
            frameDuration: CMTime(value: 1, timescale: 30),
            timeMap: [.init(compStart: 0, compEnd: source.duration.seconds, sourceStart: 0, factor: 1)],
            scene: scene, censorSegments: [], textSnapshots: [])
        let output = directory.appendingPathComponent("framed.mp4")
        try await VideoTranscoder.export(.init(asset: source, videoTrack: track, audioTracks: [], composition: composition,
            timeRange: CMTimeRange(start: .zero, duration: source.duration), outputURL: output,
            videoSettings: VideoEncodingSettings.outputSettings(width: Int(layout.canvasSize.width),
                height: Int(layout.canvasSize.height), fps: 30, codec: .h264, quality: .high),
            decodedSize: nil, outputTransform: .identity))
        let result = AVURLAsset(url: output)
        let resultTrack = try XCTUnwrap(result.tracks(withMediaType: .video).first)
        XCTAssertEqual(resultTrack.naturalSize, layout.canvasSize)
        let generator = AVAssetImageGenerator(asset: result)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(value: 30, timescale: 30), actualTime: nil)
        let rep = NSBitmapImageRep(cgImage: image)
        let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(corner.blueComponent, 0.8)
        XCTAssertLessThan(corner.greenComponent, 0.2)
        let center = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(center.greenComponent, 0.5, "the recording fills the frame's center")
    }
}

/// Minimal thread-safe box for test callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
