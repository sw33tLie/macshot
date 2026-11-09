import Foundation
import XCTest

final class AtomicMediaSaveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testCopyPreservesOriginalAndPublishesOnlyAfterCompletion() throws {
        let source = directory.appendingPathComponent("source.mp4")
        let destination = directory.appendingPathComponent("saved.mp4")
        let media = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        let previous = Data("previous recording".utf8)
        try media.write(to: source)
        try previous.write(to: destination)
        let save = try AtomicMediaSave(destinationURL: destination)
        try save.copySource(source)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        try save.commit()
        XCTAssertEqual(try Data(contentsOf: destination), media)
        XCTAssertEqual(try Data(contentsOf: source), media)
        // A cloned destination must still be independently writable.
        try previous.write(to: destination)
        XCTAssertEqual(try Data(contentsOf: source), media)
    }

    func testFallbackCopyUsesCompleteChunksAndPreservesBytes() throws {
        let source = directory.appendingPathComponent("large.mp4")
        let destination = directory.appendingPathComponent("copy.mp4")
        let data = Data(repeating: 0x5a, count: 3 * 1024 * 1024 + 123)
        try data.write(to: source)
        let save = try AtomicMediaSave(destinationURL: destination)
        try save.copySource(source, allowClone: false)
        try save.commit()
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testCancellationInterruptsFallbackCopyBeforePublishing() throws {
        let source = directory.appendingPathComponent("large.mp4")
        let destination = directory.appendingPathComponent("copy.mp4")
        let data = Data(repeating: 0x5a, count: 4 * 1024 * 1024)
        let previous = Data("previous take".utf8)
        try data.write(to: source); try previous.write(to: destination)
        let save = try AtomicMediaSave(destinationURL: destination)
        let cancellation = MediaExportCancellation()
        XCTAssertThrowsError(try save.copySource(source, allowClone: false,
            checkCancellation: { try cancellation.check() },
            progress: { if $0 > 0 { cancellation.cancel() } })) { XCTAssertTrue($0 is CancellationError) }
        let partialSize = try FileManager.default.attributesOfItem(atPath: save.stagingURL.path)[.size] as? Int
        XCTAssertEqual(partialSize, 1024 * 1024)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testCancelledPublicationKeepsThePreviousDestination() throws {
        let destination = directory.appendingPathComponent("copy.mp4")
        let previous = Data("previous take".utf8)
        try previous.write(to: destination)
        let save = try AtomicMediaSave(destinationURL: destination)
        try Data("complete new take".utf8).write(to: save.stagingURL)
        let cancellation = MediaExportCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try save.commit(beforePublish: { try cancellation.beginPublication() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    func testMissingAndEmptyExportsNeverReplaceDestination() throws {
        let destination = directory.appendingPathComponent("saved.mp4")
        let previous = Data("only good take".utf8)
        try previous.write(to: destination)
        let save = try AtomicMediaSave(destinationURL: destination)
        XCTAssertThrowsError(try save.commit())
        try Data().write(to: save.stagingURL)
        XCTAssertThrowsError(try save.commit())
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    func testCopyFailureAndAbandonedPartialOutputLeaveDestinationIntact() throws {
        let destination = directory.appendingPathComponent("saved.mp4")
        let previous = Data("only good take".utf8)
        try previous.write(to: destination)
        var save: AtomicMediaSave? = try AtomicMediaSave(destinationURL: destination)
        XCTAssertThrowsError(try save?.copySource(directory.appendingPathComponent("missing.mp4")))
        try Data("incomplete encoding".utf8).write(to: XCTUnwrap(save?.stagingURL))
        save = nil
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    func testFailedRenameLeavesBothDestinationAndStagedMediaAvailable() throws {
        let destination = directory.appendingPathComponent("folder.mp4")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = destination.appendingPathComponent("do not remove.txt")
        try Data("original".utf8).write(to: original)
        let save = try AtomicMediaSave(destinationURL: destination)
        let media = Data("finished export".utf8)
        try media.write(to: save.stagingURL)
        XCTAssertThrowsError(try save.commit())
        XCTAssertEqual(try Data(contentsOf: save.stagingURL), media)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }

    func testSeparateJobsHaveIndependentStagingEvenWithSameDestination() throws {
        let destination = directory.appendingPathComponent("saved.mp4")
        let first = try AtomicMediaSave(destinationURL: destination)
        let second = try AtomicMediaSave(destinationURL: destination)
        XCTAssertNotEqual(first.stagingURL, second.stagingURL)
        try Data("first".utf8).write(to: first.stagingURL)
        try Data("second".utf8).write(to: second.stagingURL)
        try first.commit()
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
        try second.commit()
        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))
    }

    func testExclusivePublicationProtectsAFileCreatedAfterDestinationWasChosen() throws {
        let destination = directory.appendingPathComponent("saved.mp4")
        let save = try AtomicMediaSave(destinationURL: destination)
        try Data("new take".utf8).write(to: save.stagingURL)
        try Data("another app's file".utf8).write(to: destination)
        XCTAssertThrowsError(try save.commit(overwritingExisting: false))
        XCTAssertEqual(try Data(contentsOf: destination), Data("another app's file".utf8))
    }

    func testTemporaryInputSurvivesEditorCloseUntilItsLastReaderFinishes() throws {
        let source = directory.appendingPathComponent("temporary.mp4")
        try Data("input".utf8).write(to: source)
        let cleanup = DispatchQueue(label: "macshot.tests.temporary-cleanup")
        var editor: TemporaryMediaLease? = TemporaryMediaLease(url: source, cleanupQueue: cleanup)
        var reader = editor
        editor = nil
        cleanup.sync {}
        XCTAssertNotNil(reader)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        reader = nil
        cleanup.sync {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testSavingBackToTemporaryInputTransfersOwnershipOnlyForThatPath() throws {
        for saveToSource in [false, true] {
            let source = directory.appendingPathComponent(UUID().uuidString + ".mp4")
            let destination = saveToSource ? source : directory.appendingPathComponent("saved.mp4")
            try Data("temporary input".utf8).write(to: source)
            let cleanup = DispatchQueue(label: "macshot.tests.saved-cleanup")
            var lease: TemporaryMediaLease? = TemporaryMediaLease(url: source, cleanupQueue: cleanup)
            let transaction = try AtomicMediaSave(destinationURL: destination)
            let final = Data("completed export".utf8)
            try final.write(to: transaction.stagingURL)
            try transaction.commit()
            lease?.preserve(ifSavedAt: destination)
            lease = nil
            cleanup.sync {}
            XCTAssertEqual(try Data(contentsOf: destination), final)
            XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), saveToSource)
        }
    }
}
