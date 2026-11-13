import Cocoa
import XCTest

/// The editor's top-bar drag handle (#514): drag the current image into another
/// app as a file, or click it to copy.
@MainActor
final class EditorDragHandleTests: XCTestCase {

    // MARK: - Dragged file

    func testDragFileHoldsTheAnnotatedImageAtFullResolution() throws {
        let editor = EditorView()
        editor.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        editor.screenshotImage = ImageProbe.quadrantImage(width: 300, height: 200)
        editor.applySelection(NSRect(x: 0, y: 0, width: 300, height: 200))
        editor.annotations = [Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 40, y: 30),
                                         endPoint: NSPoint(x: 160, y: 120), color: .black, strokeWidth: 2)]
        editor.cachedCompositedImage = nil

        try withDefaults(["imageFormat": "png", "filenameTemplate": "drag-{random}"]) {
            let image = try XCTUnwrap(editor.captureSelectedRegion())
            let url = try XCTUnwrap(EditorDragHandleView.writeDragFile(for: image))
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            XCTAssertEqual(url.pathExtension, "png")
            XCTAssertTrue(url.lastPathComponent.hasPrefix("drag-"), "uses the user's filename template")
            XCTAssertTrue(url.path.hasPrefix(TmpScratchDirectory.url.path), "lives in the private share scratch folder")

            let decoded = try XCTUnwrap(NSImage(contentsOf: url))
            let rep = try XCTUnwrap(ImageProbe.bitmap(from: decoded))
            XCTAssertEqual(rep.pixelsWide, 300)
            XCTAssertEqual(rep.pixelsHigh, 200)

            // Inside the annotation (AppKit y=100 → bitmap row 100 from the top).
            let annotated = try XCTUnwrap(rep.colorAt(x: 100, y: 100))
            XCTAssertLessThan(annotated.redComponent + annotated.greenComponent + annotated.blueComponent, 0.1,
                              "the annotation is baked into the dropped file")
            // Outside it, the screenshot is untouched (top-right quadrant is white).
            let untouched = try XCTUnwrap(rep.colorAt(x: 250, y: 20))
            XCTAssertGreaterThan(untouched.redComponent, 0.9)
            XCTAssertGreaterThan(untouched.blueComponent, 0.9)
        }
    }

    func testDragFilesNeverOverwriteEachOther() throws {
        try withDefaults(["imageFormat": "png", "filenameTemplate": "same-name"]) {
            let image = ImageProbe.solidImage(width: 8, height: 8)
            let first = try XCTUnwrap(EditorDragHandleView.writeDragFile(for: image))
            let second = try XCTUnwrap(EditorDragHandleView.writeDragFile(for: image))
            defer {
                try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
            }
            XCTAssertEqual(first.lastPathComponent, second.lastPathComponent)
            XCTAssertNotEqual(first, second, "an earlier drop must keep its file")
        }
    }

    func testDragFileFollowsTheConfiguredFormat() throws {
        try withDefaults(["imageFormat": "jpeg"]) {
            let url = try XCTUnwrap(EditorDragHandleView.writeDragFile(for: ImageProbe.solidImage(width: 8, height: 8)))
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            XCTAssertEqual(url.pathExtension, "jpg")
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8], "JPEG data, not PNG with a .jpg name")
        }
    }

    // MARK: - Preview size

    func testPreviewKeepsAspectRatioWithinTheCap() {
        XCTAssertEqual(EditorDragHandleView.previewSize(for: NSSize(width: 2800, height: 1400)),
                       NSSize(width: 140, height: 70))
        XCTAssertEqual(EditorDragHandleView.previewSize(for: NSSize(width: 100, height: 4000)),
                       NSSize(width: 4, height: 140))
        XCTAssertEqual(EditorDragHandleView.previewSize(for: NSSize(width: 60, height: 40)),
                       NSSize(width: 60, height: 40), "small images are not scaled up")
        XCTAssertEqual(EditorDragHandleView.previewSize(for: .zero), NSSize(width: 140, height: 140))
    }

    // MARK: - Click vs drag

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testClickWithoutMovingCopies() {
        let handle = EditorDragHandleView(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        var clicks = 0
        var provided = 0
        handle.onClick = { clicks += 1 }
        handle.imageProvider = { provided += 1; return nil }

        handle.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 20, y: 11)))
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 21, y: 12)))
        handle.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 21, y: 12)))

        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(provided, 0, "a jitter below the threshold is still a click")
    }

    func testReleasingOutsideTheHandleDoesNotCopy() {
        let handle = EditorDragHandleView(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        var clicks = 0
        handle.onClick = { clicks += 1 }
        handle.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 20, y: 11)))
        handle.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 20, y: 60)))
        XCTAssertEqual(clicks, 0)
    }

    func testDraggingPastTheThresholdStartsADragNotACopy() {
        let handle = EditorDragHandleView(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        var clicks = 0
        var provided = 0
        var ended: [Bool] = []
        handle.onClick = { clicks += 1 }
        // No image: the drag gives up cleanly instead of starting a session.
        handle.imageProvider = { provided += 1; return nil }
        handle.onDragEnded = { ended.append($0) }

        handle.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 20, y: 11)))
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 30, y: 11)))
        handle.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 40, y: 11)))
        handle.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 20, y: 11)))

        XCTAssertEqual(provided, 1, "one drag per press")
        XCTAssertEqual(ended, [false], "a failed drag reports that nothing was dropped")
        XCTAssertEqual(clicks, 0, "a drag never also copies")
    }
}
