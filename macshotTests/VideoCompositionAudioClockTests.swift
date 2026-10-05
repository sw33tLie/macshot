import AVFoundation
import XCTest

/// The editing timescale is inflated toward 1 GHz so edited video endpoints
/// stay exact, and the audio composition track used to inherit it. When a take
/// has a single audio track the export passes that track through instead of
/// mixing it, so the inflated clock reached the delivered file as the audio
/// `mdhd` timescale.
///
/// ffmpeg-family demuxers then measure the edit list's priming `media_time`
/// against the sample rate rather than the media timescale, so the skip
/// overshoots the track and every packet is discarded. The export is silent on
/// Discord, YouTube and in browsers while AVFoundation still plays it, which is
/// why the declared clock — not decodability under AVFoundation — is what these
/// tests assert.
final class VideoCompositionAudioClockTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    /// A system-audio take: one audio track, so the export passes it through.
    /// `RecordingMediaFixture.mixedMovie` records mic and system audio, and
    /// mixing two tracks re-encodes the result, which hides the bad clock.
    private func systemAudioOnlyMovie(frameCount: Int = 60) async throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let queue = DispatchQueue(label: "macshot.tests.system-audio-source")
        let writer = try MP4WriterSession.make(queue: queue, url: url, width: 64, height: 64, fps: 30,
                                               recordSystemAudio: true, recordMicAudio: false)
        let pixels = try RecordingMediaFixture.pixels(width: 64, height: 64)
        for tick in 0..<frameCount {
            let time = CMTime(value: Int64(4_800_000 + tick * 1600), timescale: 48_000)
            let system = try RecordingMediaFixture.audio(samples: 1600, pts: time,
                frequency: 880, phaseSample: tick * 1600, amplitude: 0.3, rightFrequency: 1320)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !queue.sync(execute: { writer.handleFrame(pixelBuffer: pixels, presentationTime: time) }) {
                if ProcessInfo.processInfo.systemUptime > deadline { throw CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            queue.sync { writer.handleSystemAudioSample(system) }
        }
        writer.requestStop(atSourceTime: CMTime(value: Int64(3000 + frameCount), timescale: 30))
        try await writer.finish()
        return url
    }

    private func build(_ source: AVAsset) throws -> VideoCompositionBuilder.Result {
        try VideoCompositionBuilder.build(asset: source,
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: source.duration.seconds,
                           compositionDuration: source.duration.seconds)], includeAudio: true)
    }

    func testAudioCompositionTracksKeepTheirSampleClock() async throws {
        let source = AVURLAsset(url: try await systemAudioOnlyMovie())
        let sourceAudio = source.tracks(withMediaType: .audio)
        XCTAssertEqual(sourceAudio.count, 1)

        let processed = try build(source)
        XCTAssertEqual(processed.audioTracks.count, sourceAudio.count)
        for (track, origin) in zip(processed.audioTracks, sourceAudio) {
            XCTAssertEqual(track.naturalTimeScale, origin.naturalTimeScale)
        }
        // Video still gets the high-resolution editing clock it needs.
        XCTAssertGreaterThan(processed.videoTrack.naturalTimeScale, processed.audioTracks[0].naturalTimeScale)
    }

    /// End to end through the writer the `.high` export preset uses.
    func testExportedAudioTrackCarriesASampleRateClock() async throws {
        let source = AVURLAsset(url: try await systemAudioOnlyMovie())
        let sourceAudio = try XCTUnwrap(source.tracks(withMediaType: .audio).first)
        let processed = try build(source)

        let videoTrack = try XCTUnwrap(processed.composition.tracks(withMediaType: .video).first)
        let layout = try XCTUnwrap(VideoRenderGeometry.layout(sourceSize: videoTrack.naturalSize,
            preferredTransform: videoTrack.preferredTransform, renderSize: CGSize(width: 64, height: 64)))
        let videoComposition = try VideoCompositionRendering.scaleComposition(track: videoTrack,
            renderSize: layout.renderSize, duration: processed.composition.duration,
            frameDuration: processed.frameDuration)

        let output = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let session = try XCTUnwrap(AVAssetExportSession(asset: processed.composition,
            presetName: AVAssetExportPresetHighestQuality))
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        await session.export()
        XCTAssertEqual(session.status, .completed, "\(String(describing: session.error))")

        let saved = AVURLAsset(url: output)
        let track = try XCTUnwrap(saved.tracks(withMediaType: .audio).first)
        XCTAssertEqual(track.naturalTimeScale, sourceAudio.naturalTimeScale)
    }
}
