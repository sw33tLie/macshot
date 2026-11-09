import XCTest

@MainActor
final class HistoryFileCleanupTests: XCTestCase {
    private var directory: URL!
    private let cleanupQueue = DispatchQueue(label: "macshot.tests.history-cleanup")
    private let now = Date()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cleanupQueue.sync {}
        try FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func file(_ name: String, age: TimeInterval = 48 * 60 * 60) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("retained capture bytes".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func testMissingUnreadableAndPartlySalvagedIndexesPreserveEveryFile() throws {
        let id = UUID().uuidString
        let names = ["\(id).png", "\(id)_raw.png", "\(id)_thumb.png", "\(id)_preview.png", "\(id)_annotations.json"]
        for name in names { try file(name) }
        for payload: String? in [nil, "truncated{", "[{\"id\":\"\(id)\"},{}]"] {
            if let payload { try Data(payload.utf8).write(to: directory.appendingPathComponent("index.json")) }
            withDefaults(["historySize": 10, "historyUnlimited": false]) {
                let history = ScreenshotHistory(directory: directory, cleanupQueue: cleanupQueue)
                cleanupQueue.sync {}
                for name in names { XCTAssertTrue(exists(name), name) }
                withExtendedLifetime(history) {}
            }
        }
    }

    func testACompleteIndexAllowsOnlyOldUnreferencedDerivedCachesToBeRemoved() throws {
        let orphan = UUID().uuidString, known = UUID().uuidString, fresh = UUID().uuidString
        let originalSuffixes = [".png", "_raw.png", "_annotations.json", "_edit.json", "_other.png"]
        for suffix in originalSuffixes { try file(orphan + suffix) }
        for id in [orphan, known] { try file(id + "_thumb.png"); try file(id + "_preview.png") }
        try file(fresh + "_thumb.png", age: 3600)
        let result = HistoryFileCleanup.sweep(directory: directory, indexedIDs: [known.lowercased()], asOf: now)
        XCTAssertEqual(result.removed, 2)
        XCTAssertFalse(exists(orphan + "_thumb.png"))
        XCTAssertFalse(exists(orphan + "_preview.png"))
        for suffix in originalSuffixes { XCTAssertTrue(exists(orphan + suffix)) }
        XCTAssertTrue(exists(known + "_thumb.png"))
        XCTAssertTrue(exists(known + "_preview.png"))
        XCTAssertTrue(exists(fresh + "_thumb.png"))
    }

    func testQueuedStartupCleanupPreservesFilesWrittenAfterTheIndexWasRead() throws {
        try Data("[]".utf8).write(to: directory.appendingPathComponent("index.json"))
        cleanupQueue.suspend()
        let history = ScreenshotHistory(directory: directory, cleanupQueue: cleanupQueue)
        let id = UUID().uuidString
        do {
            try file(id + ".png", age: 0)
            try file(id + "_thumb.png", age: 0)
        } catch { cleanupQueue.resume(); throw error }
        cleanupQueue.resume()
        cleanupQueue.sync {}
        XCTAssertTrue(exists(id + ".png"))
        XCTAssertTrue(exists(id + "_thumb.png"))
        withExtendedLifetime(history) {}
    }

    func testDuplicateRowsCannotPruneTheOnlyImageForThatIdentifier() throws {
        let id = UUID().uuidString
        try file(id + ".png")
        try Data("[{\"id\":\"\(id)\"},{\"id\":\"\(id)\"}]".utf8)
            .write(to: directory.appendingPathComponent("index.json"))
        withDefaults(["historySize": 1, "historyUnlimited": false]) {
            let history = ScreenshotHistory(directory: directory, cleanupQueue: cleanupQueue)
            cleanupQueue.sync {}
            XCTAssertEqual(history.entries.count, 1)
            XCTAssertTrue(exists(id + ".png"))
        }
    }

    func testInvalidNamesAreSkippedAndInvalidMetadataUsesSafeDefaults() throws {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: [
            ["id": "invalid identifier", "fileExtension": "png"],
            ["id": UUID().uuidString, "fileExtension": "unsupported"],
            ["id": id, "timestamp": 1e200, "lastEditedAt": -1e200, "pixelWidth": -3, "pixelHeight": -4],
        ])
        let rows = try XCTUnwrap(LenientArrayDecoder.decode(ScreenshotHistory.IndexEntry.self, from: data))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, id)
        XCTAssertEqual(rows[0].fileExtension, "png")
        XCTAssertEqual(rows[0].timestamp, Date(timeIntervalSince1970: 0))
        XCTAssertNil(rows[0].lastEditedAt)
        XCTAssertEqual(rows[0].pixelWidth, 0)
        XCTAssertEqual(rows[0].pixelHeight, 0)
    }

    func testUnusableDatesDoNotTrapWhenTheHistoryLabelIsDrawn() {
        for value in [Double.nan, .infinity, -.infinity, 1e200] {
            let entry = HistoryEntry(id: UUID().uuidString, fileExtension: "png",
                timestamp: Date(timeIntervalSince1970: value), pixelWidth: 1, pixelHeight: 1)
            XCTAssertEqual(entry.timeAgoString, "-")
        }
    }
}
