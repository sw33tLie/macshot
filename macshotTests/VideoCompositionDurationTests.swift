import AppKit
import AVFoundation
import XCTest

@MainActor
final class VideoCompositionDurationTests: XCTestCase {
    func testFractionalSecondRecordingRendersEffectsAndExportsThroughItsLastFrame() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await RecordingMediaFixture.mixedMovie(in: directory, frameCount: 31)
        let source = AVURLAsset(url: url)
        let processed = try VideoCompositionBuilder.build(asset: source,
            pieces: [.init(kind: .normal, srcStart: 0, srcEnd: source.duration.seconds,
                           compositionDuration: source.duration.seconds)], includeAudio: false)

        // Preview uses the source asset; export uses the processed timeline.
        // 31/30 cannot be represented exactly on a nanosecond clock.
        for asset: AVAsset in [source, processed.composition] {
            let rounded = CMTime(seconds: asset.duration.seconds, preferredTimescale: 1_000_000_000)
            XCTAssertLessThan(CMTimeCompare(rounded, asset.duration), 0)
            let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
            let cadence = CMTime(value: 1, timescale: 30)
            let layout = try XCTUnwrap(VideoRenderGeometry.layout(sourceSize: track.naturalSize,
                preferredTransform: track.preferredTransform, renderSize: CGSize(width: 32, height: 32)))
            let censor = VideoCensorSegment(startTime: 0, endTime: asset.duration.seconds,
                rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), style: .solid)
            let effects = VideoCompositionRendering.effectsComposition(asset: asset, track: track,
                layout: layout, frameDuration: cadence,
                timeMap: [.init(compStart: 0, compEnd: asset.duration.seconds, sourceStart: 0, factor: 1)],
                zoomSegments: [], censorSegments: [VideoCensorSnapshot(censor)])
            let scale = try VideoCompositionRendering.scaleComposition(track: track,
                renderSize: layout.renderSize, duration: asset.duration, frameDuration: cadence)

            for (composition, censored) in [(effects, true), (scale, false)] {
                XCTAssertTrue(isValid(composition, for: asset))
                let generator = AVAssetImageGenerator(asset: asset)
                generator.videoComposition = composition
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                for time in [CMTime.zero, CMTime(value: 1, timescale: 1)] {
                    let image = try generator.copyCGImage(at: time, actualTime: nil)
                    try checkFrame(image, censored: censored)
                }

                let output = directory.appendingPathComponent(UUID().uuidString + ".mp4")
                let session = try XCTUnwrap(AVAssetExportSession(asset: asset,
                    presetName: AVAssetExportPresetHighestQuality))
                session.outputURL = output
                session.outputFileType = .mp4
                session.videoComposition = composition
                await session.export()
                XCTAssertEqual(session.status, .completed, "\(String(describing: session.error))")
                let saved = AVURLAsset(url: output)
                XCTAssertEqual(saved.duration.seconds, asset.duration.seconds, accuracy: 1.0 / 600)
                let image = try AVAssetImageGenerator(asset: saved).copyCGImage(at: CMTime(value: 1, timescale: 1), actualTime: nil)
                try checkFrame(image, censored: censored)
            }
        }
    }

    private func isValid(_ composition: AVVideoComposition, for asset: AVAsset) -> Bool {
        composition.isValid(for: asset, timeRange: CMTimeRange(start: .zero, duration: asset.duration), validationDelegate: nil)
    }

    private func checkFrame(_ image: CGImage, censored: Bool) throws {
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 32)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let left = try XCTUnwrap(bitmap.colorAt(x: 8, y: 16))
        let right = try XCTUnwrap(bitmap.colorAt(x: 24, y: 16))
        if censored {
            XCTAssertLessThan(max(left.redComponent, left.greenComponent, left.blueComponent), 0.04)
        } else {
            XCTAssertGreaterThan(left.greenComponent, 0.4)
        }
        XCTAssertGreaterThan(right.greenComponent, 0.4)
    }
}
