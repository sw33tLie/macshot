import AVFoundation
import XCTest

@MainActor
final class VideoEffectSnapshotTests: XCTestCase {
    func testInstructionDoesNotChangeWhenEditorSegmentsAreMutated() {
        let zoom = VideoZoomSegment(startTime: 1, endTime: 5, zoomLevel: 3,
                                    center: CGPoint(x: 0.3, y: 0.7), fadeIn: 0.2, fadeOut: 0.4)
        let censor = VideoCensorSegment(startTime: 2, endTime: 4,
                                        rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                                        style: .solid, fadeIn: 0.1, fadeOut: 0.2)
        let instruction = EffectsCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 6, preferredTimescale: 600)),
            videoTrackID: 1, naturalSize: CGSize(width: 640, height: 480),
            renderSize: CGSize(width: 640, height: 480), baseTransform: .identity, timeMap: [],
            zoomSegments: [VideoZoomSnapshot(zoom)], censorSegments: [VideoCensorSnapshot(censor)])
        let zoomID = zoom.id, censorID = censor.id
        zoom.id = UUID(); zoom.startTime = 10; zoom.endTime = 12; zoom.zoomLevel = 5
        zoom.center = .zero; zoom.fadeIn = 1; zoom.fadeOut = 1
        censor.id = UUID(); censor.startTime = 20; censor.endTime = 22; censor.rect = .zero
        censor.style = .blur; censor.fadeIn = 1; censor.fadeOut = 1
        let z = instruction.zoomSegments[0], c = instruction.censorSegments[0]
        XCTAssertEqual(z.id, zoomID)
        XCTAssertEqual(z.startTime, 1); XCTAssertEqual(z.endTime, 5)
        XCTAssertEqual(z.zoomLevel, 3); XCTAssertEqual(z.center, CGPoint(x: 0.3, y: 0.7))
        XCTAssertEqual(z.fadeIn, 0.2); XCTAssertEqual(z.fadeOut, 0.4)
        XCTAssertEqual(z.zoomLevel(at: 2), 3)
        XCTAssertEqual(c.id, censorID)
        XCTAssertEqual(c.startTime, 2); XCTAssertEqual(c.endTime, 4)
        XCTAssertEqual(c.rect, CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(c.style, .solid)
        XCTAssertEqual(c.fadeIn, 0.1); XCTAssertEqual(c.fadeOut, 0.2)
        XCTAssertEqual(c.opacity(at: 3), 1)
    }

    func testNewCensorsCoverBothIntervalEdgesEvenWhenShort() {
        for duration in [0.001, 0.3, 2, 28_800] {
            let censor = VideoCensorSegment(startTime: 2, endTime: 2 + duration, style: .solid)
            XCTAssertEqual(VideoCensorSegment.autoFade(for: duration), 0)
            let snapshot = VideoCensorSnapshot(censor)
            for time in [2, 2 + duration / 2, 2 + duration] {
                XCTAssertEqual(censor.opacity(at: time), 1)
                XCTAssertEqual(snapshot.opacity(at: time), 1)
            }
            XCTAssertEqual(snapshot.opacity(at: 1.9999), 0)
            XCTAssertEqual(snapshot.opacity(at: 2 + duration + 0.0001), 0)
        }
    }

    func testExplicitCensorFadesSurvivePersistenceAndMatchTheRenderer() throws {
        let original = VideoCensorSegment(startTime: 1, endTime: 5, fadeIn: 0.5, fadeOut: 1)
        let restored = try JSONDecoder().decode(VideoCensorSegment.self, from: JSONEncoder().encode(original))
        let snapshot = VideoCensorSnapshot(restored)
        for (time, opacity): (Double, CGFloat) in [(0, 0), (1, 0), (1.25, 0.5), (2, 1), (4.5, 0.5), (5, 0), (6, 0)] {
            XCTAssertEqual(restored.opacity(at: time), opacity, accuracy: 0.00001)
            XCTAssertEqual(snapshot.opacity(at: time), opacity, accuracy: 0.00001)
        }
    }

    func testInvalidTimingDoesNotProduceNonfiniteOpacity() {
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(VideoEffectTiming.opacity(at: time, start: 0, end: 1, fadeIn: 0, fadeOut: 0), 0)
        }
        XCTAssertEqual(VideoEffectTiming.opacity(at: 0.5, start: 0, end: 1,
                                                 fadeIn: .nan, fadeOut: .infinity), 1)
        XCTAssertEqual(VideoEffectTiming.opacity(at: 1, start: 1, end: 1, fadeIn: 0, fadeOut: 0), 0)
    }
}
