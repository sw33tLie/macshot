import XCTest

/// "Restart macshot" (permission reset, settings import) launches the
/// replacement while the old instance still runs. The replacement must not
/// quit as a duplicate, but a real second launch still must.
final class RelaunchHandoffTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RelaunchHandoffTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testReplacementOfTheRecordingInstanceIsAllowedOnce() {
        let now = Date()
        RelaunchHandoff.record(pid: 4242, now: now, defaults: defaults)
        XCTAssertTrue(RelaunchHandoff.claim(otherPIDs: [4242], now: now.addingTimeInterval(2), defaults: defaults))
        // Consumed: a later duplicate launch is not excused.
        XCTAssertFalse(RelaunchHandoff.claim(otherPIDs: [4242], now: now.addingTimeInterval(3), defaults: defaults))
        XCTAssertNil(defaults.object(forKey: RelaunchHandoff.pidKey))
        XCTAssertNil(defaults.object(forKey: RelaunchHandoff.dateKey))
    }

    func testOrdinaryDuplicateLaunchStillQuits() {
        XCTAssertFalse(RelaunchHandoff.claim(otherPIDs: [4242], defaults: defaults))
    }

    func testHandoffFromAnotherInstanceDoesNotExcuseThisOne() {
        let now = Date()
        RelaunchHandoff.record(pid: 1111, now: now, defaults: defaults)
        XCTAssertFalse(RelaunchHandoff.claim(otherPIDs: [4242], now: now, defaults: defaults))
        RelaunchHandoff.record(pid: 1111, now: now, defaults: defaults)
        XCTAssertFalse(RelaunchHandoff.claim(otherPIDs: [1111, 4242], now: now, defaults: defaults))
    }

    func testStaleOrFutureHandoffIsIgnored() {
        let now = Date()
        RelaunchHandoff.record(pid: 4242, now: now, defaults: defaults)
        XCTAssertFalse(RelaunchHandoff.claim(otherPIDs: [4242], now: now.addingTimeInterval(RelaunchHandoff.lifetime + 1), defaults: defaults))
        RelaunchHandoff.record(pid: 4242, now: now, defaults: defaults)
        XCTAssertFalse(RelaunchHandoff.claim(otherPIDs: [4242], now: now.addingTimeInterval(-5), defaults: defaults))
    }

    func testLaunchWithNoOtherInstanceClearsALeftoverRecord() {
        RelaunchHandoff.record(pid: 4242, defaults: defaults)
        XCTAssertFalse(RelaunchHandoff.claim(otherPIDs: [], defaults: defaults))
        XCTAssertNil(defaults.object(forKey: RelaunchHandoff.pidKey))
    }

    func testHandoffKeysAreNotExportedWithSettings() {
        XCTAssertTrue(SettingsPortability.excludedKeys.contains(RelaunchHandoff.pidKey))
        XCTAssertTrue(SettingsPortability.excludedKeys.contains(RelaunchHandoff.dateKey))
    }
}
