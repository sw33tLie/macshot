import Foundation
import XCTest

final class RecordingSessionStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRepeatedDisplayNamesNeverOverwriteAnotherTake() throws {
        let first = try RecordingSessionStore(filename: "Same recording", root: root)
        let second = try RecordingSessionStore(filename: "Same recording", root: root)
        XCTAssertNotEqual(first.mediaURL, second.mediaURL)
        XCTAssertEqual(first.mediaURL.lastPathComponent, second.mediaURL.lastPathComponent)
        try Data("original take".utf8).write(to: first.mediaURL)
        try Data("next take".utf8).write(to: second.mediaURL)
        XCTAssertEqual(try Data(contentsOf: first.mediaURL), Data("original take".utf8))
    }

    func testOnlyAnEmptyCancelledSessionCanBeRemoved() throws {
        let empty = try RecordingSessionStore(filename: "Empty", root: root)
        empty.removeIfEmpty()
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.directoryURL.path))
        let partial = try RecordingSessionStore(filename: "Partial", root: root)
        let bytes = Data("incomplete but recoverable media".utf8)
        try bytes.write(to: partial.mediaURL)
        try partial.update(status: "interrupted", error: CocoaError(.fileWriteOutOfSpace))
        partial.removeIfEmpty()
        XCTAssertEqual(try Data(contentsOf: partial.mediaURL), bytes)
        let data = try Data(contentsOf: partial.directoryURL.appendingPathComponent("session.plist"))
        let metadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(metadata["status"] as? String, "interrupted")
        XCTAssertNotNil(metadata["error"])
    }

    func testNamesAreDisplayNamesAndFitTheFilesystem() throws {
        for name in ["Vacation / Demo", String(repeating: "🎬", count: 500), "", "  "] {
            let session = try RecordingSessionStore(filename: name, root: root)
            XCTAssertEqual(session.mediaURL.deletingLastPathComponent(), session.directoryURL)
            XCTAssertLessThanOrEqual(session.mediaURL.lastPathComponent.utf8.count, 204)
            try Data("take".utf8).write(to: session.mediaURL)
        }
    }

    func testOwnershipDoesNotIncludeSiblingDirectoriesOrExternalSources() {
        let root = RecordingSessionStore.rootURL
        XCTAssertTrue(RecordingSessionStore.owns(root.appendingPathComponent("session/take.mp4")))
        XCTAssertFalse(RecordingSessionStore.owns(root.deletingLastPathComponent().appendingPathComponent("Recordings-old/take.mp4")))
        XCTAssertFalse(RecordingSessionStore.owns(URL(fileURLWithPath: "/tmp/my-video.mp4")))
    }

    func testDirectSessionNamesRemoveControlsAndProduceReadableManifests() throws {
        for name in ["Take\0one", "Take\u{1}\u{7F}\u{85}two", "\u{1}\u{7F}", " . .  "] {
            let session = try RecordingSessionStore(filename: name, root: root)
            XCTAssertFalse(session.mediaURL.lastPathComponent.unicodeScalars.contains {
                $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
            })
            let bytes = Data("recording data".utf8)
            try bytes.write(to: session.mediaURL)
            XCTAssertEqual(try Data(contentsOf: session.mediaURL), bytes)
            let manifest = try Data(contentsOf: session.directoryURL.appendingPathComponent("session.plist"))
            let metadata = try XCTUnwrap(PropertyListSerialization.propertyList(from: manifest, format: nil) as? [String: Any])
            XCTAssertEqual(metadata["filename"] as? String, session.mediaURL.lastPathComponent)
        }
    }
}
