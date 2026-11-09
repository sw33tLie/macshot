import Foundation
import XCTest

/// Speed ramps and freeze frames rebuild the composition timeline together
/// with cuts. Every composition second has to map back to a real source
/// moment, or the export plays the wrong footage — or nothing.
final class VideoSpeedAndFreezeTests: XCTestCase {

    private func speed(_ start: Double, _ end: Double, _ factor: Double) -> VideoSpeedSegment {
        VideoSpeedSegment(startTime: start, endTime: end, speedFactor: factor)
    }

    private func freeze(at time: Double, hold: Double) -> VideoFreezeSegment {
        VideoFreezeSegment(atTime: time, holdDuration: hold)
    }

    // MARK: - Speed segment maths

    func testSpeedingUpShortensTheComposition() {
        let fast = speed(0, 10, 2)
        XCTAssertEqual(fast.sourceDuration, 10)
        XCTAssertEqual(fast.compositionDuration, 5, accuracy: 0.0001)
    }

    func testSlowingDownLengthensTheComposition() {
        let slow = speed(0, 10, 0.5)
        XCTAssertEqual(slow.compositionDuration, 20, accuracy: 0.0001)
    }

    func testTheSpeedFactorIsClamped() {
        XCTAssertEqual(VideoSpeedSegment.clampFactor(0), VideoSpeedSegment.minFactor)
        XCTAssertEqual(VideoSpeedSegment.clampFactor(-4), VideoSpeedSegment.minFactor)
        XCTAssertEqual(VideoSpeedSegment.clampFactor(1000), VideoSpeedSegment.maxFactor)
        XCTAssertEqual(VideoSpeedSegment.clampFactor(2), 2)
    }

    func testAnInvertedSegmentHasNoDuration() {
        XCTAssertEqual(speed(10, 4, 2).sourceDuration, 0)
    }

    func testEveryOfferedSpeedPresetIsWithinTheAllowedRange() {
        for factor in VideoSpeedSegment.presetFactors {
            XCTAssertEqual(VideoSpeedSegment.clampFactor(factor), factor,
                           "preset \(factor)x is outside the allowed range")
        }
    }

    func testSpeedSegmentsOverlapOnlyWhenTheyShareTime() {
        let segment = speed(5, 10, 2)
        XCTAssertTrue(segment.overlaps(startTime: 9, endTime: 12))
        XCTAssertFalse(segment.overlaps(startTime: 10, endTime: 12))
    }

    // MARK: - Freeze segments

    func testFreezeDurationIsClamped() {
        XCTAssertEqual(VideoFreezeSegment.clampDuration(0), VideoFreezeSegment.minHoldDuration)
        XCTAssertEqual(VideoFreezeSegment.clampDuration(-1), VideoFreezeSegment.minHoldDuration)
        XCTAssertEqual(VideoFreezeSegment.clampDuration(9999), VideoFreezeSegment.maxHoldDuration)
    }

    func testEveryFreezePresetIsAllowed() {
        for duration in VideoFreezeSegment.presetDurations {
            XCTAssertEqual(VideoFreezeSegment.clampDuration(duration), duration)
        }
        XCTAssertEqual(VideoFreezeSegment.clampDuration(VideoFreezeSegment.defaultDuration),
                       VideoFreezeSegment.defaultDuration)
    }

    func testAFreezeOccupiesItsHoldDurationInTheComposition() {
        XCTAssertEqual(freeze(at: 3, hold: 2).compositionWidth(), 2, accuracy: 0.0001)
    }

    // MARK: - Building the timeline

    private func pieces(kept: [(Double, Double)],
                        speeds: [VideoSpeedSegment] = [],
                        freezes: [VideoFreezeSegment] = []) -> [VideoSpeeds.Piece] {
        VideoSpeeds.pieces(keptRanges: kept, speeds: speeds, freezes: freezes)
    }

    func testFootageWithNoEditsIsOnePiece() {
        let result = pieces(kept: [(0, 10)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .normal)
        XCTAssertEqual(result[0].compositionDuration, 10, accuracy: 0.0001)
    }

    func testASpeedSegmentSplitsTheTimelineIntoThree() {
        let result = pieces(kept: [(0, 10)], speeds: [speed(4, 6, 2)])
        XCTAssertEqual(result.count, 3, "before, sped-up, after")
        XCTAssertEqual(result[1].kind, .speed)
        XCTAssertEqual(result[1].compositionDuration, 1, accuracy: 0.0001, "2s at 2x plays in 1s")
    }

    func testTheCompositionCoversEverySourceSecondThatSurvived() {
        let kept = [(0.0, 10.0)]
        let result = pieces(kept: kept, speeds: [speed(2, 4, 2), speed(7, 8, 0.5)])
        let covered = result.reduce(0.0) { $0 + $1.sourceDuration }
        XCTAssertEqual(covered, 10, accuracy: 0.001, "the timeline must account for all kept footage")
    }

    func testEachPieceMapsBackIntoItsSourceRange() {
        let result = pieces(kept: [(0, 12)], speeds: [speed(3, 6, 3)], freezes: [freeze(at: 9, hold: 2)])
        for piece in result {
            XCTAssertGreaterThanOrEqual(piece.srcEnd, piece.srcStart, "a piece can't run backwards")
            XCTAssertGreaterThan(piece.compositionDuration, 0, "a piece with no duration shows nothing")
            XCTAssertTrue(piece.factor.isFinite, "factor must be usable by the compositor")
            XCTAssertGreaterThanOrEqual(piece.factor, 0)
        }
    }

    func testAFreezeHoldsForItsConfiguredTime() {
        let result = pieces(kept: [(0, 10)], freezes: [freeze(at: 5, hold: 3)])
        let frozen = result.filter { $0.kind == .freeze }
        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].compositionDuration, 3, accuracy: 0.0001)
        XCTAssertEqual(frozen[0].sourceDuration, 0, "a freeze adds time without removing footage")
        XCTAssertEqual(frozen[0].factor, 0, "source-time effects must remain stationary during a hold")
    }

    func testAFreezeAddsToTheTotalRuntime() {
        let plain = pieces(kept: [(0, 10)]).reduce(0.0) { $0 + $1.compositionDuration }
        let withFreeze = pieces(kept: [(0, 10)], freezes: [freeze(at: 5, hold: 2)])
            .reduce(0.0) { $0 + $1.compositionDuration }
        XCTAssertEqual(withFreeze, plain + 2, accuracy: 0.000000001)
    }

    func testSpeedSegmentsOutsideTheKeptRangesAreDropped() {
        // A speed ramp over footage that was cut out has nothing to apply to.
        let result = pieces(kept: [(0, 5)], speeds: [speed(20, 25, 2)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .normal)
    }

    func testOverlappingSpeedSegmentsDoNotProduceOverlappingPieces() {
        let result = pieces(kept: [(0, 20)], speeds: [speed(2, 8, 2), speed(5, 12, 3)])
        for (index, piece) in result.enumerated() where index > 0 {
            XCTAssertGreaterThanOrEqual(piece.srcStart, result[index - 1].srcEnd - 0.0001,
                                        "pieces must not replay the same source range")
        }
    }

    func testNoFootageProducesNoPieces() {
        XCTAssertTrue(pieces(kept: []).isEmpty)
    }

    func testAZeroLengthKeptRangeIsIgnored() {
        XCTAssertTrue(pieces(kept: [(5, 5)]).isEmpty)
    }

    func testTheTimelineSurvivesCutsSpeedsAndFreezesTogether() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 30,
                                        cuts: [VideoCutSegment(startTime: 10, endTime: 12)])
        let result = pieces(kept: kept, speeds: [speed(4, 8, 2)], freezes: [freeze(at: 20, hold: 1)])

        XCTAssertFalse(result.isEmpty)
        let sourceCovered = result.filter { $0.kind != .freeze }.reduce(0.0) { $0 + $1.sourceDuration }
        XCTAssertEqual(sourceCovered, 28, accuracy: 0.000000001, "28s of footage survives a 2s cut")

        // Nothing may map into the cut-out range.
        for piece in result where piece.kind != .freeze {
            let overlapsCut = piece.srcStart < 12 && piece.srcEnd > 10
            XCTAssertFalse(overlapsCut, "piece \(piece.srcStart)–\(piece.srcEnd) replays cut footage")
        }
    }

    func testManyFreezesIncludingTheTrimStartNeverConsumeOriginalFootage() {
        let holds = (0..<100).map { freeze(at: Double($0) / 10, hold: 0.25) }
        let result = pieces(kept: [(0, 10)], freezes: holds)
        XCTAssertEqual(result.filter { $0.kind == .freeze }.count, 100)
        XCTAssertEqual(result.reduce(0) { $0 + $1.sourceDuration }, 10, accuracy: 0.000000001)
        XCTAssertEqual(result.reduce(0) { $0 + $1.compositionDuration }, 35, accuracy: 0.000000001)
    }

    func testAnOverriddenSpeedResumesAfterTheInnerRangeEnds() {
        let result = pieces(kept: [(0, 10)], speeds: [speed(2, 8, 2), speed(4, 6, 4)])
        XCTAssertEqual(result.map(\.srcStart), [0, 2, 4, 6, 8])
        XCTAssertEqual(result.map(\.factor), [1, 2, 4, 2, 1])
        XCTAssertEqual(result.reduce(0) { $0 + $1.compositionDuration }, 6.5, accuracy: 0.000000001)
    }

    func testSubmillisecondKeptRangesAreNotSilentlyRemoved() {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: 1,
            cuts: [VideoCutSegment(startTime: 0.0005, endTime: 0.5),
                   VideoCutSegment(startTime: 0.5005, endTime: 0.9995)])
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(VideoCuts.totalDuration(for: kept), 0.0015, accuracy: 0.000000001)
    }
}
