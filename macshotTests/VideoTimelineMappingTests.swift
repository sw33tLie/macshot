import XCTest

final class VideoTimelineMappingTests: XCTestCase {
    func testRebuildingAnEarlierCutPreservesTheOldItemsSourcePlayhead() {
        let oldItem = VideoTimelineMapping(entries: [.init(compStart: 0, compEnd: 8, sourceStart: 2, factor: 1)])
        let newItem = VideoTimelineMapping(entries: [.init(compStart: 0, compEnd: 6, sourceStart: 4, factor: 1)])
        // The old player is at source 7s. Its current 5s clock must be read
        // with its old mapping, then sought to 3s on the new player.
        let source = oldItem.sourceTime(at: 5)
        XCTAssertEqual(source, 7)
        XCTAssertEqual(newItem.compositionTime(at: source), 3)
        XCTAssertEqual(oldItem.sourceTime(at: 5), 7)
    }

    func testFreezeAndCutBoundariesMapInBothDirections() {
        let mapping = VideoTimelineMapping(entries: [
            .init(compStart: 0, compEnd: 1, sourceStart: 2, factor: 2),
            .init(compStart: 1, compEnd: 2, sourceStart: 4, factor: 0),
            .init(compStart: 2, compEnd: 3, sourceStart: 4, factor: 1),
            .init(compStart: 3, compEnd: 4, sourceStart: 6, factor: 1),
        ])
        XCTAssertEqual(mapping.sourceTime(at: 0.5), 3)
        XCTAssertEqual(mapping.sourceTime(at: 1.5), 4)
        XCTAssertEqual(mapping.sourceTime(at: 2), 4)
        XCTAssertEqual(mapping.sourceTime(at: 3), 6)
        XCTAssertEqual(mapping.compositionTime(at: 4), 1)
        XCTAssertEqual(mapping.compositionTime(at: 4.5), 2.5)
        XCTAssertEqual(mapping.compositionTime(at: 5.5), 3)
        XCTAssertEqual(mapping.sourceTime(at: -1), 2)
        XCTAssertEqual(mapping.sourceTime(at: 10), 7)
        XCTAssertEqual(mapping.sourceTime(at: .nan), 2)
        XCTAssertEqual(mapping.compositionTime(at: .nan), 0)
    }

    func testUneditedAssetsKeepTheirOriginalClock() {
        let mapping = VideoTimelineMapping(entries: [])
        XCTAssertEqual(mapping.sourceTime(at: 8), 8)
        XCTAssertEqual(mapping.compositionTime(at: 8), 8)
    }
}
