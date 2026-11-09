import XCTest

final class RecordingLifecycleTests: XCTestCase {
    func testStopDuringPreparationCannotBeOverriddenByLateStartup() throws {
        var lifecycle = RecordingLifecycle()
        let id = try XCTUnwrap(lifecycle.begin())
        XCTAssertEqual(lifecycle.state, .preparing)
        XCTAssertEqual(lifecycle.requestStop(), id)
        XCTAssertFalse(lifecycle.didStart(id))
        XCTAssertEqual(lifecycle.state, .stopping)
        XCTAssertTrue(lifecycle.finish(id))
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertFalse(lifecycle.didStart(id))
    }

    func testCompletionAndStopEachHaveOneOwner() throws {
        var lifecycle = RecordingLifecycle()
        let id = try XCTUnwrap(lifecycle.begin())
        XCTAssertTrue(lifecycle.didStart(id))
        XCTAssertFalse(lifecycle.finish(id), "the writer must finish before completing a running session")
        XCTAssertEqual(lifecycle.requestStop(), id)
        XCTAssertNil(lifecycle.requestStop())
        XCTAssertTrue(lifecycle.finish(id))
        XCTAssertFalse(lifecycle.finish(id))
        XCTAssertNil(lifecycle.requestStop())
    }

    func testPreviousSessionCallbacksCannotChangeANewRecording() throws {
        var lifecycle = RecordingLifecycle()
        let old = try XCTUnwrap(lifecycle.begin())
        _ = lifecycle.requestStop()
        XCTAssertTrue(lifecycle.finish(old))
        let current = try XCTUnwrap(lifecycle.begin())
        XCTAssertFalse(lifecycle.isCurrent(old))
        XCTAssertFalse(lifecycle.didStart(old))
        XCTAssertFalse(lifecycle.finish(old))
        XCTAssertTrue(lifecycle.isPreparing(current))
        XCTAssertTrue(lifecycle.didStart(current))
        XCTAssertFalse(lifecycle.finish(old))
        XCTAssertEqual(lifecycle.state, .recording)
    }

    func testPauseCannotRunBeforeCaptureStartsOrDuringStop() throws {
        var lifecycle = RecordingLifecycle()
        XCTAssertFalse(lifecycle.pause())
        let id = try XCTUnwrap(lifecycle.begin())
        XCTAssertFalse(lifecycle.pause())
        XCTAssertFalse(lifecycle.resume())
        XCTAssertTrue(lifecycle.didStart(id))
        XCTAssertTrue(lifecycle.pause())
        XCTAssertFalse(lifecycle.pause())
        XCTAssertTrue(lifecycle.resume())
        XCTAssertFalse(lifecycle.resume())
        _ = lifecycle.requestStop()
        XCTAssertFalse(lifecycle.pause())
        XCTAssertFalse(lifecycle.resume())
    }

    func testRepeatedSessionsDoNotReuseCompletionState() throws {
        var lifecycle = RecordingLifecycle()
        var completed = 0
        for index in 0..<100 {
            let id = try XCTUnwrap(lifecycle.begin())
            XCTAssertNil(lifecycle.begin(), "a second start must not replace the current session")
            if index.isMultiple(of: 2) { XCTAssertTrue(lifecycle.didStart(id)) }
            XCTAssertEqual(lifecycle.requestStop(), id)
            XCTAssertNil(lifecycle.begin(), "a new session must wait for finalization")
            if lifecycle.finish(id) { completed += 1 }
            if lifecycle.finish(id) { completed += 1 }
        }
        XCTAssertEqual(completed, 100)
        XCTAssertEqual(lifecycle.state, .idle)
    }
}
