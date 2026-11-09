import Cocoa
import XCTest

/// The editor is the same canvas in a different coordinate world: the
/// screenshot fills `selectionRect` inside a scroll view instead of covering
/// the screen. CLAUDE.md calls these rules critical because getting them wrong
/// puts annotations somewhere other than where the user drew them — and the
/// damage only shows up in the exported image.
@MainActor
final class EditorCanvasTests: XCTestCase {

    private func makeEditor(width: CGFloat = 300, height: CGFloat = 200) -> EditorView {
        let view = EditorView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.screenshotImage = ImageProbe.quadrantImage(width: Int(width), height: Int(height))
        view.applySelection(NSRect(x: 0, y: 0, width: width, height: height))
        return view
    }

    // MARK: - Mode

    func testTheEditorKnowsItIsTheEditor() {
        let editor = makeEditor()
        XCTAssertTrue(editor.isEditorMode)
        XCTAssertTrue(editor.isInsideScrollView, "the editor lets NSScrollView own zoom and pan")
    }

    func testTheOverlayIsNotInEditorMode() {
        let overlay = OverlayView()
        XCTAssertFalse(overlay.isEditorMode)
        XCTAssertFalse(overlay.isInsideScrollView)
    }

    // MARK: - Coordinate rules

    func testCaptureDrawRectFollowsTheSelectionNotTheViewBounds() {
        let editor = makeEditor(width: 300, height: 200)
        editor.applySelection(NSRect(x: 0, y: 0, width: 180, height: 120))
        XCTAssertEqual(editor.captureDrawRect, NSRect(x: 0, y: 0, width: 180, height: 120),
                       "the image occupies the selection, so annotations map against that")
        XCTAssertNotEqual(editor.captureDrawRect, editor.bounds)
    }

    func testCoordinateTransformsAreIdentityInsideAScrollView() {
        // NSScrollView already applies zoom and pan, so the view must not
        // apply them a second time.
        let editor = makeEditor()
        editor.zoomLevel = 3
        editor.zoomAnchorCanvas = NSPoint(x: 40, y: 50)
        editor.zoomAnchorView = NSPoint(x: 90, y: 10)

        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 123.5, y: 45.25), NSPoint(x: -20, y: 400)] {
            XCTAssertEqual(editor.viewToCanvas(point), point, "viewToCanvas double-applied the zoom")
            XCTAssertEqual(editor.canvasToView(point), point, "canvasToView double-applied the zoom")
        }
    }

    func testCompositedImageIsTheSizeOfTheCaptureNotTheView() throws {
        let editor = makeEditor(width: 400, height: 300)
        editor.applySelection(NSRect(x: 0, y: 0, width: 220, height: 140))
        editor.annotations = [Annotation(tool: .rectangle, startPoint: NSPoint(x: 10, y: 10),
                                         endPoint: NSPoint(x: 80, y: 60), color: .red, strokeWidth: 3)]
        editor.cachedCompositedImage = nil

        let image = try XCTUnwrap(editor.compositedImage())
        XCTAssertEqual(image.size, NSSize(width: 220, height: 140),
                       "the export is the size of the capture, not of the scrollable view")
    }

    func testAnUnannotatedCaptureIsReturnedUntouched() throws {
        // Re-encoding a capture nobody drew on would cost quality for nothing.
        let editor = makeEditor(width: 320, height: 240)
        let image = try XCTUnwrap(editor.compositedImage())
        XCTAssertTrue(image === editor.screenshotImage, "expected the original image, not a copy")
    }

    // MARK: - Annotations behave the same as in the overlay

    func testAnAnnotationLandsAtTheSameCanvasPointInBothModes() throws {
        let overlay = OverlayView()
        overlay.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        overlay.screenshotImage = ImageProbe.quadrantImage(width: 300, height: 200)

        let editor = makeEditor(width: 300, height: 200)

        let start = NSPoint(x: 40, y: 30)
        let end = NSPoint(x: 160, y: 120)
        for canvas in [overlay, editor] {
            let ann = Annotation(tool: .filledRectangle, startPoint: start, endPoint: end,
                                 color: .black, strokeWidth: 2)
            canvas.annotations = [ann]
            canvas.cachedCompositedImage = nil
        }

        let overlayImage = try XCTUnwrap(overlay.compositedImage())
        let editorImage = try XCTUnwrap(editor.compositedImage())
        XCTAssertEqual(overlayImage.size, editorImage.size)

        // The same annotation covers the same pixels in both.
        let probe = NSPoint(x: 100, y: 100)
        let overlayPixel = ImageProbe.pixelColor(overlayImage, x: Int(probe.x), y: Int(probe.y))
        let editorPixel = ImageProbe.pixelColor(editorImage, x: Int(probe.x), y: Int(probe.y))
        XCTAssertEqual(overlayPixel?.redComponent ?? -1, editorPixel?.redComponent ?? -2, accuracy: 0.02)
        XCTAssertEqual(overlayPixel?.blueComponent ?? -1, editorPixel?.blueComponent ?? -2, accuracy: 0.02)
    }

    func testUndoWorksTheSameInTheEditor() {
        let editor = makeEditor()
        let ann = Annotation(tool: .arrow, startPoint: .zero, endPoint: NSPoint(x: 50, y: 50),
                             color: .red, strokeWidth: 3)
        editor.annotations = [ann]
        editor.undoStack = [.added(ann)]

        editor.undo()
        XCTAssertTrue(editor.annotations.isEmpty)
        editor.redo()
        XCTAssertEqual(editor.annotations.count, 1)
    }

    func testEveryToolRendersInTheEditorToo() throws {
        let editor = makeEditor(width: 200, height: 150)
        for tool in AnnotationTool.allCases {
            let ann = Annotation(tool: tool, startPoint: NSPoint(x: 20, y: 20),
                                 endPoint: NSPoint(x: 150, y: 120), color: .systemGreen, strokeWidth: 5)
            ann.text = "sample"
            ann.number = 2
            ann.points = [NSPoint(x: 20, y: 20), NSPoint(x: 80, y: 90), NSPoint(x: 150, y: 120)]
            editor.annotations = [ann]
            editor.cachedCompositedImage = nil
            XCTAssertNotNil(editor.compositedImage(), "\(tool) failed to render in the editor")
        }
    }

    func testResizingTheSelectionChangesTheCaptureRect() {
        let editor = makeEditor(width: 400, height: 400)
        editor.annotations = [Annotation(tool: .ellipse, startPoint: NSPoint(x: 5, y: 5),
                                         endPoint: NSPoint(x: 50, y: 30), color: .blue, strokeWidth: 2)]
        editor.applySelection(NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(editor.captureDrawRect.size, NSSize(width: 100, height: 100))

        // Cropping in the editor replaces the selection with the new size.
        editor.applySelection(NSRect(x: 0, y: 0, width: 60, height: 40))
        editor.cachedCompositedImage = nil
        XCTAssertEqual(editor.captureDrawRect.size, NSSize(width: 60, height: 40))
        XCTAssertEqual(editor.compositedImage()?.size, NSSize(width: 60, height: 40))
    }
}
