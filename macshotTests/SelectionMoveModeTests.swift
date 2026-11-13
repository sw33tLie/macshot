import Cocoa
import XCTest

@MainActor
final class SelectionMoveModeTests: XCTestCase {
    private let selection = NSRect(x: 80, y: 60, width: 200, height: 150)
    private let settings: [String: Any?] = [
        "startCapturesInMoveMode": true,
        "rememberLastTool": false,
        "boundarySnapEnabled": false,
        "doubleClickToCopy": false,
        "openEditorAfterSelection": false,
        "beautifyEnabled": false,
    ]

    private func makeOverlay() -> OverlayView {
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.screenshotImage = ImageProbe.quadrantImage(width: 500, height: 400)
        view.applySelection(selection)
        return view
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ view: OverlayView, from start: NSPoint, to end: NSPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, at: start))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
        view.mouseUp(with: mouse(.leftMouseUp, at: end))
    }

    func testFreshCaptureMovesWithoutDrawingAndKeepsItsSize() {
        withDefaults(settings) {
            let view = makeOverlay()
            XCTAssertFalse(view.toolHasOptionsRow)
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection.offsetBy(dx: 35, dy: 25))
            XCTAssertTrue(view.annotations.isEmpty)

            // Releasing the button ends the move; the next drag gets a fresh offset.
            drag(view, from: NSPoint(x: 170, y: 135), to: NSPoint(x: 150, y: 110))
            XCTAssertEqual(view.selectionRect, selection.offsetBy(dx: 15, dy: 0))
        }
    }

    func testChoosingAToolArmsDrawingForTheRestOfTheCapture() {
        withDefaults(settings) {
            let view = makeOverlay()
            view.handleToolbarAction(.tool(.arrow))
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection)
            XCTAssertEqual(view.annotations.count, 1)
            XCTAssertEqual(view.annotations.first?.tool, .arrow)
            XCTAssertTrue(view.toolHasOptionsRow)
        }
    }

    func testChoosingTheRememberedToolAlsoArmsDrawing() {
        withDefaults(settings) {
            let view = makeOverlay()
            view.handleToolbarAction(.tool(view.currentTool))
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection)
            XCTAssertEqual(view.annotations.count, 1)
        }
    }

    func testToolShortcutArmsDrawing() {
        withDefaults(settings.merging(["overlayToolShortcuts": nil]) { _, new in new }) {
            ToolShortcutManager.setKey("a", for: .arrow)
            defer { ToolShortcutManager.setKey("a", for: .arrow) }
            let view = makeOverlay()
            view.keyDown(with: TestKeyEvent.keyDown(characters: "a", keyCode: TestKeyEvent.Code.a))
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection)
            XCTAssertEqual(view.annotations.first?.tool, .arrow)
        }
    }

    func testResetAndNewCapturesReturnToMoveMode() {
        withDefaults(settings) {
            let view = makeOverlay()
            view.handleToolbarAction(.tool(.pencil))
            view.reset()
            view.applySelection(selection)
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection.offsetBy(dx: 35, dy: 25))
            XCTAssertTrue(view.annotations.isEmpty)

            let next = makeOverlay()
            drag(next, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(next.selectionRect, selection.offsetBy(dx: 35, dy: 25))
        }
    }

    func testDisablingMoveModeRestoresImmediateAnnotation() {
        withDefaults(settings.merging(["startCapturesInMoveMode": false]) { _, new in new }) {
            let view = makeOverlay()
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection)
            XCTAssertEqual(view.annotations.first?.tool, .arrow)
        }
    }

    func testMoveModeIsOptIn() {
        withDefaults(settings.merging(["startCapturesInMoveMode": nil]) { _, new in new }) {
            XCTAssertFalse(OverlayView.startCapturesInMoveModeSetting)
            let view = makeOverlay()
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection)
            XCTAssertEqual(view.annotations.first?.tool, .arrow)
        }
    }

    func testSettingIsReadWhenACaptureStarts() {
        withDefaults(settings) {
            let view = makeOverlay()
            // Changing the preference mid-capture does not switch modes.
            UserDefaults.standard.set(false, forKey: OverlayView.startCapturesInMoveModeKey)
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection.offsetBy(dx: 35, dy: 25))
            XCTAssertTrue(view.annotations.isEmpty)

            // The next capture on the same (pooled) view picks it up.
            view.reset()
            view.applySelection(selection)
            drag(view, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(view.selectionRect, selection)
            XCTAssertEqual(view.annotations.first?.tool, .arrow)
        }
    }

    func testRememberedColorSamplerDoesNotActUntilChosen() {
        let values = settings.merging([
            "rememberLastTool": true, "lastUsedTool": nil, "lastUsedColor": nil,
            "lastUsedColorOpacity": nil, "customColors": nil,
        ]) { _, new in new }
        withDefaults(values) {
            defer { OverlayView.resetRememberedTool() }
            let view = makeOverlay()
            // Remember the color sampler, then start a fresh capture with it.
            view.currentTool = .colorSampler
            view.reset()
            view.applySelection(selection)
            XCTAssertEqual(view.currentTool, .colorSampler)

            let outside = NSPoint(x: 20, y: 20)
            view.currentColor = .systemPurple
            view.mouseDown(with: mouse(.leftMouseDown, at: outside))
            view.mouseUp(with: mouse(.leftMouseUp, at: outside))
            XCTAssertEqual(view.currentColor, .systemPurple)
            XCTAssertEqual(view.selectionRect, selection)

            // Once picked explicitly, the same click samples the screenshot.
            view.handleToolbarAction(.tool(.colorSampler))
            view.mouseDown(with: mouse(.leftMouseDown, at: outside))
            view.mouseUp(with: mouse(.leftMouseUp, at: outside))
            XCTAssertNotEqual(view.currentColor, .systemPurple)
        }
    }

    func testEditorStillDrawsImmediately() {
        withDefaults(settings) {
            let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
            editor.screenshotImage = ImageProbe.quadrantImage(width: 500, height: 400)
            editor.applySelection(selection)
            drag(editor, from: NSPoint(x: 140, y: 120), to: NSPoint(x: 175, y: 145))
            XCTAssertEqual(editor.selectionRect, selection)
            XCTAssertEqual(editor.annotations.first?.tool, .arrow)
        }
    }

    func testResizeHandlesStillResizeInMoveMode() {
        withDefaults(settings) {
            let view = makeOverlay()
            drag(view, from: NSPoint(x: selection.maxX, y: selection.maxY),
                 to: NSPoint(x: selection.maxX + 30, y: selection.maxY + 20))
            XCTAssertEqual(view.selectionRect.origin, selection.origin)
            XCTAssertEqual(view.selectionRect.size, NSSize(width: 230, height: 170))
            XCTAssertTrue(view.annotations.isEmpty)
        }
    }

    func testWindowSnapIsReleasedOnlyWhenTheSelectionMoves() {
        withDefaults(settings) {
            let view = makeOverlay()
            view.selectionIsWindowSnap = true
            view.snappedWindowID = 42
            let point = NSPoint(x: 140, y: 120)
            view.mouseDown(with: mouse(.leftMouseDown, at: point))
            view.mouseUp(with: mouse(.leftMouseUp, at: point))
            XCTAssertTrue(view.selectionIsWindowSnap)
            drag(view, from: point, to: NSPoint(x: 175, y: 145))
            XCTAssertFalse(view.selectionIsWindowSnap)
            XCTAssertNil(view.snappedWindowID)
        }
    }
}
