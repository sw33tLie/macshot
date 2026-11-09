import Cocoa
import XCTest

/// History is the only place a capture survives after the overlay closes, and
/// "Edit" reopens it from these files. Each test gets its own directory, so
/// nothing here touches the user's real captures.
@MainActor
final class ScreenshotHistoryTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeHistory() -> ScreenshotHistory {
        ScreenshotHistory(directory: directory)
    }

    /// `add` finishes its file writes on a background queue, in a fixed order:
    /// composited image, thumbnail, preview, raw image, annotations, edit
    /// state. Waiting on the last file each capture expects avoids racing it.
    private func waitForWrites(_ history: ScreenshotHistory, entryCount: Int,
                               expecting suffixes: [String] = [".png", "_thumb.png", "_preview.png"],
                               file: StaticString = #filePath, line: UInt = #line) {
        // `add` writes on a utility queue, which can be starved for several
        // seconds on a loaded machine (a parallel build, say), so wait
        // generously rather than flaking.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            let complete = !history.hasPendingWrites && history.entries.count >= entryCount && history.entries.allSatisfy { entry in
                suffixes.allSatisfy { suffix in
                    let url = suffix == ".png" ? history.fileURL(for: entry) : history.sidecarURL(for: entry, suffix: suffix)
                    return FileManager.default.fileExists(atPath: url.path)
                }
            }
            if complete && files.contains("index.json") { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        XCTFail("history files were never written. entries=\(history.entries.map(\.id)) expected=\(suffixes) onDisk=\(files)",
                file: file, line: line)
    }

    private func annotations() -> [Annotation] {
        let rect = Annotation(tool: .rectangle, startPoint: NSPoint(x: 5, y: 5),
                              endPoint: NSPoint(x: 60, y: 40), color: .systemRed, strokeWidth: 4)
        rect.rectCornerRadius = 8
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 10, y: 10),
                               endPoint: NSPoint(x: 90, y: 70), color: .systemBlue, strokeWidth: 6)
        arrow.arrowStyle = .double
        return [rect, arrow]
    }

    // MARK: - Round trip

    func testACaptureComesBackAfterARestart() throws {
        let image = ImageProbe.quadrantImage(width: 120, height: 90)
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations())
        }
        waitForWrites(history, entryCount: 1, expecting: [".png", "_thumb.png", "_preview.png", "_raw.png", "_annotations.json"])

        // A second instance reads the index from disk, like the next launch does.
        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.entries.count, 1)
        let entry = try XCTUnwrap(reloaded.entries.first)
        XCTAssertTrue(entry.hasAnnotations)
        XCTAssertNotNil(reloaded.loadImage(for: entry), "the capture image must reload")
        XCTAssertNotNil(reloaded.loadRawImage(for: entry), "editing needs the un-annotated original")

        let restored = try XCTUnwrap(reloaded.loadAnnotations(for: entry))
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.map(\.tool), [.rectangle, .arrow])
        XCTAssertEqual(restored[0].rectCornerRadius, 8)
        XCTAssertEqual(restored[1].arrowStyle, .double)
    }

    func testEditStateSurvivesTheRoundTrip() throws {
        var state = CaptureEditState()
        state.beautifyEnabled = true
        state.beautifyStyleIndex = 5
        state.beautifyPadding = 72

        let image = ImageProbe.quadrantImage(width: 80, height: 60)
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: nil, editState: state)
        }
        waitForWrites(history, entryCount: 1, expecting: [".png", "_thumb.png", "_preview.png", "_edit.json"])

        let reloaded = makeHistory()
        let entry = try XCTUnwrap(reloaded.entries.first)
        let restored = try XCTUnwrap(reloaded.loadEditState(for: entry))
        XCTAssertEqual(restored, state)
    }

    func testAnnotationsWrittenByAnOlderBuildStillLoad() throws {
        // Same shape the app writes, but with only the fields the first version
        // had — what an entry saved before later fields existed looks like.
        let image = ImageProbe.quadrantImage(width: 60, height: 40)
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations())
        }
        waitForWrites(history, entryCount: 1, expecting: [".png", "_thumb.png", "_preview.png", "_annotations.json"])

        let entry = try XCTUnwrap(history.entries.first)
        let annotationFile = history.sidecarURL(for: entry, suffix: "_annotations.json")
        try Data("""
        [{"tool":3,"startX":1,"startY":2,"endX":30,"endY":40,"colorRGBA":[1,0,0,1],"strokeWidth":5}]
        """.utf8).write(to: annotationFile)

        let reloaded = makeHistory()
        let restored = try XCTUnwrap(
            reloaded.loadAnnotations(for: try XCTUnwrap(reloaded.entries.first)),
            "an entry from an older version must still open with its annotations")
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].tool, .rectangle)
    }

    func testACorruptAnnotationFileLosesOnlyTheAnnotations() throws {
        let image = ImageProbe.quadrantImage(width: 60, height: 40)
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations())
        }
        waitForWrites(history, entryCount: 1, expecting: [".png", "_thumb.png", "_preview.png", "_annotations.json"])

        let entry = try XCTUnwrap(history.entries.first)
        try Data("truncated{".utf8).write(to: history.sidecarURL(for: entry, suffix: "_annotations.json"))

        let reloaded = makeHistory()
        let reloadedEntry = try XCTUnwrap(reloaded.entries.first)
        XCTAssertNil(reloaded.loadAnnotations(for: reloadedEntry))
        XCTAssertNotNil(reloaded.loadImage(for: reloadedEntry), "the capture itself must still open")
    }

    func testACorruptIndexDoesNotTakeTheCapturesWithIt() throws {
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: ImageProbe.quadrantImage(width: 40, height: 40), rawImage: nil, annotations: nil)
        }
        waitForWrites(history, entryCount: 1)

        // One unreadable row among good ones.
        let entry = try XCTUnwrap(history.entries.first)
        let index = """
        [{"garbage":true},
         {"id":"\(entry.id)","revision":"\(entry.revision!)","fileExtension":"png","timestamp":0,"pixelWidth":40,"pixelHeight":40}]
        """
        try Data(index.utf8).write(to: directory.appendingPathComponent("index.json"))

        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.entries.count, 1, "one bad row must not empty the history")
        XCTAssertEqual(reloaded.entries.first?.id, entry.id)
    }

    // MARK: - Pruning

    func testEditableReopenRequiresReadablePresentSidecars() async throws {
        let image = ImageProbe.quadrantImage(width: 80, height: 60)
        var state = CaptureEditState()
        state.effectsBrightness = 0.2
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: annotations(), editState: state)
        }
        await history.waitUntilIdle()
        let entry = try XCTUnwrap(history.entries.first)
        let editable = try XCTUnwrap(history.loadEditableCapture(for: entry))
        XCTAssertEqual(editable.annotations.count, 2)
        XCTAssertEqual(editable.editState, state)
        let original = try Data(contentsOf: history.fileURL(for: entry))
        let editURL = history.sidecarURL(for: entry, suffix: "_edit.json")
        try Data("incomplete".utf8).write(to: editURL)
        XCTAssertNil(history.loadEditableCapture(for: entry), "the UI must use its flattened-image fallback")
        XCTAssertNotNil(history.loadImage(for: entry))
        XCTAssertEqual(try Data(contentsOf: history.fileURL(for: entry)), original)
        try JSONEncoder().encode(state).write(to: editURL)
        try Data("incomplete".utf8).write(to: history.sidecarURL(for: entry, suffix: "_annotations.json"))
        XCTAssertNil(history.loadEditableCapture(for: entry))
        XCTAssertNotNil(history.loadImage(for: entry))
    }

    func testEditableReopenSupportsEffectsOnlyAndLegacyAnnotationsOnly() async throws {
        let image = ImageProbe.quadrantImage(width: 80, height: 60)
        var state = CaptureEditState()
        state.effectsBrightness = 0.2
        let history = makeHistory()
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: image, rawImage: image, annotations: nil, editState: state)
            history.add(image: image, rawImage: image, annotations: annotations())
        }
        await history.waitUntilIdle()
        XCTAssertEqual(history.entries.count, 2)
        for entry in history.entries {
            let editable = try XCTUnwrap(history.loadEditableCapture(for: entry))
            if editable.editState != nil { XCTAssertTrue(editable.annotations.isEmpty) }
            else { XCTAssertEqual(editable.annotations.count, 2) }
            for suffix in ["_edit.json", "_annotations.json"] {
                let url = history.sidecarURL(for: entry, suffix: suffix)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            XCTAssertNil(history.loadEditableCapture(for: entry), "raw pixels alone must not lose baked edits")
            XCTAssertNotNil(history.loadImage(for: entry))
        }
    }

    func testTheOldestCaptureIsDroppedWhenTheLimitIsReached() {
        let history = makeHistory()
        withDefaults(["historySize": 3, "historyUnlimited": false]) {
            for index in 0..<5 {
                history.add(image: ImageProbe.solidImage(width: 20 + index, height: 20), rawImage: nil, annotations: nil)
            }
            waitForWrites(history, entryCount: 3)
            XCTAssertEqual(history.entries.count, 3)
        }
    }

    func testNewestCapturesComeFirst() {
        let history = makeHistory()
        withDefaults(["historySize": 5, "historyUnlimited": false]) {
            history.add(image: ImageProbe.solidImage(width: 10, height: 10), rawImage: nil, annotations: nil)
            history.add(image: ImageProbe.solidImage(width: 20, height: 20), rawImage: nil, annotations: nil)
        }
        waitForWrites(history, entryCount: 2)
        XCTAssertEqual(history.entries.first?.pixelWidth ?? 0, history.entries.last.map { $0.pixelWidth * 2 } ?? -1,
                       "the 20pt capture should be first")
    }

    func testAZeroSizedHistoryStoresNothing() {
        let history = makeHistory()
        withDefaults(["historySize": 0, "historyUnlimited": false]) {
            history.add(image: ImageProbe.solidImage(), rawImage: nil, annotations: nil)
            XCTAssertTrue(history.entries.isEmpty, "history turned off must not write captures")
        }
    }

    func testClearRemovesEveryEntryAndItsFiles() {
        let history = makeHistory()
        withDefaults(["historySize": 5, "historyUnlimited": false]) {
            for _ in 0..<3 {
                history.add(image: ImageProbe.solidImage(), rawImage: nil, annotations: nil)
            }
        }
        waitForWrites(history, entryCount: 3)

        history.clear()
        waitForWrites(history, entryCount: 0)
        XCTAssertTrue(history.entries.isEmpty)

        let reloaded = makeHistory()
        XCTAssertTrue(reloaded.entries.isEmpty, "cleared captures must not come back on relaunch")
    }

    func testRemovingOneEntryLeavesTheRest() throws {
        let history = makeHistory()
        withDefaults(["historySize": 5, "historyUnlimited": false]) {
            for _ in 0..<3 {
                history.add(image: ImageProbe.solidImage(), rawImage: nil, annotations: nil)
            }
        }
        waitForWrites(history, entryCount: 3)

        let doomed = try XCTUnwrap(history.entries.first?.id)
        history.removeEntry(id: doomed)
        waitForWrites(history, entryCount: 2)
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertFalse(history.entries.contains { $0.id == doomed })

        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.entries.count, 2)
    }

    func testAnEntryWhoseImageWasDeletedIsSkippedOnLoad() throws {
        let history = makeHistory()
        withDefaults(["historySize": 5, "historyUnlimited": false]) {
            history.add(image: ImageProbe.solidImage(), rawImage: nil, annotations: nil)
        }
        waitForWrites(history, entryCount: 1)

        let entry = try XCTUnwrap(history.entries.first)
        try FileManager.default.removeItem(at: history.fileURL(for: entry))

        let reloaded = makeHistory()
        XCTAssertTrue(reloaded.entries.isEmpty, "an entry with no image would show as a broken thumbnail")
    }

    // MARK: - Entry metadata

    func testTimeAgoReadsNaturallyAtEachStep() {
        let now = Date()
        let cases: [(TimeInterval, String)] = [
            (-2, "just now"),
            (-30, "s ago"),
            (-60 * 5, "m ago"),
            (-60 * 60 * 3, "h ago"),
        ]
        for (offset, expected) in cases {
            let entry = HistoryEntry(id: "x", fileExtension: "png", timestamp: now.addingTimeInterval(offset),
                                     lastEditedAt: nil, pixelWidth: 10, pixelHeight: 10,
                                     hasAnnotations: false, thumbnail: nil)
            XCTAssertTrue(entry.timeAgoString.lowercased().contains(expected.lowercased()),
                          "\(offset)s ago rendered as \(entry.timeAgoString)")
        }
    }

    func testAnEditedCaptureSortsByWhenItWasEdited() {
        let created = Date(timeIntervalSince1970: 1_000)
        let edited = Date(timeIntervalSince1970: 2_000)
        let entry = HistoryEntry(id: "x", fileExtension: "png", timestamp: created, lastEditedAt: edited,
                                 pixelWidth: 1, pixelHeight: 1, hasAnnotations: true, thumbnail: nil)
        XCTAssertEqual(entry.effectiveSortDate, edited)

        let untouched = HistoryEntry(id: "y", fileExtension: "png", timestamp: created, lastEditedAt: nil,
                                     pixelWidth: 1, pixelHeight: 1, hasAnnotations: false, thumbnail: nil)
        XCTAssertEqual(untouched.effectiveSortDate, created)
    }
}
