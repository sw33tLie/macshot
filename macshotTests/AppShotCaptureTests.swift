import Cocoa
import CoreGraphics
import Foundation
import XCTest

final class AppShotCaptureTests: XCTestCase {
    func testFrontmostWindowPrefersSourceApplicationAndLargestDisplayOverlap() {
        let auxiliary = WindowSelectionCandidate(id: 1, ownerPID: 42, layer: 0,
            bounds: CGRect(x: 408, y: 108, width: 60, height: 20), title: "Window")
        let source = WindowSelectionCandidate(id: 2, ownerPID: 42, layer: 0,
            bounds: CGRect(x: 400, y: 100, width: 800, height: 600), title: "Source")
        let other = WindowSelectionCandidate(id: 3, ownerPID: 77, layer: 0,
            bounds: CGRect(x: 0, y: 0, width: 900, height: 600), title: "Other")
        let displays = [
            DisplaySelectionCandidate(id: 10, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            DisplaySelectionCandidate(id: 11, bounds: CGRect(x: 1000, y: 0, width: 1000, height: 800))
        ]
        let result = FrontmostWindowSelection.select(windows: [auxiliary, source, other],
            displays: displays, ownPID: 99, preferredPID: 42)
        XCTAssertEqual(result?.window.id, 2)
        XCTAssertEqual(result?.displayID, 10)
    }

    func testContextDocumentContainsSourceAndRecognizedText() {
        let payload = ContextCapturePayload(applicationName: "TextEdit", bundleIdentifier: "com.apple.TextEdit",
            windowTitle: "Sample", capturedAt: Date(timeIntervalSince1970: 0),
            recognizedText: "Visible OCR line")
        XCTAssertTrue(payload.markdown.contains("# App Shot"))
        XCTAssertTrue(payload.markdown.contains("- Bundle ID: com.apple.TextEdit"))
        XCTAssertTrue(payload.markdown.contains("- Window: Sample"))
        XCTAssertTrue(payload.markdown.contains("Visible OCR line"))
    }

    @MainActor
    func testClipboardPublishesImageThenContextAsSeparateStates() async {
        let board = NSPasteboard(name: NSPasteboard.Name("AppShotTest-\(UUID().uuidString)"))
        defer { board.clearContents() }
        let pixels = Data([0x89, 0x50, 0x4e, 0x47])
        let generation = AppShotClipboardPublisher.beginPublication()
        var sawImageState = false
        let succeeded = await AppShotClipboardPublisher.publish(
            to: board, generation: generation, backingURL: nil,
            pngData: pixels, tiffData: nil, markdown: "# App Shot",
            wait: { sawImageState = board.data(forType: .png) == pixels }
        )
        XCTAssertTrue(succeeded)
        XCTAssertTrue(sawImageState)
        XCTAssertEqual(board.string(forType: .string), "# App Shot")
        XCTAssertNil(board.data(forType: .png))
    }

    @MainActor
    func testThumbnailCallbackPrecedesRecognitionAndPublication() async {
        var events: [String] = []
        let coordinator = AppShotCaptureCoordinator<Int, String>(
            captureImage: { _ in events.append("capture"); return "pixels" },
            onImageCaptured: { _, _ in events.append("thumbnail") },
            recognizeText: { _ in events.append("ocr"); return "text" },
            publish: { _ in events.append("clipboard"); return true }
        )
        let outcome = await coordinator.capture(target: 1)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(events, ["capture", "thumbnail", "ocr", "clipboard"])
    }
}
