import CoreGraphics
import XCTest

final class CursorTelemetryTests: XCTestCase {
    private let header = CursorTelemetry.Header(sourcePointSize: CGSize(width: 800, height: 600),
                                                pixelSize: CGSize(width: 1600, height: 1200), frameRate: 60,
                                                createdAt: Date(timeIntervalSince1970: 1_000),
                                                cursorHiddenInVideo: true, overlaysInTelemetry: true)

    private func encode(_ events: [CursorTelemetry.Event]) throws -> Data {
        var data = try CursorTelemetry.encodeHeader(header)
        for event in events { CursorTelemetry.encode(event, into: &data) }
        return data
    }

    private var sampleEvents: [CursorTelemetry.Event] {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        return [
            .shapeDefinition(.init(id: 1, hotspot: CGPoint(x: 5, y: 5), size: CGSize(width: 28, height: 40), png: png)),
            .start(time: 100),
            .shape(time: 100, id: 1),
            .move(time: 100.5, x: 0.1, y: 0.2),
            .button(time: 101, button: .left, down: true, x: 0.3, y: 0.4),
            .button(time: 101.1, button: .left, down: false, x: 0.3, y: 0.4),
            .key(time: 101.5, down: true, keyCode: 0, modifiers: KeystrokeTimeline.commandMask, characters: "a"),
            .key(time: 101.6, down: false, keyCode: 0, modifiers: 0, characters: "a"),
        ]
    }

    func testRoundTripPreservesEveryRecordType() throws {
        let decoded = try CursorTelemetry.decode(try encode(sampleEvents))
        XCTAssertEqual(decoded.header, header)
        XCTAssertEqual(decoded.events, sampleEvents)
    }

    func testEveryTruncationKeepsACompletePrefix() throws {
        let data = try encode(sampleEvents)
        let headerLength = try CursorTelemetry.encodeHeader(header).count
        var previousCount = 0
        for length in headerLength...data.count {
            let decoded = try CursorTelemetry.decode(data.prefix(length))
            XCTAssertGreaterThanOrEqual(decoded.events.count, previousCount, "events vanished at \(length)")
            XCTAssertEqual(Array(sampleEvents.prefix(decoded.events.count)), decoded.events)
            previousCount = decoded.events.count
        }
        XCTAssertEqual(previousCount, sampleEvents.count)
    }

    func testRejectsForeignOrDamagedHeaders() throws {
        XCTAssertThrowsError(try CursorTelemetry.decode(Data("NOPE".utf8)))
        var data = try encode([])
        data[4] = 99 // version
        XCTAssertThrowsError(try CursorTelemetry.decode(data)) { error in
            XCTAssertEqual(error as? CursorTelemetry.FormatError, .unsupportedVersion)
        }
        var huge = Data(CursorTelemetry.magic)
        huge.appendLE(CursorTelemetry.version)
        huge.appendLE(UInt32.max)
        XCTAssertThrowsError(try CursorTelemetry.decode(huge))
    }

    func testUnknownTagStopsReadingWithoutThrowing() throws {
        var data = try encode([.move(time: 1, x: 0.5, y: 0.5)])
        data.append(0xEE)
        data.append(contentsOf: [1, 2, 3])
        let decoded = try CursorTelemetry.decode(data)
        XCTAssertEqual(decoded.events, [.move(time: 1, x: 0.5, y: 0.5)])
    }

    func testMediaClockRemovesPausesAndAnchorsToFirstFrame() {
        let events: [CursorTelemetry.Event] = [
            .move(time: 90, x: 0, y: 0),          // long before the first frame → dropped
            .move(time: 99.8, x: 0, y: 0),        // just before the first frame → clamped to 0
            .start(time: 100),
            .move(time: 101, x: 0.1, y: 0.1),
            .pause(time: 102),
            .move(time: 103, x: 0.9, y: 0.9),     // while paused → dropped
            .resume(time: 110, pausedDuration: 8),
            .move(time: 111, x: 0.2, y: 0.2),
            .button(time: 112, button: .left, down: true, x: 0.2, y: 0.2),
            .button(time: 112.2, button: .left, down: false, x: 0.2, y: 0.2),
        ]
        let recording = CursorRecording(header: header, events: events)
        XCTAssertTrue(recording.hasStartAnchor)
        // Button records carry positions too (press at 4, release at 4.2).
        XCTAssertEqual(recording.times.count, 5)
        for (actual, expected) in zip(recording.times, [0, 1, 3, 4, 4.2]) { XCTAssertEqual(actual, expected, accuracy: 0.0001) }
        XCTAssertFalse(recording.xs.contains(0.9))
        XCTAssertEqual(recording.clicks.count, 1)
        XCTAssertEqual(recording.clicks[0].time, 4, accuracy: 0.0001)
        XCTAssertEqual(recording.clicks[0].upTime ?? 0, 4.2, accuracy: 0.0001)
    }

    func testMissingAnchorFallsBackToFirstSample() {
        let recording = CursorRecording(header: header, events: [.move(time: 50, x: 0.1, y: 0.1),
                                                                 .move(time: 51, x: 0.2, y: 0.2)])
        XCTAssertFalse(recording.hasStartAnchor)
        XCTAssertEqual(recording.times, [0, 1])
    }

    func testPositionInterpolatesAndShapesStep() {
        let recording = CursorRecording(header: header, events: [
            .start(time: 0), .shape(time: 0, id: 3), .move(time: 0, x: 0, y: 0), .move(time: 1, x: 1, y: 0.5),
            .shape(time: 2, id: 4),
        ])
        let p = recording.rawPosition(at: 0.5)
        XCTAssertEqual(p?.x ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(p?.y ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(recording.shapeID(at: 1.9), 3)
        XCTAssertEqual(recording.shapeID(at: 2.1), 4)
        XCTAssertEqual(recording.pixelsPerPoint, 2)
    }

    func testWriterStreamsReadableFileAndClosesIdempotently() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mstl")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try CursorTelemetryWriter(url: url, header: header)
        writer.append(.start(time: 10))
        for i in 0..<5000 {
            writer.append(.move(time: 10 + Double(i) / 120, x: Float(i % 100) / 100, y: 0.5))
        }
        // Readable mid-recording after a flush.
        writer.flush()
        XCTAssertEqual(CursorRecording.load(url: url)?.times.count, 5000)
        writer.append(.button(time: 60, button: .right, down: true, x: 0.5, y: 0.5))
        writer.close()
        writer.close()
        let recording = try XCTUnwrap(CursorRecording.load(url: url))
        XCTAssertEqual(recording.clicks.first?.button, .right)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testKeyTextIsBoundedWithoutSplittingCharacters() throws {
        let long = String(repeating: "é", count: 100)
        let decoded = try CursorTelemetry.decode(try encode([.key(time: 1, down: true, keyCode: 1, modifiers: 0,
                                                                  characters: long)]))
        guard case let .key(_, _, _, _, text)? = decoded.events.first else { return XCTFail("missing key") }
        XCTAssertLessThanOrEqual(text.utf8.count, CursorTelemetry.maxKeyTextBytes)
        XCTAssertTrue(text.allSatisfy { $0 == "é" })
    }

    func testGlobalRegionConvertsAppKitRectsToCoreGraphics() {
        let region = CursorTelemetryRecorder.globalRegion(forAppKitRect: NSRect(x: 10, y: 20, width: 100, height: 50))
        let primary = NSScreen.screens.first?.frame.height ?? 70
        XCTAssertEqual(region.minX, 10)
        XCTAssertEqual(region.minY, primary - 70)
        let n = CursorTelemetryRecorder.normalized(CGPoint(x: 60, y: region.minY + 25), origin: region.origin, size: region.size)
        XCTAssertEqual(n.0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(n.1, 0.5, accuracy: 0.0001)
    }
}

final class CursorMotionTests: XCTestCase {
    private func recording(_ samples: [(Double, Float, Float)], keys: [Double] = []) -> CursorRecording {
        var events: [CursorTelemetry.Event] = [.start(time: 0)]
        events += samples.map { .move(time: $0.0, x: $0.1, y: $0.2) }
        events += keys.map { .key(time: $0, down: true, keyCode: 0, modifiers: 0, characters: "a") }
        let header = CursorTelemetry.Header(sourcePointSize: CGSize(width: 100, height: 100),
                                            pixelSize: CGSize(width: 200, height: 200), frameRate: 30,
                                            cursorHiddenInVideo: true, overlaysInTelemetry: true)
        return CursorRecording(header: header, events: events)
    }

    func testZeroSmoothingFollowsRawSamples() {
        let rec = recording([(0, 0, 0), (1, 1, 1)])
        let track = CursorMotion.buildTrack(from: rec, smoothing: 0)
        XCTAssertTrue(track.xs.isEmpty)
        XCTAssertEqual(track.position(at: 0.25)?.x ?? -1, 0.25, accuracy: 0.0001)
    }

    func testSmoothingLagsThenSettlesWithoutOvershoot() {
        let rec = recording([(0, 0, 0), (0.01, 1, 0), (3, 1, 0)])
        let track = CursorMotion.buildTrack(from: rec, smoothing: 0.6)
        let early = track.position(at: 0.05)!.x
        XCTAssertLessThan(early, 0.9)
        var previous: CGFloat = 0
        for t in stride(from: 0.0, through: 3.0, by: 0.01) {
            let x = track.position(at: t)!.x
            XCTAssertLessThanOrEqual(x, 1.0001, "critically damped motion must not overshoot")
            XCTAssertGreaterThanOrEqual(x, previous - 0.0001, "motion toward the target is monotonic")
            previous = x
        }
        XCTAssertEqual(track.position(at: 3)!.x, 1, accuracy: 0.001)
    }

    func testTrackIsDeterministicAndQueryableAtAnyTime() {
        let samples = (0..<600).map { i in (Double(i) / 120, Float(sin(Double(i) / 30) * 0.4 + 0.5), Float(0.5)) }
        let a = CursorMotion.buildTrack(from: recording(samples), smoothing: 0.5)
        let b = CursorMotion.buildTrack(from: recording(samples), smoothing: 0.5)
        XCTAssertEqual(a.xs, b.xs)
        for t in [-5.0, 0, 2.5, 100] { XCTAssertNotNil(a.position(at: t)) }
    }

    func testIdleOpacityFadesAfterDelayAndReturnsOnMovement() {
        let rec = recording([(0, 0, 0), (0.1, 0.5, 0.5), (0.2, 0.6, 0.6), (6, 0.6, 0.6), (6.1, 0.8, 0.8)])
        let track = CursorMotion.buildTrack(from: rec, smoothing: 0)
        XCTAssertEqual(track.idleOpacity(at: 0.5, delay: 2), 1)
        XCTAssertEqual(track.idleOpacity(at: 4, delay: 2), 0)
        XCTAssertEqual(track.idleOpacity(at: 6.5, delay: 2), 1)
    }

    func testTypingHidesPointerUntilItMoves() {
        let rec = recording([(0, 0, 0), (0.1, 0.5, 0.5), (4, 0.5, 0.5), (4.1, 0.7, 0.7)], keys: [2])
        let track = CursorMotion.buildTrack(from: rec, smoothing: 0)
        XCTAssertEqual(CursorMotion.typingOpacity(at: 1, keyTimes: [2], track: track), 1)
        XCTAssertEqual(CursorMotion.typingOpacity(at: 3, keyTimes: [2], track: track), 0)
        XCTAssertEqual(CursorMotion.typingOpacity(at: 4.5, keyTimes: [2], track: track), 1)
    }

    func testClickEffectTiming() {
        let clicks = [CursorRecording.Click(time: 1, upTime: 1.1, button: .left, position: .zero)]
        XCTAssertNil(CursorClickEffect.activeClick(at: 0.9, clicks: clicks))
        XCTAssertEqual(CursorClickEffect.activeClick(at: 1.25, clicks: clicks)?.progress ?? -1, 0.5, accuracy: 0.001)
        XCTAssertNil(CursorClickEffect.activeClick(at: 1.6, clicks: clicks))
        XCTAssertLessThan(CursorClickEffect.pressScale(at: 1.05, clicks: clicks), 1)
        XCTAssertEqual(CursorClickEffect.pressScale(at: 3, clicks: clicks), 1)
    }
}

final class CameraPathTests: XCTestCase {
    private let layout = VideoSceneGeometry.layout(contentSize: CGSize(width: 1920, height: 1080),
                                                   crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                   frame: VideoFrameStyle())!

    private func zoom(_ start: Double, _ end: Double, level: CGFloat = 2, center: CGPoint = CGPoint(x: 0.5, y: 0.5),
                      follows: Bool = false) -> CameraPathBuilder.Zoom {
        CameraPathBuilder.Zoom(start: start, end: end, level: level, center: center, follows: follows,
                               rampIn: 0.8, rampOut: 0.8)
    }

    func testIdentityOutsideZoomsAndFullLevelOnPlateau() {
        let path = CameraPathBuilder.build(zooms: [zoom(2, 6)], layout: layout, cursor: nil, connect: true)
        XCTAssertTrue(path.state(at: 1).isIdentity)
        XCTAssertTrue(path.state(at: 7).isIdentity)
        XCTAssertEqual(path.state(at: 4).zoom, 2, accuracy: 0.001)
        let ramp = path.state(at: 2.4).zoom
        XCTAssertGreaterThan(ramp, 1)
        XCTAssertLessThan(ramp, 2)
    }

    func testFocusStaysInsideCanvasForEdgeTargets() {
        let path = CameraPathBuilder.build(zooms: [zoom(0, 5, level: 3, center: CGPoint(x: 0, y: 1))],
                                           layout: layout, cursor: nil, connect: true)
        for t in stride(from: 0.0, through: 5.0, by: 0.05) {
            let state = path.state(at: t)
            let visible = state.visibleRect
            XCTAssertGreaterThanOrEqual(visible.minX, -0.0001)
            XCTAssertLessThanOrEqual(visible.maxY, 1.0001)
        }
    }

    func testConnectedZoomsPanWithoutZoomingOut() {
        let zooms = [zoom(0, 3, center: CGPoint(x: 0.3, y: 0.3)), zoom(3.5, 6, center: CGPoint(x: 0.7, y: 0.7))]
        let connected = CameraPathBuilder.build(zooms: zooms, layout: layout, cursor: nil, connect: true)
        let separate = CameraPathBuilder.build(zooms: zooms, layout: layout, cursor: nil, connect: false)
        XCTAssertEqual(connected.state(at: 3.25).zoom, 2, accuracy: 0.01)
        XCTAssertLessThan(separate.state(at: 3.25).zoom, 1.01)
        XCTAssertEqual(connected.state(at: 5.5).focus.x, 0.7, accuracy: 0.03)
    }

    func testTouchingZoomsWithDifferentLevelsBlendSmoothly() {
        let path = CameraPathBuilder.build(zooms: [zoom(0, 3, level: 1.5), zoom(3, 6, level: 3)],
                                           layout: layout, cursor: nil, connect: true)
        var previous = path.state(at: 1).zoom
        for t in stride(from: 1.0, through: 5.0, by: 1.0 / 60) {
            let z = path.state(at: t).zoom
            XCTAssertLessThan(abs(z - previous), 0.1, "zoom jumped at \(t)")
            previous = z
        }
    }

    func testFollowingZoomKeepsThePointerInView() {
        let header = CursorTelemetry.Header(sourcePointSize: CGSize(width: 960, height: 540),
                                            pixelSize: CGSize(width: 1920, height: 1080), frameRate: 60,
                                            cursorHiddenInVideo: true, overlaysInTelemetry: true)
        // Pointer sweeps left to right over six seconds.
        var events: [CursorTelemetry.Event] = [.start(time: 0)]
        for i in 0...360 { events.append(.move(time: Double(i) / 60, x: Float(0.1 + 0.8 * Double(i) / 360), y: 0.5)) }
        let track = CursorMotion.buildTrack(from: CursorRecording(header: header, events: events), smoothing: 0.3)
        let path = CameraPathBuilder.build(zooms: [zoom(0, 6, level: 2.5, follows: true)], layout: layout,
                                           cursor: track, connect: true)
        for t in stride(from: 1.5, through: 5.0, by: 0.1) {
            let state = path.state(at: t)
            let p = layout.sceneNormalized(forContent: track.position(at: t)!)
            XCTAssertTrue(state.visibleRect.insetBy(dx: -0.02, dy: -0.02).contains(p), "pointer left view at \(t)")
        }
    }

    func testSmootherstepEndpoints() {
        XCTAssertEqual(CameraPathBuilder.smootherstep(0), 0)
        XCTAssertEqual(CameraPathBuilder.smootherstep(1), 1)
        XCTAssertEqual(CameraPathBuilder.smootherstep(0.5), 0.5, accuracy: 0.0001)
    }
}

final class AutoZoomPlannerTests: XCTestCase {
    private func recording(clicks: [(Double, CGFloat, CGFloat)]) -> CursorRecording {
        var events: [CursorTelemetry.Event] = [.start(time: 0)]
        for (t, x, y) in clicks {
            events.append(.button(time: t, button: .left, down: true, x: Float(x), y: Float(y)))
            events.append(.button(time: t + 0.1, button: .left, down: false, x: Float(x), y: Float(y)))
        }
        let header = CursorTelemetry.Header(sourcePointSize: CGSize(width: 100, height: 100),
                                            pixelSize: CGSize(width: 100, height: 100), frameRate: 30,
                                            cursorHiddenInVideo: true, overlaysInTelemetry: true)
        return CursorRecording(header: header, events: events)
    }

    func testClustersNearbyClicksAndSkipsOffscreenOnes() {
        let rec = recording(clicks: [(2, 0.5, 0.5), (3, 0.52, 0.5), (10, 0.2, 0.2), (15, 1.4, 0.5)])
        let suggestions = AutoZoomPlanner.suggestions(recording: rec, track: nil, range: 0...20, level: 2)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions[0].start, 2 - AutoZoomPlanner.leadIn, accuracy: 0.001)
        XCTAssertEqual(suggestions[0].end, 3 + AutoZoomPlanner.tail, accuracy: 0.001)
        XCTAssertEqual(suggestions[1].center.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(suggestions[1].center.y, 0.2, accuracy: 0.0001)
    }

    func testWideClustersZoomLessAndRespectOccupiedRanges() {
        let rec = recording(clicks: [(2, 0.1, 0.1), (3, 0.9, 0.9)])
        let wide = AutoZoomPlanner.suggestions(recording: rec, track: nil, range: 0...20, level: 2.5)
        XCTAssertEqual(wide.first?.level ?? 0, 1.25, accuracy: 0.001)
        XCTAssertTrue(AutoZoomPlanner.suggestions(recording: rec, track: nil, range: 0...20, level: 2,
                                                  avoiding: [1...5]).isEmpty)
        XCTAssertTrue(AutoZoomPlanner.suggestions(recording: rec, track: nil, range: 10...20, level: 2).isEmpty)
    }
}

final class VideoSceneGeometryTests: XCTestCase {
    private let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    func testWithoutFrameCanvasIsTheEvenContentSize() throws {
        let layout = try XCTUnwrap(VideoSceneGeometry.layout(contentSize: CGSize(width: 1001, height: 601),
                                                             crop: full, frame: VideoFrameStyle()))
        XCTAssertEqual(layout.canvasSize, CGSize(width: 1000, height: 600))
        XCTAssertEqual(layout.videoRect, CGRect(origin: .zero, size: layout.canvasSize))
        XCTAssertEqual(layout.cornerRadius, 0)
    }

    func testFramePaddingCentersTheRecording() throws {
        var frame = VideoFrameStyle()
        frame.enabled = true
        frame.padding = 0.1
        let layout = try XCTUnwrap(VideoSceneGeometry.layout(contentSize: CGSize(width: 1920, height: 1080),
                                                             crop: full, frame: frame))
        XCTAssertEqual(layout.canvasSize, CGSize(width: 2136, height: 1296))
        XCTAssertEqual(layout.videoRect.midX, layout.canvasSize.width / 2, accuracy: 0.5)
        XCTAssertEqual(layout.videoRect.midY, layout.canvasSize.height / 2, accuracy: 0.5)
        XCTAssertEqual(layout.contentScale, 1, accuracy: 0.001)
        XCTAssertGreaterThan(layout.cornerRadius, 0)
    }

    func testFixedAspectRatiosProduceThatShapeAndFitTheRecording() throws {
        for aspect in VideoAspectRatio.allCases where aspect != .auto {
            var frame = VideoFrameStyle()
            frame.aspect = aspect
            let layout = try XCTUnwrap(VideoSceneGeometry.layout(contentSize: CGSize(width: 1920, height: 1080),
                                                                 crop: full, frame: frame))
            XCTAssertEqual(layout.canvasSize.width / layout.canvasSize.height, aspect.ratio!, accuracy: 0.01)
            XCTAssertTrue(CGRect(origin: .zero, size: layout.canvasSize).insetBy(dx: -1, dy: -1).contains(layout.videoRect))
            XCTAssertLessThanOrEqual(max(layout.canvasSize.width, layout.canvasSize.height), VideoSceneGeometry.maxDimension)
        }
    }

    func testCropAndInverseMappingRoundTrip() throws {
        var frame = VideoFrameStyle()
        frame.enabled = true
        let crop = CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)
        let layout = try XCTUnwrap(VideoSceneGeometry.layout(contentSize: CGSize(width: 1000, height: 800),
                                                             crop: crop, frame: frame, scale: 0.5))
        for p in [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.45, y: 0.4), CGPoint(x: 0.7, y: 0.7)] {
            let back = layout.contentNormalized(forScene: layout.sceneNormalized(forContent: p))
            XCTAssertEqual(back.x, p.x, accuracy: 0.0001)
            XCTAssertEqual(back.y, p.y, accuracy: 0.0001)
        }
        let corner = layout.canvasPoint(forContent: CGPoint(x: 0.2, y: 0.1))
        XCTAssertEqual(corner.x, layout.videoRect.minX, accuracy: 0.001)
        XCTAssertEqual(corner.y, layout.videoRect.minY, accuracy: 0.001)
    }

    func testRejectsDegenerateInput() {
        XCTAssertNil(VideoSceneGeometry.layout(contentSize: CGSize(width: 0, height: 10), crop: full, frame: VideoFrameStyle()))
        XCTAssertNil(VideoSceneGeometry.layout(contentSize: CGSize(width: CGFloat.nan, height: 10), crop: full,
                                               frame: VideoFrameStyle()))
    }

    func testCameraTransformKeepsFocusCentered() {
        let state = CameraState(zoom: 2, focus: CGPoint(x: 0.25, y: 0.25))
        let size = CGSize(width: 1000, height: 500)
        let mapped = CGPoint(x: 250, y: 125).applying(state.transform(canvasSize: size))
        XCTAssertEqual(mapped.x, 500, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 250, accuracy: 0.001)
        // Flipping to Core Image coordinates maps the same point consistently.
        let ci = VideoSceneRenderer.coreImageTransform(state.transform(canvasSize: size), height: 500)
        let p = CGPoint(x: 250, y: 500 - 125).applying(ci)
        XCTAssertEqual(p.x, 500, accuracy: 0.001)
        XCTAssertEqual(p.y, 250, accuracy: 0.001)
    }
}

final class KeystrokeAndCaptionTimelineTests: XCTestCase {
    private func key(_ t: Double, _ c: String, _ mods: UInt32 = 0) -> CursorRecording.Key {
        CursorRecording.Key(time: t, keyCode: 0, modifiers: mods, characters: c)
    }

    func testShortcutsStandAloneAndTypingAccumulates() {
        let labels = KeystrokeTimeline.labels(from: [key(0, "h"), key(0.2, "i"), key(0.4, "Space"), key(0.6, "x"),
                                                     key(1, "s", KeystrokeTimeline.commandMask | KeystrokeTimeline.shiftMask)],
                                              shortcutsOnly: false)
        XCTAssertEqual(labels.map(\.text), ["h", "hi", "hi ", "hi x", "⇧ ⌘ S"], "typing grows key by key")
        XCTAssertEqual(labels[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(labels[3].end, 1, accuracy: 0.0001, "a new label replaces the previous one")
    }

    func testShortcutsOnlyHidesTyping() {
        let labels = KeystrokeTimeline.labels(from: [key(0, "h"), key(1, "↩"), key(2, "c", KeystrokeTimeline.commandMask)],
                                              shortcutsOnly: true)
        XCTAssertEqual(labels.map(\.text), ["⌘ C"])
    }

    func testActiveLabelFades() {
        let labels = [KeystrokeTimeline.Label(start: 1, end: 2, text: "⌘ C")]
        XCTAssertNil(KeystrokeTimeline.active(at: 0.5, in: labels))
        XCTAssertEqual(KeystrokeTimeline.active(at: 1.5, in: labels)?.1 ?? 0, 1)
        XCTAssertLessThan(KeystrokeTimeline.active(at: 1.95, in: labels)?.1 ?? 1, 1)
    }

    func testCaptionSegmentationAndSubRip() {
        let words = ["Hello", "there.", "This", "is", "a", "long", "caption", "line"].enumerated().map { i, w in
            CaptionTimeline.Word(text: w, start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.3)
        }
        let segments = CaptionTimeline.segments(from: words, maxWords: 4)
        XCTAssertEqual(segments.map(\.text), ["Hello there.", "This is a long", "caption line"])
        let srt = CaptionTimeline.srt(segments) { $0 }
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:00,700\nHello there.\n"))
        XCTAssertTrue(srt.contains("3\n"))
    }
}

final class VideoProjectPersistenceTests: XCTestCase {
    func testRoundTripKeepsSegmentsAndLook() throws {
        var look = VideoLook()
        look.frame.enabled = true
        look.frame.aspect = .square
        look.cursor.size = 2
        let project = VideoProject(sourceDuration: 30, look: look)
        project.trimStart = 1
        project.zooms = [VideoZoomSegment(startTime: 2, endTime: 5, zoomLevel: 2.5, followsCursor: true, isAutomatic: true)]
        project.cuts = [VideoCutSegment(startTime: 8, endTime: 9)]
        project.texts = [VideoTextSegment(startTime: 3, endTime: 4, text: "Hi")]
        project.captions = [VideoCaptionSegment(startTime: 1, endTime: 2, text: "Hello")]
        let copy = try XCTUnwrap(project.copy())
        XCTAssertEqual(copy.encoded(), project.encoded())
        XCTAssertTrue(copy.zooms[0].followsCursor)
        XCTAssertEqual(copy.look, look)
        XCTAssertTrue(copy.hasEdits)
    }

    func testMissingKeysAndCorruptSegmentsDecodeLeniently() throws {
        let json = """
        {"sourceDuration": 20, "trimEnd": 50, "look": {"frame": {"padding": 9, "aspect": "nonsense"}},
         "zooms": [{"startTime": 1, "endTime": 3, "zoomLevel": 99}, "garbage", {"startTime": 30, "endTime": 40}],
         "cuts": [{"id": "not-a-uuid", "startTime": 4, "endTime": 5}]}
        """
        let project = try XCTUnwrap(VideoProject.decode(Data(json.utf8)))
        XCTAssertEqual(project.trimEnd, 20)
        XCTAssertEqual(project.look.frame.padding, VideoFrameStyle.paddingRange.upperBound)
        XCTAssertEqual(project.look.frame.aspect, .auto)
        XCTAssertEqual(project.zooms.count, 1, "the corrupt entry and the out-of-range zoom are dropped")
        XCTAssertEqual(project.zooms[0].zoomLevel, VideoZoomSegment.maxZoom)
        XCTAssertFalse(project.zooms[0].followsCursor)
        XCTAssertEqual(project.cuts.count, 1)
        XCTAssertNil(VideoProject.decode(Data("{}".utf8)), "a project without a source duration is unusable")
    }

    func testRememberedLookRoundTrips() {
        withDefaults([VideoLook.defaultsKey: nil]) {
            XCTAssertNil(VideoLook.remembered())
            var look = VideoLook.recordingDefault
            look.zoom.defaultLevel = 2.2
            look.remember()
            XCTAssertEqual(VideoLook.remembered(), look)
        }
    }

    func testUntouchedProjectHasNoEdits() {
        XCTAssertFalse(VideoProject(sourceDuration: 10, look: VideoLook()).hasEdits)
        XCTAssertTrue(VideoProject(sourceDuration: 10, look: VideoLook.recordingDefault).hasEdits)
    }
}

final class PointerSamplerTests: XCTestCase {
    func testStationaryPollsWriteNothingAndPausesGetAHoldSample() {
        var sampler = PointerSampler()
        let up = [false, false, false]
        XCTAssertEqual(sampler.sample(time: 0, x: 0.1, y: 0.1, buttons: up), [.move(time: 0, x: 0.1, y: 0.1)])
        XCTAssertEqual(sampler.sample(time: 0.008, x: 0.1, y: 0.1, buttons: up), [], "stationary poll")
        // Moving again ten seconds later first records where it rested.
        let resumed = sampler.sample(time: 10, x: 0.5, y: 0.5, buttons: up)
        XCTAssertEqual(resumed, [.move(time: 10 - PointerSampler.sampleInterval, x: 0.1, y: 0.1),
                                 .move(time: 10, x: 0.5, y: 0.5)])
        // Continuous motion needs no extra samples.
        XCTAssertEqual(sampler.sample(time: 10.008, x: 0.6, y: 0.5, buttons: up), [.move(time: 10.008, x: 0.6, y: 0.5)])
        let pressed = sampler.sample(time: 10.016, x: 0.6, y: 0.5, buttons: [true, false, false])
        XCTAssertEqual(pressed, [.button(time: 10.016, button: .left, down: true, x: 0.6, y: 0.5)])
    }

    func testHoldSamplesKeepThePointerStillAndIdleHidingWorking() {
        var sampler = PointerSampler()
        var events: [CursorTelemetry.Event] = [.start(time: 0)]
        for t in stride(from: 0.0, through: 1, by: 0.008) { events += sampler.sample(time: t, x: Float(t) * 0.2, y: 0.5, buttons: [false, false, false]) }
        for t in stride(from: 1.008, through: 11, by: 0.008) { events += sampler.sample(time: t, x: 0.2, y: 0.5, buttons: [false, false, false]) }
        events += sampler.sample(time: 11.008, x: 0.8, y: 0.5, buttons: [false, false, false])
        let header = CursorTelemetry.Header(sourcePointSize: CGSize(width: 100, height: 100), pixelSize: CGSize(width: 100, height: 100),
                                            frameRate: 30, cursorHiddenInVideo: true, overlaysInTelemetry: true)
        let track = CursorMotion.buildTrack(from: CursorRecording(header: header, events: events), smoothing: 0)
        XCTAssertEqual(track.position(at: 6)?.x ?? 0, 0.2, accuracy: 0.001, "no drift while resting")
        XCTAssertEqual(track.idleOpacity(at: 8, delay: 2), 0, "idle hiding sees the pause")
    }
}

final class CaptionOrderingTests: XCTestCase {
    func testActiveCaptionIgnoresArrayOrder() {
        let late = VideoCaptionSegment(startTime: 5, endTime: 7, text: "late")
        let early = VideoCaptionSegment(startTime: 1, endTime: 3, text: "early")
        XCTAssertEqual(CaptionTimeline.active(at: 2, in: [early, late])?.0.text, "early")
        XCTAssertEqual(CaptionTimeline.active(at: 6, in: [late, early].sorted { $0.startTime < $1.startTime })?.0.text, "late")
        let srt = CaptionTimeline.srt([late, early]) { $0 }
        XCTAssertLessThan(srt.range(of: "early")!.lowerBound, srt.range(of: "late")!.lowerBound)
    }
}

final class KeystrokeFadeTests: XCTestCase {
    func testTypingContinuationsDoNotFlicker() {
        let labels = [KeystrokeTimeline.Label(start: 0, end: 0.2, text: "h"),
                      KeystrokeTimeline.Label(start: 0.2, end: 1.6, text: "hi")]
        XCTAssertEqual(KeystrokeTimeline.active(at: 0.21, in: labels)?.1 ?? 0, 1, "continuation shows at full opacity")
        XCTAssertLessThan(KeystrokeTimeline.active(at: 0.02, in: labels)?.1 ?? 1, 1, "the first label still fades in")
    }
}

final class CursorSwayTests: XCTestCase {
    func testPointerTiltsAgainstItsMotionAndRestsUpright() {
        let header = CursorTelemetry.Header(sourcePointSize: CGSize(width: 100, height: 100), pixelSize: CGSize(width: 100, height: 100),
                                            frameRate: 30, cursorHiddenInVideo: true, overlaysInTelemetry: true)
        var events: [CursorTelemetry.Event] = [.start(time: 0)]
        for i in 0...60 { events.append(.move(time: Double(i) / 60, x: Float(i) / 60, y: 0.5)) }
        events.append(.move(time: 3, x: 1, y: 0.5))
        let track = CursorMotion.buildTrack(from: CursorRecording(header: header, events: events), smoothing: 0)
        let moving = CursorSway.angle(at: 0.5, track: track, amount: 1, aspect: 1)
        XCTAssertLessThan(moving, -0.05, "moving right tilts clockwise")
        XCTAssertGreaterThanOrEqual(moving, -CursorSway.maxAngle)
        XCTAssertEqual(CursorSway.angle(at: 2.5, track: track, amount: 1, aspect: 1), 0, accuracy: 0.001, "upright at rest")
        XCTAssertEqual(CursorSway.angle(at: 0.5, track: track, amount: 0, aspect: 1), 0, "off by default")
    }
}
