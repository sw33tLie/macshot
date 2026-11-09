import XCTest

@MainActor
final class DeferredRestorationTests: XCTestCase {
    func testNewCaptureInheritsHiddenItemsAndRejectsTheOldTimer() throws {
        var state = DeferredRestoration<Int>()
        state.begin(adding: [1, 2])
        let oldTimer = try XCTUnwrap(state.schedule())
        state.begin(adding: [3])
        XCTAssertNil(state.take(ifCurrent: oldTimer))
        XCTAssertEqual(state.pending, [1, 2, 3])
        let current = try XCTUnwrap(state.schedule())
        XCTAssertEqual(state.take(ifCurrent: current), [1, 2, 3])
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testActivationAndFallbackCannotRestoreTwiceOrConsumeTheNextCapture() throws {
        var state = DeferredRestoration<Int>()
        state.begin(adding: [1])
        let token = try XCTUnwrap(state.schedule())
        XCTAssertEqual(state.take(ifCurrent: token), [1])
        state.begin(adding: [2])
        XCTAssertNil(state.take(ifCurrent: token))
        XCTAssertEqual(state.pending, [2])
    }

    func testClosedItemsAreNotRestoredAndExistingItemsAreNotDuplicated() throws {
        var state = DeferredRestoration<Int>()
        state.begin(adding: [1, 2])
        state.begin(adding: [2, 3])
        let token = try XCTUnwrap(state.schedule())
        state.remove(2)
        XCTAssertEqual(state.take(ifCurrent: token), [1, 3])
    }

    func testReschedulingAndImmediateRestoreInvalidateEarlierCallbacks() throws {
        var state = DeferredRestoration<Int>()
        state.begin(adding: [1])
        let first = try XCTUnwrap(state.schedule())
        let second = try XCTUnwrap(state.schedule())
        XCTAssertNil(state.take(ifCurrent: first))
        XCTAssertEqual(state.takeNow(), [1])
        XCTAssertNil(state.take(ifCurrent: second))
        XCTAssertNil(state.schedule())
    }
}
