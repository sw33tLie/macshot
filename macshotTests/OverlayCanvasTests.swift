import Cocoa
import XCTest

/// The overlay canvas is the surface every annotation is drawn on. It builds
/// and draws fine without a window, so the coordinate rules and the undo stack
/// — the two things that quietly corrupt a capture when they're wrong — can be
/// tested directly.
@MainActor
final class OverlayCanvasTests: XCTestCase {

    private func makeOverlay(width: CGFloat = 400, height: CGFloat = 300) -> OverlayView {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.screenshotImage = ImageProbe.quadrantImage(width: Int(width), height: Int(height))
        return view
    }

    private func annotation(_ tool: AnnotationTool = .rectangle,
                            from start: NSPoint = NSPoint(x: 10, y: 10),
                            to end: NSPoint = NSPoint(x: 100, y: 80)) -> Annotation {
        Annotation(tool: tool, startPoint: start, endPoint: end, color: .red, strokeWidth: 3)
    }

    // MARK: - Coordinate rules

    func testCaptureDrawRectIsTheWholeViewInOverlayMode() {
        let view = makeOverlay()
        XCTAssertFalse(view.isEditorMode)
        XCTAssertEqual(view.captureDrawRect, view.bounds,
                       "the overlay draws the screenshot across the whole screen")
    }

    func testCanvasAndViewCoordinatesAgreeAtDefaultZoom() {
        let view = makeOverlay()
        let point = NSPoint(x: 123.5, y: 67.25)
        XCTAssertEqual(view.viewToCanvas(point), point)
        XCTAssertEqual(view.canvasToView(point), point)
    }

    func testCoordinateConversionRoundTripsWhileZoomed() {
        let view = makeOverlay()
        view.zoomLevel = 2.5
        view.zoomAnchorCanvas = NSPoint(x: 120, y: 90)
        view.zoomAnchorView = NSPoint(x: 200, y: 150)

        for point in [NSPoint(x: 0, y: 0), NSPoint(x: 200, y: 150),
                      NSPoint(x: 399, y: 299), NSPoint(x: -40, y: 500)] {
            let roundTripped = view.canvasToView(view.viewToCanvas(point))
            XCTAssertEqual(roundTripped.x, point.x, accuracy: 0.0001, "x drifted for \(point)")
            XCTAssertEqual(roundTripped.y, point.y, accuracy: 0.0001, "y drifted for \(point)")
        }
    }

    func testTheZoomAnchorStaysPutWhileZooming() {
        let view = makeOverlay()
        let anchorCanvas = NSPoint(x: 50, y: 60)
        let anchorView = NSPoint(x: 150, y: 160)
        view.zoomAnchorCanvas = anchorCanvas
        view.zoomAnchorView = anchorView

        for zoom in [1.0, 1.5, 4.0, 8.0] as [CGFloat] {
            view.zoomLevel = zoom
            let mapped = view.canvasToView(anchorCanvas)
            XCTAssertEqual(mapped.x, anchorView.x, accuracy: 0.0001, "anchor moved at \(zoom)x")
            XCTAssertEqual(mapped.y, anchorView.y, accuracy: 0.0001, "anchor moved at \(zoom)x")
        }
    }

    func testZoomingScalesDistancesFromTheAnchor() {
        let view = makeOverlay()
        view.zoomAnchorCanvas = NSPoint(x: 100, y: 100)
        view.zoomAnchorView = NSPoint(x: 100, y: 100)
        view.zoomLevel = 2

        let mapped = view.canvasToView(NSPoint(x: 150, y: 100))
        XCTAssertEqual(mapped.x, 200, accuracy: 0.0001, "50pt from the anchor should land 100pt away at 2x")
    }

    func testClearingTheZoomAnchorsReturnsToIdentity() {
        let view = makeOverlay()
        view.zoomLevel = 3
        view.zoomAnchorCanvas = NSPoint(x: 10, y: 20)
        view.zoomAnchorView = NSPoint(x: 30, y: 40)

        view.zoomLevel = 1
        view.zoomAnchorCanvas = .zero
        view.zoomAnchorView = .zero

        let point = NSPoint(x: 77, y: 88)
        XCTAssertEqual(view.viewToCanvas(point), point)
        XCTAssertEqual(view.canvasToView(point), point)
    }

    // MARK: - Composited output

    func testCompositedImageMatchesTheCaptureRectNotTheViewBounds() throws {
        let view = makeOverlay(width: 420, height: 260)
        let image = try XCTUnwrap(view.compositedImage())
        XCTAssertEqual(image.size, view.captureDrawRect.size)
    }

    func testCompositedImageIncludesAnnotations() throws {
        let view = makeOverlay(width: 200, height: 200)
        let before = try XCTUnwrap(view.compositedImage())

        let redaction = annotation(.filledRectangle, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 200, y: 200))
        redaction.color = .black
        view.annotations.append(redaction)
        view.cachedCompositedImage = nil
        let after = try XCTUnwrap(view.compositedImage())

        XCTAssertNotEqual(FieldDescriber.describe(after), FieldDescriber.describe(before),
                          "an annotation covering the whole capture has to change the output")
    }

    func testCompositedImageIsStableWhenNothingChanges() throws {
        let view = makeOverlay(width: 120, height: 90)
        view.annotations.append(annotation(.arrow))
        let first = try XCTUnwrap(view.compositedImage())
        let second = try XCTUnwrap(view.compositedImage())
        XCTAssertEqual(FieldDescriber.describe(first), FieldDescriber.describe(second))
    }

    // MARK: - Undo / redo

    func testSavedUndoIdentitySurvivesRedoButNotADifferentEditAtTheSameDepth() {
        let view = makeOverlay()
        let first = annotation(.arrow)
        view.annotations.append(first)
        view.undoStack.append(.added(first))
        let saved = view.undoStateIdentity
        view.undo()
        XCTAssertNotEqual(view.undoStateIdentity, saved)
        view.redo()
        XCTAssertEqual(view.undoStateIdentity, saved)
        view.undo()
        let replacement = annotation(.ellipse)
        view.annotations.append(replacement)
        view.undoStack.append(.added(replacement))
        view.redoStack.removeAll()
        XCTAssertEqual(view.undoStack.count, 1)
        XCTAssertNotEqual(view.undoStateIdentity, saved)
        let branch = view.undoStateIdentity
        view.undo()
        view.redo()
        XCTAssertEqual(view.undoStateIdentity, branch)
    }

    func testGroupedUndoAndRedoRestoreSavedIdentity() {
        let view = makeOverlay()
        let group = UUID()
        let annotations = [annotation(.arrow), annotation(.ellipse)]
        for annotation in annotations { annotation.groupID = group }
        view.annotations = annotations
        let initial = view.undoStateIdentity
        view.undoStack.append(contentsOf: annotations.map { .added($0) })
        let saved = view.undoStateIdentity
        view.undo()
        XCTAssertEqual(view.undoStateIdentity, initial)
        view.redo()
        XCTAssertEqual(view.undoStateIdentity, saved)
    }

    func testUndoRemovesTheLastAnnotationAndRedoPutsItBack() {
        let view = makeOverlay()
        let ann = annotation()
        view.annotations.append(ann)
        view.undoStack.append(.added(ann))

        view.undo()
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertEqual(view.redoStack.count, 1)

        view.redo()
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertTrue(view.annotations.first === ann, "redo must restore the same annotation, not a copy")
        XCTAssertTrue(view.redoStack.isEmpty)
    }

    func testUndoOnAnEmptyStackDoesNothing() {
        let view = makeOverlay()
        view.undo()
        view.redo()
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertTrue(view.undoStack.isEmpty)
        XCTAssertTrue(view.redoStack.isEmpty)
    }

    func testUndoRestoresADeletedAnnotationInItsOriginalPlace() {
        let view = makeOverlay()
        let first = annotation(.pencil)
        let middle = annotation(.arrow)
        let last = annotation(.text)
        view.annotations = [first, last]
        view.undoStack.append(.deleted(middle, 1))

        view.undo()
        XCTAssertEqual(view.annotations.count, 3)
        XCTAssertTrue(view.annotations[1] === middle, "z-order matters: it has to come back where it was")
    }

    func testUndoingADeletionAtAStaleIndexDoesNotCrash() {
        let view = makeOverlay()
        view.annotations = [annotation()]
        view.undoStack.append(.deleted(annotation(.arrow), 99))  // index from a longer list

        view.undo()
        XCTAssertEqual(view.annotations.count, 2, "a stale index must clamp, not trap")
    }

    func testABatchOfAnnotationsUndoesTogether() {
        // Auto-redact adds one annotation per detected match, all sharing a
        // group id; a single undo has to take the whole batch.
        let view = makeOverlay()
        let group = UUID()
        let batch = (0..<4).map { index -> Annotation in
            let ann = annotation(.filledRectangle,
                                 from: NSPoint(x: index * 10, y: 0),
                                 to: NSPoint(x: index * 10 + 8, y: 8))
            ann.groupID = group
            return ann
        }
        view.annotations = batch
        for ann in batch { view.undoStack.append(.added(ann)) }

        view.undo()
        XCTAssertTrue(view.annotations.isEmpty, "the whole redaction pass should disappear at once")

        view.redo()
        XCTAssertEqual(view.annotations.count, 4, "and come back at once")
    }

    func testAnUngroupedAnnotationIsNotSweptUpByABatchUndo() {
        let view = makeOverlay()
        let manual = annotation(.arrow)
        let group = UUID()
        let redaction = annotation(.filledRectangle)
        redaction.groupID = group

        view.annotations = [manual, redaction]
        view.undoStack = [.added(manual), .added(redaction)]

        view.undo()
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertTrue(view.annotations.first === manual, "an unrelated annotation must survive")
    }

    func testUndoingAPropertyChangeRestoresTheOldStyle() {
        let view = makeOverlay()
        let ann = annotation(.rectangle)
        ann.strokeWidth = 3
        ann.color = .red
        let snapshot = ann.clone()

        ann.strokeWidth = 12
        ann.color = .blue
        view.annotations = [ann]
        view.undoStack.append(.propertyChange(annotation: ann, snapshot: snapshot))

        view.undo()
        XCTAssertEqual(ann.strokeWidth, 3)
        XCTAssertEqual(FieldDescriber.describe(ann.color), FieldDescriber.describe(NSColor.red))

        view.redo()
        XCTAssertEqual(ann.strokeWidth, 12, "redo has to put the new style back")
    }

    func testNumberingCountsBackDownWhenUndone() {
        let view = makeOverlay()
        view.numberCounter = 3
        let third = annotation(.number)
        third.number = 3
        view.annotations = [third]
        view.undoStack.append(.added(third))

        view.undo()
        XCTAssertEqual(view.numberCounter, 2, "the next badge should reuse the number that was undone")
    }

    func testRepeatedUndoAndRedoConvergeOnTheSameState() {
        let view = makeOverlay()
        let annotations = [annotation(.pencil), annotation(.arrow), annotation(.text)]
        view.annotations = annotations
        view.undoStack = annotations.map { .added($0) }

        for _ in 0..<5 { view.undo() }   // more undos than entries
        XCTAssertTrue(view.annotations.isEmpty)

        for _ in 0..<5 { view.redo() }   // more redos than entries
        XCTAssertEqual(view.annotations.count, 3)
        XCTAssertEqual(view.annotations.map(\.tool), annotations.map(\.tool), "order must be preserved")
    }

    func testUndoingAnImageTransformRestoresThePreviousImage() throws {
        let view = makeOverlay(width: 100, height: 100)
        let original = try XCTUnwrap(view.screenshotImage)
        let flipped = ImageProbe.solidImage(width: 60, height: 40)

        view.undoStack.append(.imageTransform(previousImage: original, previousSnappedWindowImage: nil, annotationOffsets: []))
        view.screenshotImage = flipped

        view.undo()
        XCTAssertEqual(view.screenshotImage?.size, original.size)

        view.redo()
        XCTAssertEqual(view.screenshotImage?.size, flipped.size)
    }

    // MARK: - Selection

    func testApplySelectionStoresTheRect() {
        let view = makeOverlay()
        view.applySelection(NSRect(x: 20, y: 30, width: 120, height: 90))
        XCTAssertEqual(view.selectionRect, NSRect(x: 20, y: 30, width: 120, height: 90))
    }

    // MARK: - Drawing every tool

    func testEveryToolDrawsWithoutCrashing() throws {
        // Annotations draw themselves; a degenerate shape must not trap.
        let view = makeOverlay(width: 200, height: 160)
        let geometries: [(NSPoint, NSPoint)] = [
            (NSPoint(x: 20, y: 20), NSPoint(x: 150, y: 120)),   // normal
            (NSPoint(x: 50, y: 50), NSPoint(x: 50, y: 50)),     // zero size
            (NSPoint(x: 150, y: 120), NSPoint(x: 20, y: 20)),   // reversed
            (NSPoint(x: -500, y: -500), NSPoint(x: 900, y: 900)), // far outside
        ]

        for tool in AnnotationTool.allCases {
            for (start, end) in geometries {
                let ann = Annotation(tool: tool, startPoint: start, endPoint: end,
                                     color: .systemBlue, strokeWidth: 4)
                ann.text = "sample"
                ann.number = 1
                ann.points = [start, NSPoint(x: (start.x + end.x) / 2, y: end.y), end]
                view.annotations = [ann]
                view.cachedCompositedImage = nil
                XCTAssertNotNil(view.compositedImage(), "\(tool) failed to render at \(start)–\(end)")
            }
        }
    }

    func testAnnotationsWithHugeStrokeWidthsStillRender() throws {
        let view = makeOverlay(width: 100, height: 100)
        for width in [0, 1, 200, 5000] as [CGFloat] {
            let ann = annotation(.rectangle)
            ann.strokeWidth = width
            view.annotations = [ann]
            view.cachedCompositedImage = nil
            XCTAssertNotNil(view.compositedImage(), "stroke width \(width) failed to render")
        }
    }
}
