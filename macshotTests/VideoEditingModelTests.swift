import CoreGraphics
import XCTest

/// Trimming and cutting rebuild the video's timeline. An off-by-one here shows
/// up as a clip that plays the wrong moment, or an export that silently loses
/// the end of the recording.
final class VideoCutSegmentTests: XCTestCase {

    private func cut(_ start: Double, _ end: Double) -> VideoCutSegment {
        VideoCutSegment(startTime: start, endTime: end)
    }

    private func ranges(_ kept: [(Double, Double)]) -> [[Double]] {
        kept.map { [$0.0, $0.1] }
    }

    // MARK: - Kept ranges

    func testNoCutsKeepsTheWholeTrimRange() {
        let kept = VideoCuts.keptRanges(trimStart: 2, trimEnd: 10, cuts: [])
        XCTAssertEqual(ranges(kept), [[2, 10]])
    }

    func testACutInTheMiddleSplitsTheTimeline() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 10, cuts: [cut(4, 6)])
        XCTAssertEqual(ranges(kept), [[0, 4], [6, 10]])
    }

    func testOverlappingCutsMergeInsteadOfDoubleCounting() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 10, cuts: [cut(2, 5), cut(4, 7)])
        XCTAssertEqual(ranges(kept), [[0, 2], [7, 10]])
    }

    func testTouchingCutsAreTreatedAsOne() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 10, cuts: [cut(2, 4), cut(4, 6)])
        XCTAssertEqual(ranges(kept), [[0, 2], [6, 10]])
    }

    func testCutsAreClippedToTheTrimRange() {
        let kept = VideoCuts.keptRanges(trimStart: 3, trimEnd: 8, cuts: [cut(0, 4), cut(7, 20)])
        XCTAssertEqual(ranges(kept), [[4, 7]])
    }

    func testCutsOutsideTheTrimRangeChangeNothing() {
        let kept = VideoCuts.keptRanges(trimStart: 3, trimEnd: 8, cuts: [cut(0, 1), cut(9, 12)])
        XCTAssertEqual(ranges(kept), [[3, 8]])
    }

    func testCuttingEverythingLeavesNothing() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 10, cuts: [cut(0, 10)])
        XCTAssertTrue(kept.isEmpty, "an export with no footage should produce no ranges, not a negative one")
    }

    func testUnorderedCutsAreSortedFirst() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 10, cuts: [cut(7, 8), cut(2, 3)])
        XCTAssertEqual(ranges(kept), [[0, 2], [3, 7], [8, 10]])
    }

    func testZeroLengthCutsAreIgnored() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 10, cuts: [cut(5, 5), cut(3, 3)])
        XCTAssertEqual(ranges(kept), [[0, 10]])
    }

    func testInvertedTrimRangeProducesNothing() {
        XCTAssertTrue(VideoCuts.keptRanges(trimStart: 10, trimEnd: 2, cuts: []).isEmpty)
        XCTAssertTrue(VideoCuts.keptRanges(trimStart: 5, trimEnd: 5, cuts: []).isEmpty)
    }

    // MARK: - Time map

    func testTheTimeMapPlaysKeptRangesBackToBack() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 10, cuts: [cut(4, 6)])
        let map = VideoCuts.timeMap(for: kept)
        XCTAssertEqual(map.count, 2)

        // Output second 0 is source second 0.
        XCTAssertEqual(map[0].0, 0)
        XCTAssertEqual(map[0].2, 0)
        // Output second 4 continues at source second 6 — the cut is skipped.
        XCTAssertEqual(map[1].0, 4)
        XCTAssertEqual(map[1].0 + map[1].2, 6, "playback must resume after the cut, not repeat it")
    }

    func testTheTimeMapHasNoGapsOrOverlaps() {
        let kept = VideoCuts.keptRanges(trimStart: 1, trimEnd: 20, cuts: [cut(3, 5), cut(9, 11), cut(15, 16)])
        let map = VideoCuts.timeMap(for: kept)
        for (index, entry) in map.enumerated() where index > 0 {
            XCTAssertEqual(entry.0, map[index - 1].1, accuracy: 0.0001,
                           "output timeline must be continuous")
        }
        let total: Double = VideoCuts.totalDuration(for: kept)
        XCTAssertEqual(map.last?.1 ?? 0, total, accuracy: 0.0001)
    }

    func testEveryOutputSecondMapsBackIntoAKeptRange() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 30, cuts: [cut(5, 10), cut(20, 22)])
        let map = VideoCuts.timeMap(for: kept)

        let total: Double = VideoCuts.totalDuration(for: kept)
        for outputTime in stride(from: 0.0, to: total, by: 0.5) {
            guard let entry = map.first(where: { outputTime >= $0.0 && outputTime < $0.1 }) else {
                return XCTFail("output time \(outputTime) maps to nothing")
            }
            let sourceTime = outputTime + entry.2
            let insideAKeptRange = kept.contains { range -> Bool in
                let (start, end): (Double, Double) = range
                return sourceTime >= start - 0.001 && sourceTime <= end + 0.001
            }
            XCTAssertTrue(insideAKeptRange, "output \(outputTime)s resolves to cut-out source time \(sourceTime)s")
        }
    }

    func testTotalDurationIsTheSumOfWhatIsKept() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 10, cuts: [cut(2, 3), cut(7, 9)])
        let total: Double = VideoCuts.totalDuration(for: kept)
        XCTAssertEqual(total, 7, accuracy: 0.0001)
        let empty: Double = VideoCuts.totalDuration(for: [])
        XCTAssertEqual(empty, 0)
    }

    func testOverlapIgnoresTouchingEdges() {
        let segment = cut(5, 10)
        XCTAssertTrue(segment.overlaps(startTime: 4, endTime: 6))
        XCTAssertFalse(segment.overlaps(startTime: 10, endTime: 12), "a cut ending where another starts doesn't overlap")
        XCTAssertFalse(segment.overlaps(startTime: 0, endTime: 5))
    }
}

/// Zoom segments animate a scale and a pan. The clamping is what keeps the
/// zoomed view inside the frame — without it the export shows black edges, or
/// zooms somewhere other than where the user drew.
final class VideoZoomSegmentTests: XCTestCase {

    private func segment(start: Double = 0, end: Double = 4, zoom: CGFloat = 2,
                         center: CGPoint = CGPoint(x: 0.5, y: 0.5),
                         fadeIn: Double = 1, fadeOut: Double = 1) -> VideoZoomSegment {
        VideoZoomSegment(startTime: start, endTime: end, zoomLevel: zoom,
                         center: center, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    // MARK: - Zoom curve

    func testZoomIsNeutralOutsideTheSegment() {
        let zoom = segment()
        XCTAssertEqual(zoom.zoomLevel(at: -1), 1.0)
        XCTAssertEqual(zoom.zoomLevel(at: 99), 1.0)
    }

    func testZoomReachesItsFullLevelOnThePlateau() {
        let zoom = segment(start: 0, end: 10, zoom: 3, fadeIn: 1, fadeOut: 1)
        XCTAssertEqual(zoom.zoomLevel(at: 5), 3, accuracy: 0.0001)
    }

    func testZoomRampsSmoothlyInAndOut() {
        let zoom = segment(start: 0, end: 10, zoom: 3, fadeIn: 2, fadeOut: 2)
        XCTAssertEqual(zoom.zoomLevel(at: 0), 1, accuracy: 0.01, "starts at neutral")
        XCTAssertEqual(zoom.zoomLevel(at: 10), 1, accuracy: 0.01, "ends at neutral")

        var previous = zoom.zoomLevel(at: 0)
        for t in stride(from: 0.0, through: 2.0, by: 0.25) {
            let value = zoom.zoomLevel(at: t)
            XCTAssertGreaterThanOrEqual(value, previous - 0.0001, "the ramp-in must not go backwards")
            previous = value
        }
    }

    func testZoomStaysBetweenNeutralAndTheTarget() {
        let zoom = segment(start: 1, end: 6, zoom: 4, fadeIn: 1.5, fadeOut: 2)
        for t in stride(from: 0.0, through: 7.0, by: 0.1) {
            let value = zoom.zoomLevel(at: t)
            XCTAssertGreaterThanOrEqual(value, 1)
            XCTAssertLessThanOrEqual(value, 4)
        }
    }

    func testAZeroLengthSegmentIsNeutral() {
        XCTAssertEqual(segment(start: 3, end: 3).zoomLevel(at: 3), 1.0,
                       "a segment with no duration must not divide by zero")
    }

    func testFadesCannotOverlapEachOther() {
        // Asking for 5s fades inside a 4s segment: each gets clamped to under half.
        let zoom = segment(start: 0, end: 4, fadeIn: 5, fadeOut: 5)
        XCTAssertLessThanOrEqual(zoom.effectiveFadeIn + zoom.effectiveFadeOut, zoom.duration)
        XCTAssertGreaterThan(zoom.effectiveFadeIn, 0)
    }

    func testNegativeFadesAreTreatedAsNone() {
        let zoom = segment(fadeIn: -3, fadeOut: -1)
        XCTAssertEqual(zoom.effectiveFadeIn, 0)
        XCTAssertEqual(zoom.effectiveFadeOut, 0)
    }

    // MARK: - Center clamping

    func testTheCenterIsPulledInSoTheWindowStaysInsideTheFrame() {
        let clamped = VideoZoomSegment.clampedCenter(CGPoint(x: 0, y: 1), zoom: 2)
        XCTAssertEqual(clamped.x, 0.25, accuracy: 0.001, "at 2x the window is half the frame, so 0.25 is the closest to the edge")
        XCTAssertEqual(clamped.y, 0.75, accuracy: 0.001)
    }

    func testACenteredPointIsLeftAlone() {
        let clamped = VideoZoomSegment.clampedCenter(CGPoint(x: 0.5, y: 0.5), zoom: 4)
        XCTAssertEqual(clamped.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(clamped.y, 0.5, accuracy: 0.0001)
    }

    func testHigherZoomAllowsTheCenterCloserToTheEdge() {
        let low = VideoZoomSegment.clampedCenter(CGPoint(x: 0, y: 0), zoom: 2)
        let high = VideoZoomSegment.clampedCenter(CGPoint(x: 0, y: 0), zoom: 8)
        XCTAssertLessThan(high.x, low.x, "a tighter window can sit nearer the frame edge")
    }

    func testNoZoomPinsTheCenter() {
        let clamped = VideoZoomSegment.clampedCenter(CGPoint(x: 0.1, y: 0.9), zoom: 1)
        XCTAssertEqual(clamped.x, 0.5, accuracy: 0.001, "with no zoom the whole frame is visible")
        XCTAssertEqual(clamped.y, 0.5, accuracy: 0.001)
    }

    // MARK: - Translation

    func testNoTranslationWithoutZoom() {
        XCTAssertEqual(segment(zoom: 1).translation(zoom: 1, videoSize: CGSize(width: 1920, height: 1080)), .zero)
    }

    func testTranslationNeverExposesAreaOutsideTheVideo() {
        let size = CGSize(width: 1920, height: 1080)
        for centerX in stride(from: 0.0, through: 1.0, by: 0.1) {
            for zoom in [1.5, 2.0, 4.0] as [CGFloat] {
                let zoomSegment = segment(zoom: zoom, center: CGPoint(x: centerX, y: 0.5))
                let translation = zoomSegment.translation(zoom: zoom, videoSize: size)
                let maxTx = (zoom - 1) * size.width / (2 * zoom)
                XCTAssertLessThanOrEqual(abs(translation.x), maxTx + 0.001,
                                         "center \(centerX) at \(zoom)x pans past the edge, which shows black bars")
            }
        }
    }

    func testACenteredZoomDoesNotPan() {
        let zoomSegment = segment(zoom: 3, center: CGPoint(x: 0.5, y: 0.5))
        let translation = zoomSegment.translation(zoom: 3, videoSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(translation.x, 0, accuracy: 0.0001)
        XCTAssertEqual(translation.y, 0, accuracy: 0.0001)
    }

    func testAZeroSizedVideoDoesNotProduceNonsense() {
        let translation = segment(zoom: 2).translation(zoom: 2, videoSize: .zero)
        XCTAssertTrue(translation.x.isFinite && translation.y.isFinite)
        XCTAssertEqual(translation, .zero)
    }

    // MARK: - Overlap

    func testZoomSegmentsOverlapOnlyWhenTheyShareTime() {
        let first = segment(start: 0, end: 5)
        XCTAssertTrue(first.overlaps(segment(start: 4, end: 6)))
        XCTAssertFalse(first.overlaps(segment(start: 5, end: 8)), "touching endpoints aren't an overlap")
        XCTAssertFalse(first.overlaps(segment(start: 6, end: 8)))
    }
}
