import Cocoa
import XCTest

/// Capture entry points such as "Capture OCR & QR" arm a one-shot action that
/// runs as soon as the user picks a region. Every way of picking one has to
/// fire it — before #302 was fixed, a right-click anchored selection, F and R
/// left the OCR entry point looking like an ordinary screenshot (or like a
/// frozen selection with no toolbar at all).
@MainActor
final class OverlayAutoSelectionTests: XCTestCase {

    private func makeOverlay(width: CGFloat = 400, height: CGFloat = 300) -> (OverlayView, RecordingOverlayDelegate) {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.screenshotImage = ImageProbe.quadrantImage(width: Int(width), height: Int(height))
        let delegate = RecordingOverlayDelegate()
        view.overlayDelegate = delegate
        return (view, delegate)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ) else {
            fatalError("could not synthesize \(type) event")
        }
        return event
    }

    private func drag(_ view: OverlayView, from start: NSPoint, to end: NSPoint) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: end))
    }

    private func anchorSelect(_ view: OverlayView, from start: NSPoint, to end: NSPoint) {
        view.rightMouseDown(with: mouseEvent(.rightMouseDown, at: start))
        view.rightMouseDown(with: mouseEvent(.rightMouseDown, at: end))
    }

    private let snapOff: [String: Any?] = ["captureSnapMode": OverlayView.SnapMode.off.rawValue]
    private let snapOn: [String: Any?] = ["captureSnapMode": OverlayView.SnapMode.window.rawValue]

    // MARK: - Capture OCR & QR

    func testDragSelectionRunsOCR() {
        withDefaults(snapOff) {
            let (view, delegate) = makeOverlay()
            view.autoOCRMode = true
            drag(view, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 200, y: 150))
            XCTAssertEqual(delegate.ocrRequests, 1)
            XCTAssertFalse(view.autoOCRMode, "the action is one-shot")
        }
    }

    func testRightClickAnchoredSelectionRunsOCR() {
        withDefaults(snapOff) {
            let (view, delegate) = makeOverlay()
            view.autoOCRMode = true
            anchorSelect(view, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 200, y: 150))
            XCTAssertEqual(view.state, .selected)
            XCTAssertEqual(delegate.ocrRequests, 1,
                           "a right-click anchored selection must run OCR, not leave a bare selection")
            XCTAssertFalse(view.autoOCRMode)
        }
    }

    func testFullScreenKeyRunsOCR() {
        withDefaults(snapOn) {
            let (view, delegate) = makeOverlay()
            view.autoOCRMode = true
            view.keyDown(with: TestKeyEvent.keyDown(characters: "f", keyCode: TestKeyEvent.Code.f))
            XCTAssertEqual(view.state, .selected)
            XCTAssertEqual(view.selectionRect, view.bounds)
            XCTAssertEqual(delegate.ocrRequests, 1, "F must run OCR instead of showing the screenshot toolbar")
        }
    }

    func testRestoredSelectionRunsOCR() {
        let (view, delegate) = makeOverlay()
        view.autoOCRMode = true
        // R (restore last area) and Capture Last Area land here.
        view.applySelection(NSRect(x: 30, y: 40, width: 120, height: 80))
        XCTAssertEqual(delegate.ocrRequests, 1)
        XCTAssertFalse(view.autoOCRMode)
    }

    // MARK: - Other one-shot entry points share the same paths

    func testRightClickAnchoredSelectionRunsEveryEntryPointAction() {
        withDefaults(snapOff) {
            let (quick, quickDelegate) = makeOverlay()
            quick.autoQuickSaveMode = true
            anchorSelect(quick, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 200, y: 150))
            XCTAssertEqual(quickDelegate.quickSaveRequests, 1)

            let (scroll, scrollDelegate) = makeOverlay()
            scroll.autoScrollCaptureMode = true
            anchorSelect(scroll, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 200, y: 150))
            XCTAssertEqual(scrollDelegate.scrollCaptureRects, [scroll.selectionRect])

            let (add, addDelegate) = makeOverlay()
            add.autoConfirmMode = true
            anchorSelect(add, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 200, y: 150))
            XCTAssertEqual(addDelegate.confirms, 1)

            let (record, recordDelegate) = makeOverlay()
            record.autoEnterRecordingMode = true
            anchorSelect(record, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 200, y: 150))
            XCTAssertEqual(recordDelegate.enterRecordingRequests, 1)
        }
    }

    func testFullScreenKeyStillQuickSaves() {
        withDefaults(snapOn) {
            let (view, delegate) = makeOverlay()
            view.autoQuickSaveMode = true
            view.keyDown(with: TestKeyEvent.keyDown(characters: "f", keyCode: TestKeyEvent.Code.f))
            XCTAssertEqual(delegate.quickSaveRequests, 1)
        }
    }

    func testPlainSelectionTriggersNoAction() {
        withDefaults(snapOff) {
            let (view, delegate) = makeOverlay()
            anchorSelect(view, from: NSPoint(x: 20, y: 20), to: NSPoint(x: 200, y: 150))
            view.applySelection(NSRect(x: 30, y: 40, width: 120, height: 80))
            XCTAssertEqual(delegate.ocrRequests, 0)
            XCTAssertEqual(delegate.quickSaveRequests, 0)
            XCTAssertEqual(delegate.confirms, 0)
        }
    }
}

/// Counts the delegate calls the auto-selection tests care about.
@MainActor
final class RecordingOverlayDelegate: OverlayViewDelegate {
    var ocrRequests = 0
    var quickSaveRequests = 0
    var confirms = 0
    var cancels = 0
    var enterRecordingRequests = 0
    var scrollCaptureRects: [NSRect] = []

    func overlayViewDidRequestOCR() { ocrRequests += 1 }
    func overlayViewDidRequestQuickSave() { quickSaveRequests += 1 }
    func overlayViewDidConfirm() { confirms += 1 }
    func overlayViewDidCancel() { cancels += 1 }
    func overlayViewDidRequestEnterRecordingMode() { enterRecordingRequests += 1 }
    func overlayViewDidRequestScrollCapture(rect: NSRect) { scrollCaptureRects.append(rect) }

    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidRequestSave() {}
    func overlayViewDidRequestSaveAs() {}
    func overlayViewDidRequestPin() {}
    func overlayViewDidRequestFileSave() {}
    func overlayViewDidRequestUpload() {}
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() {}
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestCancelScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidChangeSnapMode() {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidRequestAddCapture() {}
}
