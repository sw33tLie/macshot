import CoreGraphics
import XCTest

/// Moving and resizing the webcam bubble during a take is replayed by the
/// editor (#425): the placement track, its file format and the bubble rect.
final class CameraPlacementTrackTests: XCTestCase {
    private typealias Sample = CameraPlacementTrack.Sample

    private func sample(_ t: Double, _ x: Double, _ y: Double, _ s: Double = 0.2) -> Sample {
        Sample(time: t, centerX: x, centerY: y, size: s)
    }

    func testNormalizesAScreenFrameToTopLeftRecordingSpace() throws {
        let bounds = CGRect(x: 100, y: 200, width: 1000, height: 500)
        // Bottom-left corner slot of the recorded area, 100 pt bubble.
        let frame = CGRect(x: 112, y: 212, width: 100, height: 100)
        let s = try XCTUnwrap(Sample.normalized(frame: frame, in: bounds, time: 1))
        XCTAssertEqual(s.centerX, 0.062, accuracy: 1e-9)
        XCTAssertEqual(s.centerY, 0.876, accuracy: 1e-9, "y is measured from the top")
        XCTAssertEqual(s.size, 0.2, accuracy: 1e-9, "side relative to the shorter side")
        XCTAssertNil(Sample.normalized(frame: frame, in: .zero, time: 0))
    }

    func testInitSortsDeduplicatesClampsAndDropsInvalidSamples() {
        let track = CameraPlacementTrack(samples: [
            sample(2, 0.5, 0.5),
            sample(1, 1.5, -0.2, 3),
            sample(.nan, 0.5, 0.5),
            sample(-1, 0.5, 0.5),
            sample(2, 0.7, 0.7),
            sample(3, 0.5, 0.5, 0),
        ])
        XCTAssertEqual(track.samples.map(\.time), [1, 2])
        XCTAssertEqual(track.samples[0], sample(1, 1, 0, 1))
        XCTAssertEqual(track.samples[1].centerX, 0.7, "the later of equal times wins")
    }

    func testHoldsBetweenSeparateMovesAndInterpolatesWithinADrag() throws {
        let track = CameraPlacementTrack(samples: [
            sample(0, 0.9, 0.9),
            // A drag 10 s later: the bubble must not glide from t = 0.
            sample(10, 0.8, 0.8),
            sample(10.1, 0.6, 0.6, 0.4),
        ])
        XCTAssertEqual(track.sample(at: -1)?.centerX, 0.9)
        XCTAssertEqual(track.sample(at: 5)?.centerX, 0.9)
        XCTAssertEqual(track.sample(at: 9.99)?.centerX, 0.9)
        let mid = try XCTUnwrap(track.sample(at: 10.05))
        XCTAssertEqual(mid.centerX, 0.7, accuracy: 1e-9)
        XCTAssertEqual(mid.size, 0.3, accuracy: 1e-9)
        XCTAssertEqual(track.sample(at: 60)?.centerX, 0.6)
        XCTAssertNil(CameraPlacementTrack(samples: []).sample(at: 0))
    }

    func testFileRoundTripsAndSalvagesDamagedEntries() throws {
        let track = CameraPlacementTrack(samples: [sample(0, 0.1, 0.2), sample(1, 0.3, 0.4)])
        let data = try XCTUnwrap(track.encoded())
        XCTAssertEqual(CameraPlacementTrack.decode(data), track)

        let damaged = Data(#"[{"t":0,"x":0.1,"y":0.2,"s":0.2}, "junk", {"t":1,"x":0.3}]"#.utf8)
        let salvaged = try XCTUnwrap(CameraPlacementTrack.decode(damaged))
        XCTAssertEqual(salvaged.samples.count, 2)
        XCTAssertEqual(salvaged.samples[1].centerY, 0.5, "missing fields fall back to defaults")
        XCTAssertNil(CameraPlacementTrack.decode(Data("{}".utf8)))
        XCTAssertNil(CameraPlacementTrack.decode(Data("[]".utf8)))
    }

    func testCameraStyleDecodesOlderProjectsWithoutFollowing() throws {
        let old = Data(#"{"show":true,"shape":"circle","size":0.3,"position":"topLeft"}"#.utf8)
        let style = try JSONDecoder().decode(VideoCameraStyle.self, from: old)
        XCTAssertFalse(style.followsRecording)
        XCTAssertEqual(style.position, .topLeft)

        var following = VideoCameraStyle()
        following.followsRecording = true
        let decoded = try JSONDecoder().decode(VideoCameraStyle.self, from: JSONEncoder().encode(following))
        XCTAssertTrue(decoded.followsRecording)
    }

    // MARK: Bubble rect

    /// 1000×500 recording drawn at 2x across a 2000×1000 canvas.
    private let layout = VideoSceneLayout(contentSize: CGSize(width: 1000, height: 500),
                                          crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                          canvasSize: CGSize(width: 2000, height: 1000),
                                          videoRect: CGRect(x: 0, y: 0, width: 2000, height: 1000),
                                          cornerRadius: 0, drawsBackground: false)

    func testFollowingStylePlacesTheBubbleWhereItWasRecorded() {
        var style = VideoCameraStyle()
        style.followsRecording = true
        style.shrinkOnZoom = false
        let track = CameraPlacementTrack(samples: [sample(0, 0.5, 0.5), sample(5, 0, 0, 0.1)])

        let centered = VideoSceneRenderer.webcamRect(style: style, placement: track, layout: layout, zoom: 1, time: 1)
        XCTAssertEqual(centered, CGRect(x: 900, y: 400, width: 200, height: 200))

        // Top-left corner (top-left space) is clamped inside the canvas and
        // returned bottom-left, like every Core Image rect.
        let corner = VideoSceneRenderer.webcamRect(style: style, placement: track, layout: layout, zoom: 1, time: 6)
        XCTAssertEqual(corner, CGRect(x: 0, y: 900, width: 100, height: 100))
    }

    func testFixedStyleIgnoresTheRecordedPlacement() {
        var style = VideoCameraStyle()
        style.shrinkOnZoom = false
        let track = CameraPlacementTrack(samples: [sample(0, 0.5, 0.5)])
        let fixed = VideoSceneRenderer.webcamRect(style: style, placement: track, layout: layout, zoom: 1, time: 0)
        let none = VideoSceneRenderer.webcamRect(style: style, placement: nil, layout: layout, zoom: 1, time: 0)
        XCTAssertEqual(fixed, none)
        XCTAssertGreaterThan(fixed.minX, 1000, "bottom-right by default")

        // Following without a track falls back to the fixed placement.
        style.followsRecording = true
        XCTAssertEqual(VideoSceneRenderer.webcamRect(style: style, placement: nil, layout: layout, zoom: 1, time: 0), none)
    }

    func testFollowingBubbleShrinksAroundItsCenterDuringZooms() {
        var style = VideoCameraStyle()
        style.followsRecording = true
        let track = CameraPlacementTrack(samples: [sample(0, 0.5, 0.5)])
        let zoomed = VideoSceneRenderer.webcamRect(style: style, placement: track, layout: layout, zoom: 1.8, time: 0)
        XCTAssertEqual(zoomed.width, 130, accuracy: 1e-6)
        XCTAssertEqual(zoomed.midX, 1000, accuracy: 1e-6)
        XCTAssertEqual(zoomed.midY, 500, accuracy: 1e-6)
    }
}
