import Cocoa
import XCTest

/// Gestures that confirm (copy) a capture must only fire when the user meant
/// them: a drag is never a double-click, and a ⌘C another app injects right
/// after a mouse-up is not a copy request.
@MainActor
final class OverlayConfirmGestureTests: XCTestCase {

    private let settings: [String: Any?] = [
        "captureSnapMode": OverlayView.SnapMode.off.rawValue,
        "doubleClickToCopy": true,
        DoubleClickAction.userDefaultsKey: nil,
    ]

    private func makeSelectedOverlay() -> (OverlayView, RecordingOverlayDelegate) {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.screenshotImage = ImageProbe.quadrantImage(width: 400, height: 300)
        let delegate = RecordingOverlayDelegate()
        view.overlayDelegate = delegate
        let start = NSPoint(x: 20, y: 20), end = NSPoint(x: 380, y: 280)
        view.mouseDown(with: mouse(.leftMouseDown, at: start))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
        view.mouseUp(with: mouse(.leftMouseUp, at: end, timestamp: 0))
        XCTAssertEqual(view.state, .selected)
        return (view, delegate)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1,
                       timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: 0, context: nil, eventNumber: 0,
                                             clickCount: clickCount, pressure: 1) else {
            fatalError("could not synthesize \(type)")
        }
        return event
    }

    private func commandC(at timestamp: TimeInterval) -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                           timestamp: timestamp, windowNumber: 0, context: nil,
                                           characters: "c", charactersIgnoringModifiers: "c",
                                           isARepeat: false, keyCode: TestKeyEvent.Code.c) else {
            fatalError("could not synthesize ⌘C")
        }
        return event
    }

    // MARK: - Double-click to copy (#467)

    /// Trackpad "tap to click" users drag with a double tap: the drag's
    /// mouse-down arrives with clickCount 2. Every arrow drawn that way used
    /// to copy the capture and stack another floating thumbnail.
    func testDoubleTapDragDrawsAnAnnotationInsteadOfCopying() {
        withDefaults(settings) {
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .arrow
            let tap = NSPoint(x: 100, y: 100), end = NSPoint(x: 220, y: 180)
            view.mouseDown(with: mouse(.leftMouseDown, at: tap))
            view.mouseUp(with: mouse(.leftMouseUp, at: tap))
            view.mouseDown(with: mouse(.leftMouseDown, at: tap, clickCount: 2))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 160, y: 140), clickCount: 2))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: end, clickCount: 2))
            view.mouseUp(with: mouse(.leftMouseUp, at: end, clickCount: 2))

            XCTAssertEqual(delegate.confirms, 0, "a drag is not a double-click")
            XCTAssertEqual(view.annotations.count, 1)
            XCTAssertEqual(view.annotations.first?.tool, .arrow)
        }
    }

    func testDoubleClickWithoutMovingStillCopies() {
        withDefaults(settings) {
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .arrow
            let point = NSPoint(x: 100, y: 100)
            view.mouseDown(with: mouse(.leftMouseDown, at: point))
            view.mouseUp(with: mouse(.leftMouseUp, at: point))
            view.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2))
            view.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 2))

            XCTAssertEqual(delegate.confirms, 1)
            XCTAssertTrue(view.annotations.isEmpty)
        }
    }

    func testDoubleClickWithANumberToolCopiesWithoutTheFirstClicksNumber() {
        withDefaults(settings) {
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .number
            let point = NSPoint(x: 100, y: 100)
            view.mouseDown(with: mouse(.leftMouseDown, at: point))
            view.mouseUp(with: mouse(.leftMouseUp, at: point))
            view.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2))
            view.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 2))

            XCTAssertEqual(delegate.confirms, 1)
            XCTAssertTrue(view.annotations.isEmpty, "the first click's number is rewound before copying")
        }
    }

    /// A second click whose mouse-up never arrived must not make the next,
    /// unrelated press copy the capture.
    func testALostSecondClickMouseUpDoesNotTurnTheNextDragIntoACopy() {
        withDefaults(settings) {
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .arrow
            let point = NSPoint(x: 100, y: 100)
            view.mouseDown(with: mouse(.leftMouseDown, at: point))
            view.mouseUp(with: mouse(.leftMouseUp, at: point))
            view.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2))   // mouse-up lost

            let start = NSPoint(x: 250, y: 60), end = NSPoint(x: 330, y: 200)
            view.mouseDown(with: mouse(.leftMouseDown, at: start))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: end))
            view.mouseUp(with: mouse(.leftMouseUp, at: end))

            XCTAssertEqual(delegate.confirms, 0)
            XCTAssertEqual(view.annotations.count, 1)
        }
    }

    // MARK: - Double-click delivery (#512)

    private func doubleClick(_ view: OverlayView, at point: NSPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, at: point))
        view.mouseUp(with: mouse(.leftMouseUp, at: point))
        view.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2))
        view.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 2))
    }

    func testMissingOrUnknownActionKeepsCopyOnlyEvenWhenEnterSaves() {
        for value: Any? in [nil, 99, "sameAsEnter"] {
            withDefaults(settings.merging([
                DoubleClickAction.userDefaultsKey: value,
                QuickCaptureMode.userDefaultsKey: QuickCaptureMode.saveAndCopyImage.rawValue,
            ], uniquingKeysWith: { _, new in new })) {
                let (view, delegate) = makeSelectedOverlay()
                doubleClick(view, at: NSPoint(x: 100, y: 100))
                XCTAssertEqual(DoubleClickAction.current, .copyImage)
                XCTAssertEqual(delegate.confirms, 1)
                XCTAssertEqual(delegate.quickSaveRequests, 0)
            }
        }
    }

    /// The view only asks for the Return action. Which Quick Capture mode
    /// applies is decided by the delegate, in the same code Return runs.
    func testSameAsEnterRequestsTheReturnAction() {
        withDefaults(settings) {
            DoubleClickAction.current = .sameAsEnter
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .number
            doubleClick(view, at: NSPoint(x: 100, y: 100))
            XCTAssertEqual(delegate.quickSaveRequests, 1)
            XCTAssertEqual(delegate.confirms, 0)
            XCTAssertTrue(view.annotations.isEmpty, "rewind the first click before delivering")

            let (returnView, returnDelegate) = makeSelectedOverlay()
            returnView.keyDown(with: TestKeyEvent.keyDown(characters: "\r", keyCode: TestKeyEvent.Code.returnKey))
            XCTAssertEqual(returnDelegate.quickSaveRequests, 1)
            XCTAssertEqual(returnDelegate.confirms, 0)
        }
    }

    func testOutsideSelectionDoubleClickUsesTheConfiguredAction() {
        for action in DoubleClickAction.allCases {
            withDefaults(settings) {
                DoubleClickAction.current = action
                let (view, delegate) = makeSelectedOverlay()
                view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 5, y: 150), clickCount: 2))
                XCTAssertEqual(delegate.confirms, action == .copyImage ? 1 : 0)
                XCTAssertEqual(delegate.quickSaveRequests, action == .sameAsEnter ? 1 : 0)
            }
        }
    }

    /// The editor shares the gesture. There Return quick-saves without
    /// closing the window, and "Same as Enter" does exactly that.
    func testEditorDoubleClickUsesTheConfiguredAction() {
        for action in DoubleClickAction.allCases {
            withDefaults(settings) {
                DoubleClickAction.current = action
                let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
                editor.screenshotImage = ImageProbe.quadrantImage(width: 400, height: 300)
                editor.applySelection(NSRect(x: 0, y: 0, width: 400, height: 300))
                let delegate = RecordingOverlayDelegate()
                editor.overlayDelegate = delegate
                doubleClick(editor, at: NSPoint(x: 100, y: 100))
                XCTAssertEqual(delegate.confirms, action == .copyImage ? 1 : 0, "\(action)")
                XCTAssertEqual(delegate.quickSaveRequests, action == .sameAsEnter ? 1 : 0, "\(action)")
            }
        }
    }

    func testDisabledDoubleClickNeverDeliversTheEnterAction() {
        withDefaults(settings.merging(["doubleClickToCopy": false], uniquingKeysWith: { _, new in new })) {
            DoubleClickAction.current = .sameAsEnter
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .select
            doubleClick(view, at: NSPoint(x: 100, y: 100))
            XCTAssertEqual(delegate.quickSaveRequests, 0)
            XCTAssertEqual(delegate.confirms, 0)
        }
    }

    /// Recording setup ignores Return, so a double-click there must not copy
    /// or save a screenshot either, whichever action is chosen.
    func testDoubleClickDoesNothingDuringRecordingSetup() {
        for action in DoubleClickAction.allCases {
            withDefaults(settings.merging([
                DoubleClickAction.userDefaultsKey: action.rawValue,
                "recordMouseHighlight": false, "recordKeystroke": false,
                "recordMicAudio": false, "recordWebcam": false,
            ], uniquingKeysWith: { _, new in new })) {
                let (view, delegate) = makeSelectedOverlay()
                view.isRecording = true
                doubleClick(view, at: NSPoint(x: 100, y: 100))
                view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 5, y: 150), clickCount: 2))
                XCTAssertEqual(delegate.confirms, 0, "\(action)")
                XCTAssertEqual(delegate.quickSaveRequests, 0, "\(action)")
                XCTAssertTrue(view.isRecording)
            }
        }
    }

    func testSameAsEnterDoesNotFinishADoubleTapDrag() {
        withDefaults(settings) {
            DoubleClickAction.current = .sameAsEnter
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .arrow
            let start = NSPoint(x: 100, y: 100), end = NSPoint(x: 220, y: 180)
            view.mouseDown(with: mouse(.leftMouseDown, at: start))
            view.mouseUp(with: mouse(.leftMouseUp, at: start))
            view.mouseDown(with: mouse(.leftMouseDown, at: start, clickCount: 2))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: end, clickCount: 2))
            view.mouseUp(with: mouse(.leftMouseUp, at: end, clickCount: 2))
            XCTAssertEqual(delegate.quickSaveRequests, 0)
            XCTAssertEqual(delegate.confirms, 0)
            XCTAssertEqual(view.annotations.first?.tool, .arrow)
        }
    }

    func testEnteringRecordingSetupCancelsAPendingDoubleClick() {
        for action in DoubleClickAction.allCases {
            withDefaults(settings.merging([
                DoubleClickAction.userDefaultsKey: action.rawValue,
                "recordMouseHighlight": false, "recordKeystroke": false,
                "recordMicAudio": false, "recordWebcam": false,
            ], uniquingKeysWith: { _, new in new })) {
                let (view, delegate) = makeSelectedOverlay()
                let point = NSPoint(x: 100, y: 100)
                view.mouseDown(with: mouse(.leftMouseDown, at: point))
                view.mouseUp(with: mouse(.leftMouseUp, at: point))
                view.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2))
                view.isRecording = true
                view.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 2))
                XCTAssertEqual(delegate.confirms, 0, "\(action)")
                XCTAssertEqual(delegate.quickSaveRequests, 0, "\(action)")
                XCTAssertTrue(view.isRecording)
            }
        }
    }

    func testSameAsEnterLeavesExistingTextAvailableForEditing() {
        withDefaults(settings) {
            DoubleClickAction.current = .sameAsEnter
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .text
            let annotation = Annotation(tool: .text, startPoint: NSPoint(x: 100, y: 100),
                                        endPoint: NSPoint(x: 220, y: 150), color: .red, strokeWidth: 3)
            annotation.text = "Existing text"
            annotation.textDrawRect = NSRect(x: 100, y: 100, width: 120, height: 50)
            view.annotations = [annotation]
            let point = NSPoint(x: annotation.textDrawRect.midX, y: annotation.textDrawRect.midY)
            doubleClick(view, at: point)
            XCTAssertEqual(delegate.quickSaveRequests, 0)
            XCTAssertEqual(delegate.confirms, 0)
            // Direct headless dispatch has no NSApp.currentEvent to enter edit
            // mode, but must leave the existing annotation intact.
            XCTAssertTrue(view.annotations.first === annotation)
            XCTAssertEqual(view.annotations.count, 1)
        }
    }

    func testSameAsEnterDoesNotFinishWhileEditingText() throws {
        try withDefaults(settings) {
            DoubleClickAction.current = .sameAsEnter
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .text
            let start = NSPoint(x: 100, y: 100)
            view.mouseDown(with: mouse(.leftMouseDown, at: start, timestamp: 10))
            view.mouseUp(with: mouse(.leftMouseUp, at: start, timestamp: 10.1))
            let editor = try XCTUnwrap(view.textEditView)
            editor.string = "Editing text"
            let frame = try XCTUnwrap(editor.enclosingScrollView).frame
            let point = NSPoint(x: frame.midX, y: frame.midY)
            // A later word-selection double-click is not the initial text-tool
            // placement gesture that #247 permits to finish a capture.
            view.mouseDown(with: mouse(.leftMouseDown, at: point, timestamp: 20))
            view.mouseUp(with: mouse(.leftMouseUp, at: point, timestamp: 20.1))
            view.mouseDown(with: mouse(.leftMouseDown, at: point, clickCount: 2, timestamp: 20.2))
            view.mouseUp(with: mouse(.leftMouseUp, at: point, clickCount: 2, timestamp: 20.3))
            XCTAssertEqual(delegate.quickSaveRequests, 0)
            XCTAssertEqual(delegate.confirms, 0)
            XCTAssertTrue(view.textEditView === editor)
            XCTAssertEqual(editor.string, "Editing text")
        }
    }

    func testSameAsEnterCanFinishWithTheTextToolOnEmptySpace() {
        withDefaults(settings) {
            DoubleClickAction.current = .sameAsEnter
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .text
            doubleClick(view, at: NSPoint(x: 100, y: 100))
            XCTAssertEqual(delegate.quickSaveRequests, 1)
            XCTAssertEqual(delegate.confirms, 0)
            XCTAssertTrue(view.annotations.isEmpty)
        }
    }

    // MARK: - Injected ⌘C (#477)

    func testCommandCRightAfterAnAnnotationDragDoesNotConfirm() {
        withDefaults(settings) {
            let (view, delegate) = makeSelectedOverlay()
            view.currentTool = .arrow
            view.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 100, y: 100), timestamp: 10))
            view.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 200, y: 200), timestamp: 10.1))
            view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 200, y: 200), timestamp: 10.2))
            XCTAssertTrue(view.performKeyEquivalent(with: commandC(at: 10.3)))
            XCTAssertEqual(delegate.confirms, 0)
            XCTAssertTrue(view.performKeyEquivalent(with: commandC(at: 11)))
            XCTAssertEqual(delegate.confirms, 1)
        }
    }

    func testCommandCRightAfterTheSelectionMouseUpDoesNotConfirm() {
        withDefaults(settings) {
            let (view, delegate) = makeSelectedOverlay()   // mouse-up at t = 0
            XCTAssertTrue(view.performKeyEquivalent(with: commandC(at: 0.1)))
            XCTAssertEqual(delegate.confirms, 0, "a ⌘C posted ~100 ms after the drag is another app's")
        }
    }

    func testCommandCAfterThePauseConfirms() {
        withDefaults(settings) {
            let (view, delegate) = makeSelectedOverlay()
            XCTAssertTrue(view.performKeyEquivalent(with: commandC(at: 0.5)))
            XCTAssertEqual(delegate.confirms, 1)
        }
    }
}
