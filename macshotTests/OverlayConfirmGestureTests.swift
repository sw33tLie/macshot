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
