import Cocoa
import XCTest

/// Editing near and past the image edge (#497 follow-up): handles that stick
/// out of the image must stay reachable, nothing new may be drawn outside it,
/// and undoing a canvas change must put annotations back with the image.
@MainActor
final class EditorCanvasMarginTests: XCTestCase {

    private func makeEditor(width: CGFloat = 300, height: CGFloat = 200) -> EditorView {
        let view = EditorView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutEditorDocument(forImageSize: NSSize(width: width, height: height))
        view.screenshotImage = ImageProbe.quadrantImage(width: Int(width), height: Int(height))
        view.applySelection(NSRect(x: 0, y: 0, width: width, height: height))
        return view
    }

    func testTheDocumentHasAMarginButCanvasCoordinatesDoNotMove() {
        let editor = makeEditor(width: 300, height: 200)
        let m = OverlayView.editorDocumentMargin
        XCTAssertEqual(editor.frame.size, NSSize(width: 300 + 2 * m, height: 200 + 2 * m))
        XCTAssertEqual(editor.bounds.origin, NSPoint(x: -m, y: -m))
        XCTAssertEqual(editor.selectionRect, NSRect(x: 0, y: 0, width: 300, height: 200),
                       "the image stays at the canvas origin")
        XCTAssertEqual(editor.captureDrawRect, editor.selectionRect)
        XCTAssertEqual(editor.viewToCanvas(NSPoint(x: -10, y: 250)), NSPoint(x: -10, y: 250))
    }

    func testExportIsStillJustTheImage() throws {
        let editor = makeEditor(width: 300, height: 200)
        // Partly outside the image: export clips it as before.
        editor.annotations = [Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 250, y: 150),
                                         endPoint: NSPoint(x: 330, y: 230), color: .black, strokeWidth: 2)]
        editor.cachedCompositedImage = nil
        let image = try XCTUnwrap(editor.compositedImage())
        XCTAssertEqual(image.size, NSSize(width: 300, height: 200))
    }

    func testAnnotationsPastTheEdgeCanStillBePickedUp() {
        let editor = makeEditor()
        let inside = NSPoint(x: 100, y: 100)
        let pastEdge = NSPoint(x: 320, y: 100)
        XCTAssertFalse(editor.pointHitsAnnotationInteraction(pastEdge), "empty margin is not interactive")

        let stamp = Annotation(tool: .stamp, startPoint: NSPoint(x: 260, y: 60),
                               endPoint: NSPoint(x: 340, y: 140), color: .clear, strokeWidth: 0)
        stamp.stampImage = ImageProbe.solidImage(width: 80, height: 80)
        editor.annotations = [stamp]
        XCTAssertTrue(editor.pointHitsAnnotationInteraction(pastEdge), "the part past the edge is still its body")
        XCTAssertTrue(editor.pointHitsAnnotationInteraction(NSPoint(x: 300, y: 100)))
        XCTAssertFalse(editor.pointHitsAnnotationInteraction(inside))
        XCTAssertTrue(editor.pointIsInSelection(inside))
        XCTAssertFalse(editor.pointIsInSelection(pastEdge))
    }

    func testCanvasLayoutFollowsImageSizeChanges() {
        let editor = makeEditor(width: 300, height: 200)
        let m = OverlayView.editorDocumentMargin
        editor.layoutEditorDocument(forImageSize: NSSize(width: 120, height: 90))
        XCTAssertEqual(editor.frame.size, NSSize(width: 120 + 2 * m, height: 90 + 2 * m))
        XCTAssertEqual(editor.bounds.origin, NSPoint(x: -m, y: -m))
    }

    func testTheOverlayIsNotResizedByTheEditorLayout() {
        let overlay = OverlayView()
        overlay.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        overlay.layoutEditorDocument(forImageSize: NSSize(width: 10, height: 10))
        XCTAssertEqual(overlay.frame.size, NSSize(width: 500, height: 400))
        XCTAssertEqual(overlay.bounds.origin, .zero)
    }

    // MARK: - Undo puts annotations back with the image

    func testUndoingAFlipUnmirrorsTheAnnotations() {
        let editor = makeEditor(width: 300, height: 200)
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 20, y: 30),
                               endPoint: NSPoint(x: 80, y: 90), color: .red, strokeWidth: 3)
        editor.annotations = [arrow]
        editor.undoStack = [.added(arrow)]

        editor.flipImageHorizontally()
        XCTAssertEqual(arrow.startPoint.x, 280, accuracy: 0.001)

        editor.undo()
        XCTAssertEqual(arrow.startPoint, NSPoint(x: 20, y: 30), "undoing the flip must unflip the arrow too")
        XCTAssertEqual(arrow.endPoint, NSPoint(x: 80, y: 90))
        XCTAssertEqual(editor.annotations.count, 1)

        editor.redo()
        XCTAssertEqual(arrow.startPoint.x, 280, accuracy: 0.001)
        XCTAssertEqual(arrow.endPoint.x, 220, accuracy: 0.001)
    }

    func testUndoingAFlipKeepsRestoredCensorsBaked() throws {
        // A censor reopened from history or a project has its bake but no
        // source image. Undo must never leave it unbaked (its preview is a
        // translucent fill that shows what it was hiding).
        let editor = makeEditor(width: 300, height: 200)
        let censor = Annotation(tool: .pixelate, startPoint: NSPoint(x: 20, y: 20),
                                endPoint: NSPoint(x: 120, y: 80), color: .black, strokeWidth: 2)
        let bake = ImageProbe.solidImage(width: 100, height: 60)
        censor.bakedBlurNSImage = bake
        XCTAssertNil(censor.sourceImage)
        editor.setAnnotations([censor])

        editor.flipImageHorizontally()
        editor.undo()
        XCTAssertNotNil(censor.bakedBlurNSImage, "undo un-baked the censor")
        XCTAssertTrue(censor.bakedBlurNSImage === bake, "the bake matching the restored geometry is reused")
        XCTAssertEqual(censor.startPoint, NSPoint(x: 20, y: 20))
        editor.redo()
        XCTAssertNotNil(censor.bakedBlurNSImage, "redo un-baked the censor")
    }

    func testARestoredCensorCanBeMovedWithoutLosingItsPixelation() {
        // Censors reopened from history/projects (or moved over from the
        // overlay) arrive baked but without a source. Moving one re-bakes it,
        // which needs the editor's image.
        let editor = makeEditor(width: 300, height: 200)
        let censor = Annotation(tool: .pixelate, startPoint: NSPoint(x: 20, y: 20),
                                endPoint: NSPoint(x: 120, y: 80), color: .black, strokeWidth: 2)
        censor.bakedBlurNSImage = ImageProbe.solidImage(width: 100, height: 60)
        let originalBake = censor.bakedBlurNSImage
        editor.setAnnotations([censor])
        XCTAssertTrue(censor.bakedBlurNSImage === originalBake, "restoring keeps the existing bake")
        XCTAssertNotNil(censor.sourceImage)

        censor.move(dx: 30, dy: 10)
        XCTAssertNil(censor.bakedBlurNSImage)
        censor.bakePixelate()
        XCTAssertNotNil(censor.bakedBlurNSImage, "moved censor re-baked from the editor image")
    }

    func testFlippingKeepsEffectSourcesOnTheCurrentImage() {
        let editor = makeEditor(width: 300, height: 200)
        let censor = Annotation(tool: .pixelate, startPoint: NSPoint(x: 20, y: 20),
                                endPoint: NSPoint(x: 120, y: 80), color: .black, strokeWidth: 2)
        censor.bakedBlurNSImage = ImageProbe.solidImage(width: 100, height: 60)
        editor.setAnnotations([censor])
        editor.flipImageHorizontally()
        XCTAssertTrue(censor.sourceImage === editor.screenshotImage, "later re-bakes read the flipped pixels")
        editor.undo()
        XCTAssertTrue(censor.sourceImage === editor.screenshotImage)
    }

    func testUndoingCanvasGrowthKeepsCensorsBaked() {
        let editor = makeEditor(width: 300, height: 200)
        let censor = Annotation(tool: .pixelate, startPoint: NSPoint(x: 20, y: 20),
                                endPoint: NSPoint(x: 120, y: 80), color: .black, strokeWidth: 2)
        censor.bakedBlurNSImage = ImageProbe.solidImage(width: 100, height: 60)
        let stamp = Annotation(tool: .stamp, startPoint: NSPoint(x: -50, y: 20),
                               endPoint: NSPoint(x: 50, y: 120), color: .clear, strokeWidth: 0)
        stamp.stampImage = ImageProbe.solidImage(width: 100, height: 100)
        editor.setAnnotations([censor, stamp])
        editor.expandCanvasToFitAnnotations()
        editor.undo()
        XCTAssertNotNil(censor.bakedBlurNSImage)
        editor.redo()
        XCTAssertNotNil(censor.bakedBlurNSImage)
    }

    func testUndoingCanvasGrowthMovesAnnotationsBack() {
        let editor = makeEditor(width: 300, height: 200)
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 20, y: 30),
                               endPoint: NSPoint(x: 80, y: 90), color: .red, strokeWidth: 3)
        // An image pasted so it hangs off the left edge.
        let stamp = Annotation(tool: .stamp, startPoint: NSPoint(x: -50, y: 20),
                               endPoint: NSPoint(x: 50, y: 120), color: .clear, strokeWidth: 0)
        stamp.stampImage = ImageProbe.solidImage(width: 100, height: 100)
        editor.annotations = [arrow, stamp]
        editor.undoStack = [.added(arrow), .added(stamp)]

        editor.expandCanvasToFitAnnotations()
        XCTAssertEqual(editor.selectionRect.width, 350, accuracy: 0.5)
        XCTAssertEqual(arrow.startPoint.x, 70, accuracy: 0.5, "everything shifts with the new origin")

        editor.undo()
        XCTAssertEqual(editor.screenshotImage?.size, NSSize(width: 300, height: 200))
        XCTAssertEqual(arrow.startPoint, NSPoint(x: 20, y: 30), "the arrow must line up with the image again")
        XCTAssertEqual(stamp.startPoint, NSPoint(x: -50, y: 20))
    }
}

/// Arrange screenshots precisely (#497 comment): arrow keys nudge the
/// selection, Shift for 10 pt, and a run of nudges undoes in one step.
@MainActor
final class AnnotationNudgeTests: XCTestCase {
    private func makeEditor() -> EditorView {
        let view = EditorView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        view.layoutEditorDocument(forImageSize: NSSize(width: 300, height: 200))
        view.screenshotImage = ImageProbe.quadrantImage(width: 300, height: 200)
        view.applySelection(NSRect(x: 0, y: 0, width: 300, height: 200))
        return view
    }

    private func arrow(_ keyCode: UInt16, shift: Bool = false) -> NSEvent {
        // Arrow keys carry the function-key private-use characters.
        let character: Int = [123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700][Int(keyCode)]!
        return TestKeyEvent.keyDown(characters: String(UnicodeScalar(character)!), keyCode: keyCode,
                                    modifiers: shift ? [.shift, .function, .numericPad] : [.function, .numericPad])
    }

    func testArrowsNudgeTheSelectionAndUndoAsOneStep() {
        let editor = makeEditor()
        let rect = Annotation(tool: .rectangle, startPoint: NSPoint(x: 50, y: 50), endPoint: NSPoint(x: 100, y: 90),
                              color: .red, strokeWidth: 3)
        editor.setAnnotations([rect])
        let depth = editor.undoStack.count

        // Nothing selected: arrows do nothing to annotations.
        editor.keyDown(with: arrow(124))
        XCTAssertEqual(rect.startPoint, NSPoint(x: 50, y: 50))

        editor.selectAnnotations([rect])
        editor.keyDown(with: arrow(124))
        editor.keyDown(with: arrow(124))
        editor.keyDown(with: arrow(126, shift: true))
        XCTAssertEqual(rect.startPoint, NSPoint(x: 52, y: 60))
        XCTAssertEqual(editor.undoStack.count, depth + 1, "a run of nudges is one undo step")

        editor.undo()
        XCTAssertEqual(rect.startPoint, NSPoint(x: 50, y: 50))
        XCTAssertEqual(editor.annotations.count, 1)
    }

    func testNudgesAfterASaveStillCountAsChanges() {
        // The editor compares undo identities to decide whether to warn on
        // close. A coalesced nudge adds no undo entry but must still change it.
        let editor = makeEditor()
        let rect = Annotation(tool: .rectangle, startPoint: NSPoint(x: 50, y: 50), endPoint: NSPoint(x: 100, y: 90),
                              color: .red, strokeWidth: 3)
        editor.setAnnotations([rect])
        editor.selectAnnotations([rect])
        var changes = 0
        editor.onContentChanged = { changes += 1 }
        editor.keyDown(with: arrow(124))
        let savedIdentity = editor.undoStateIdentity
        let changesAtSave = changes
        editor.keyDown(with: arrow(124))
        XCTAssertNotEqual(editor.undoStateIdentity, savedIdentity, "a later nudge would be lost on close")
        XCTAssertGreaterThan(changes, changesAtSave)
        editor.undo()
        XCTAssertEqual(rect.startPoint, NSPoint(x: 50, y: 50), "still one undo step")
    }

    func testNudgingSeveralAnnotationsUndoesTogether() {
        let editor = makeEditor()
        let a = Annotation(tool: .rectangle, startPoint: NSPoint(x: 10, y: 10), endPoint: NSPoint(x: 40, y: 40),
                           color: .red, strokeWidth: 3)
        let b = Annotation(tool: .arrow, startPoint: NSPoint(x: 100, y: 100), endPoint: NSPoint(x: 150, y: 120),
                           color: .red, strokeWidth: 3)
        editor.setAnnotations([a, b])
        let depth = editor.undoStack.count
        editor.selectAnnotations([a, b])
        editor.keyDown(with: arrow(125, shift: true))
        editor.keyDown(with: arrow(123))
        XCTAssertEqual(a.startPoint, NSPoint(x: 9, y: 0))
        XCTAssertEqual(b.startPoint, NSPoint(x: 99, y: 90))
        XCTAssertEqual(editor.undoStack.count, depth + 1)

        editor.undo()
        XCTAssertEqual(a.startPoint, NSPoint(x: 10, y: 10))
        XCTAssertEqual(b.startPoint, NSPoint(x: 100, y: 100), "one undo puts every nudged annotation back")
        editor.redo()
        XCTAssertEqual(a.startPoint, NSPoint(x: 9, y: 0))
        XCTAssertEqual(b.startPoint, NSPoint(x: 99, y: 90))
    }
}
