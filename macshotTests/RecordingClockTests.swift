import XCTest

final class RecordingClockTests: XCTestCase {
    func testElapsedTimeDoesNotDependOnTimerDelivery() {
        var clock = RecordingClock()
        clock.start(at: 100)
        XCTAssertEqual(clock.elapsed(at: 101), 1)
        // No callbacks for ten minutes; the next update still has the right time.
        XCTAssertEqual(clock.elapsed(at: 701.25), 601.25)
    }

    func testPausesFreezeElapsedTimeAndAreRemovedExactlyOnce() {
        var clock = RecordingClock()
        clock.start(at: 100)
        clock.pause(at: 110)
        clock.pause(at: 115)
        XCTAssertEqual(clock.elapsed(at: 1000), 10)
        XCTAssertEqual(clock.resume(at: 120), 10)
        XCTAssertEqual(clock.resume(at: 125), 0)
        XCTAssertEqual(clock.elapsed(at: 125), 15)
        clock.pause(at: 130)
        XCTAssertEqual(clock.resume(at: 140), 10)
        XCTAssertEqual(clock.elapsed(at: 150), 30)
    }

    func testRestartResetsThePriorSessionAndEightHoursRemainAccurate() {
        var clock = RecordingClock()
        XCTAssertEqual(clock.elapsed(at: 100), 0)
        clock.start(at: 100)
        clock.pause(at: 110)
        clock.start(at: 200)
        XCTAssertEqual(clock.elapsed(at: 200 + 8 * 3600), 8 * 3600)
        XCTAssertEqual(clock.resume(at: 300), 0)
    }
}
