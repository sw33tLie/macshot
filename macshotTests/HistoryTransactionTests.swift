import AppKit
import XCTest

@MainActor
final class HistoryTransactionTests: XCTestCase {
    private var directory: URL!
    private let queue = DispatchQueue(label: "macshot.tests.history-transactions")
    private let failure = FailureSwitch()

    private final class FailureSwitch: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var enabled = false
        nonisolated func set(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
        nonisolated func check() throws {
            lock.lock(); let fail = enabled; lock.unlock()
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
        }
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        failure.set(false)
    }
    override func tearDownWithError() throws {
        queue.sync {}
        try FileManager.default.removeItem(at: directory)
    }
    private func history() -> ScreenshotHistory {
        let failure = self.failure
        return ScreenshotHistory(directory: directory, writeQueue: queue, beforeIndexPublication: { try failure.check() })
    }
    private func annotation() -> Annotation {
        Annotation(tool: .rectangle, startPoint: .zero, endPoint: NSPoint(x: 10, y: 10), color: .red, strokeWidth: 3)
    }

    func testQueuedWritesOwnBothImagesAndAnnotationValues() async throws {
        let history = history()
        let image = ImageProbe.quadrantImage(width: 80, height: 60)
        let raw = ImageProbe.solidImage(width: 40, height: 30)
        let originalPixels = try XCTUnwrap(ImageProbe.bitmap(from: image))
        let probes = ImageProbe.samplePoints(width: 80, height: 60)
        let originalColors = probes.map { ImageProbe.describePixel(bitmap: originalPixels, x: $0.x, y: $0.y) }
        let annotation = annotation()
        queue.suspend()
        let id = history.add(image: image, rawImage: raw, annotations: [annotation])
        XCTAssertNotNil(id)
        XCTAssertTrue(history.entries.isEmpty, "Unwritten captures must not be published in history")
        for representation in image.representations { image.removeRepresentation(representation) }
        for representation in raw.representations { raw.removeRepresentation(representation) }
        image.size = CGSize(width: 1, height: 1)
        raw.size = CGSize(width: 1, height: 1)
        annotation.strokeWidth = 99
        queue.resume()
        await history.waitUntilIdle()
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.pixelWidth, 80)
        XCTAssertEqual(entry.pixelHeight, 60)
        XCTAssertEqual(try XCTUnwrap(history.loadImage(for: entry)).size, CGSize(width: 80, height: 60))
        XCTAssertEqual(try XCTUnwrap(history.loadRawImage(for: entry)).size, CGSize(width: 40, height: 30))
        XCTAssertEqual(try XCTUnwrap(history.loadAnnotations(for: entry)).first?.strokeWidth, 3)
        let savedPixels = try XCTUnwrap(ImageProbe.bitmap(from: try XCTUnwrap(history.loadImage(for: entry))))
        XCTAssertEqual(probes.map { ImageProbe.describePixel(bitmap: savedPixels, x: $0.x, y: $0.y) }, originalColors)
    }

    func testRetinaCaptureKeepsLogicalSizeAndSharpBoundedCaches() async throws {
        let history = history()
        let image = ImageProbe.quadrantImage(width: 960, height: 640)
        image.size = CGSize(width: 480, height: 320)
        history.add(image: image)
        await history.waitUntilIdle()
        let entry = try XCTUnwrap(history.entries.first)
        let saved = try XCTUnwrap(history.loadImage(for: entry))
        XCTAssertEqual(saved.size.width, 480, accuracy: 0.05)
        XCTAssertEqual(saved.size.height, 320, accuracy: 0.05)
        XCTAssertEqual(entry.pixelWidth, 960)
        XCTAssertEqual(entry.pixelHeight, 640)
        let thumbnail = try XCTUnwrap(history.loadThumbnail(for: entry))
        XCTAssertEqual(thumbnail.size.width, 36, accuracy: 0.05)
        XCTAssertEqual(thumbnail.size.height, 24, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(ImageProbe.bitmap(from: thumbnail)).pixelsWide, 72)
        let preview = try XCTUnwrap(HistoryImageSnapshot.preview(at: history.previewURLs(for: entry)))
        XCTAssertEqual(preview.width, 480)
        XCTAssertEqual(preview.height, 320)
    }

    func testMissingLegacyPreviewDecodesABoundedOriginal() async throws {
        let id = UUID().uuidString
        let original = directory.appendingPathComponent(id + ".png")
        try HistoryImageSnapshot.Image(ImageProbe.quadrantImage(width: 2400, height: 1600)).writePNG(to: original)
        try Data("[{\"id\":\"\(id)\"}]".utf8).write(to: directory.appendingPathComponent("index.json"))
        let history = history()
        let entry = try XCTUnwrap(history.entries.first)
        let urls = history.previewURLs(for: entry)
        let image = await Task.detached { HistoryImageSnapshot.preview(at: urls) }.value
        let preview = try XCTUnwrap(image)
        XCTAssertEqual(preview.width, 480)
        XCTAssertEqual(preview.height, 320)
        XCTAssertNil(HistoryImageSnapshot.preview(at: urls, maximumPixels: 0))
    }

    func testUpdateFollowedByClearCannotRecreateFilesOrRows() async throws {
        let history = history()
        queue.suspend()
        let id = history.add(image: ImageProbe.solidImage(width: 40, height: 30))
        if let id {
            history.updateEntry(id: id, compositedImage: ImageProbe.solidImage(width: 80, height: 60), rawImage: nil, annotations: nil)
        }
        history.clear()
        queue.resume()
        XCTAssertNotNil(id)
        await history.waitUntilIdle()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertTrue(ScreenshotHistory(directory: directory).entries.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["index.json"])
    }

    func testFailedUpdatePreservesEveryPreviouslyCommittedArtifact() async throws {
        let history = history()
        let image = ImageProbe.quadrantImage(width: 40, height: 30)
        history.add(image: image, rawImage: image, annotations: [annotation()])
        await history.waitUntilIdle()
        let entry = try XCTUnwrap(history.entries.first)
        let originalIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let urls = [history.fileURL(for: entry), history.sidecarURL(for: entry, suffix: "_raw.png"),
                    history.sidecarURL(for: entry, suffix: "_annotations.json")]
        let originals = try urls.map { try Data(contentsOf: $0) }
        failure.set(true)
        var saved: Bool?
        history.updateEntry(id: entry.id, compositedImage: ImageProbe.solidImage(width: 100, height: 90),
                            rawImage: nil, annotations: nil, completion: { saved = $0 })
        await history.waitUntilIdle()
        XCTAssertEqual(saved, false)
        XCTAssertEqual(history.entries.first?.revision, entry.revision)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), originalIndex)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originals)
        XCTAssertEqual(history.loadAnnotations(for: entry)?.first?.strokeWidth, 3)
        XCTAssertEqual(ScreenshotHistory(directory: directory).entries.first?.revision, entry.revision)
    }

    func testFailedIndexDeletionRestoresTheRowAndKeepsItsImage() async throws {
        let history = history()
        history.add(image: ImageProbe.solidImage())
        await history.waitUntilIdle()
        let entry = try XCTUnwrap(history.entries.first)
        failure.set(true)
        history.removeEntry(id: entry.id)
        XCTAssertTrue(history.entries.isEmpty)
        await history.waitUntilIdle()
        XCTAssertEqual(history.entries.first?.id, entry.id)
        XCTAssertNotNil(history.loadImage(for: entry))
        XCTAssertEqual(ScreenshotHistory(directory: directory).entries.first?.id, entry.id)
    }

    func testUnencodableEditCannotReplaceAValidCapture() async throws {
        let history = history()
        history.add(image: ImageProbe.solidImage())
        await history.waitUntilIdle()
        let entry = try XCTUnwrap(history.entries.first)
        var success: Bool?
        history.updateEntry(id: entry.id, compositedImage: NSImage(size: NSSize(width: 0, height: 0)),
                            rawImage: nil, annotations: nil, completion: { success = $0 })
        XCTAssertEqual(success, false)
        XCTAssertEqual(history.entries.first?.revision, entry.revision)
        XCTAssertNotNil(history.loadImage(for: entry))
    }

    func testDisabledHistoryDoesNotReturnAnOlderCapturesIdentifier() async throws {
        let history = history()
        history.add(image: ImageProbe.solidImage())
        await history.waitUntilIdle()
        withDefaults(["historySize": 0, "historyUnlimited": false]) {
            XCTAssertNil(history.add(image: ImageProbe.solidImage()))
        }
    }

    func testSerializedUpdatesPublishOnlyCompleteMatchingRevisions() async throws {
        let history = history()
        let id = try XCTUnwrap(history.add(image: ImageProbe.solidImage(width: 20, height: 20)))
        await history.waitUntilIdle()
        queue.suspend()
        let raw = ImageProbe.quadrantImage(width: 30, height: 20)
        history.updateEntry(id: id, compositedImage: raw, rawImage: raw, annotations: [annotation()])
        history.updateEntry(id: id, compositedImage: ImageProbe.solidImage(width: 80, height: 70),
                            rawImage: nil, annotations: nil)
        queue.resume()
        await history.waitUntilIdle()
        let reloaded = ScreenshotHistory(directory: directory)
        let entry = try XCTUnwrap(reloaded.entries.first)
        XCTAssertEqual(entry.pixelWidth, 80)
        XCTAssertEqual(entry.pixelHeight, 70)
        XCTAssertFalse(entry.hasAnnotations)
        XCTAssertNil(reloaded.loadRawImage(for: entry))
        XCTAssertNil(reloaded.loadAnnotations(for: entry))
        XCTAssertEqual(try XCTUnwrap(reloaded.loadImage(for: entry)).size, CGSize(width: 80, height: 70))
        let revisions = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(id).path)
        XCTAssertEqual(revisions, [entry.revision!])
    }

    func testLegacyFlatCaptureRemainsReadableAndMigratesOnlyAfterSuccessfulEdit() async throws {
        let id = UUID().uuidString
        let original = directory.appendingPathComponent(id + ".png")
        try HistoryImageSnapshot.Image(ImageProbe.quadrantImage(width: 30, height: 20)).writePNG(to: original)
        try Data("[{\"id\":\"\(id)\",\"pixelWidth\":30,\"pixelHeight\":20}]".utf8)
            .write(to: directory.appendingPathComponent("index.json"))
        let history = history()
        let before = try XCTUnwrap(history.entries.first)
        XCTAssertNil(before.revision)
        XCTAssertNotNil(history.loadImage(for: before))
        history.updateEntry(id: id, compositedImage: ImageProbe.solidImage(width: 60, height: 40), rawImage: nil, annotations: nil)
        await history.waitUntilIdle()
        let after = try XCTUnwrap(history.entries.first)
        XCTAssertNotNil(after.revision)
        XCTAssertNotNil(history.loadImage(for: after))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(ScreenshotHistory(directory: directory).entries.first?.revision, after.revision)
    }

    func testFailedNewCaptureReportsFailureWithoutPublishingAPhantomRow() async throws {
        let reported = expectation(description: "History save failure is visible")
        ImageSaveService.onFailure = { message in
            XCTAssertTrue(message.contains("history"))
            reported.fulfill()
        }
        defer { ImageSaveService.onFailure = nil }
        let history = history()
        failure.set(true)
        var saved: Bool?
        history.add(image: ImageProbe.solidImage(), completion: { saved = $0 })
        await history.waitUntilIdle()
        await fulfillment(of: [reported], timeout: 3)
        XCTAssertEqual(saved, false)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.json").path))
    }

    func testPendingPixelBudgetRejectsAnotherCaptureAndRecoversAfterDrain() async throws {
        let history = ScreenshotHistory(directory: directory, writeQueue: queue, maximumPendingBytes: 8_192)
        let image = ImageProbe.solidImage(width: 32, height: 32)
        var errors: [String] = []
        let previous = ImageSaveService.onFailure
        ImageSaveService.onFailure = { errors.append($0) }
        defer { ImageSaveService.onFailure = previous }
        queue.suspend()
        let first = history.add(image: image)
        let second = history.add(image: image)
        var rejected: Bool?
        let third = history.add(image: image, completion: { rejected = $0 })
        let retained = history.pendingSnapshotBytes
        queue.resume()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNil(third)
        XCTAssertEqual(rejected, false)
        XCTAssertEqual(retained, 8_192)
        await history.waitUntilIdle()
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains(L("History is busy saving. Please try again shortly.")) == true)
        XCTAssertEqual(history.pendingSnapshotBytes, 0)
        XCTAssertEqual(Set(history.entries.map(\.id)), Set([first!, second!]))
        XCTAssertNotNil(history.add(image: image))
        await history.waitUntilIdle()
        XCTAssertEqual(history.entries.count, 3)
    }

    func testSaveCountLimitAndFailedPublicationReleaseTheirReservations() async throws {
        let failure = self.failure
        let history = ScreenshotHistory(directory: directory, writeQueue: queue,
            maximumPendingBytes: 1_048_576, maximumPendingSaves: 1,
            beforeIndexPublication: { try failure.check() })
        let image = ImageProbe.solidImage(width: 32, height: 32)
        let id = try XCTUnwrap(history.add(image: image))
        await history.waitUntilIdle()
        let oldIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        failure.set(true)
        queue.suspend()
        history.updateEntry(id: id, compositedImage: image, rawImage: nil, annotations: nil)
        var rejected: Bool?
        history.updateEntry(id: id, compositedImage: image, rawImage: nil, annotations: nil, completion: { rejected = $0 })
        queue.resume()
        XCTAssertEqual(rejected, false)
        await history.waitUntilIdle()
        XCTAssertEqual(history.pendingSnapshotBytes, 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), oldIndex)
        failure.set(false)
        var saved: Bool?
        history.updateEntry(id: id, compositedImage: image, rawImage: nil, annotations: nil, completion: { saved = $0 })
        await history.waitUntilIdle()
        XCTAssertEqual(saved, true)
    }

    func testOneOversizedCaptureCanSaveAloneAndAllSnapshotDataIsCounted() async throws {
        let image = ImageProbe.solidImage(width: 32, height: 32)
        let raw = ImageProbe.solidImage(width: 16, height: 16)
        let annotations = [annotation()]
        let snapshot = try HistoryImageSnapshot(image: image, rawImage: raw, annotations: annotations, editState: nil)
        XCTAssertEqual(snapshot.retainedBytes, 32 * 32 * 4 + 16 * 16 * 4 + (snapshot.annotations?.count ?? 0))
        let history = ScreenshotHistory(directory: directory, writeQueue: queue, maximumPendingBytes: 1_024)
        queue.suspend()
        let first = history.add(image: image, rawImage: raw, annotations: annotations)
        let second = history.add(image: image)
        let retained = history.pendingSnapshotBytes
        queue.resume()
        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(retained, snapshot.retainedBytes)
        await history.waitUntilIdle()
        XCTAssertEqual(history.pendingSnapshotBytes, 0)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertNotNil(history.loadRawImage(for: try XCTUnwrap(history.entries.first)))
    }
}
