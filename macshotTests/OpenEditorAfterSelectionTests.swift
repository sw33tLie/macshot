import Cocoa
import XCTest

@MainActor
final class OpenEditorAfterSelectionTests: XCTestCase {
    private func dragSelection(openEditor: Bool, configure: (OverlayView) -> Void = { _ in }) -> (OverlayView, SelectionDelegate) {
        var result: (OverlayView, SelectionDelegate)!
        withDefaults(["openEditorAfterSelection": openEditor]) {
            let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = SelectionDelegate()
            view.overlayDelegate = delegate
            configure(view)
            view.mouseDown(with: Self.mouse(.leftMouseDown, at: NSPoint(x: 100, y: 100)))
            view.mouseDragged(with: Self.mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 250)))
            view.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: 300, y: 250)))
            result = (view, delegate)
        }
        return result
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testReleasingASelectionOpensTheEditorWhenEnabled() {
        let (view, delegate) = dragSelection(openEditor: true)
        XCTAssertEqual(delegate.finishedSelections, [NSRect(x: 100, y: 100, width: 200, height: 150)])
        XCTAssertEqual(delegate.detachRequests, 1)
        XCTAssertFalse(view.showToolbars)
    }

    func testReleasingASelectionKeepsTheOverlayWhenDisabled() {
        let (view, delegate) = dragSelection(openEditor: false)
        XCTAssertEqual(delegate.finishedSelections.count, 1)
        XCTAssertEqual(delegate.detachRequests, 0)
        XCTAssertTrue(view.showToolbars)
    }

    func testCaptureModesWithTheirOwnActionDoNotOpenTheEditor() {
        let modes: [(String, (OverlayView) -> Void)] = [
            ("OCR", { $0.autoOCRMode = true }),
            ("quick save", { $0.autoQuickSaveMode = true }),
            ("scroll capture", { $0.autoScrollCaptureMode = true }),
            ("add capture", { $0.autoConfirmMode = true }),
            ("record", { $0.autoEnterRecordingMode = true }),
            ("translate", { $0.autoTranslateOverlayMode = true }),
        ]
        for (name, configure) in modes {
            let (_, delegate) = dragSelection(openEditor: true, configure: configure)
            XCTAssertEqual(delegate.detachRequests, 0, name)
        }
    }
}

@MainActor
private final class SelectionDelegate: OverlayViewDelegate {
    var finishedSelections: [NSRect] = []
    var detachRequests = 0
    func overlayViewDidFinishSelection(_ rect: NSRect) { finishedSelections.append(rect) }
    func overlayViewDidRequestDetach() { detachRequests += 1 }
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidCancel() {}
    func overlayViewDidConfirm() {}
    func overlayViewDidRequestSave() {}
    func overlayViewDidRequestSaveAs() {}
    func overlayViewDidRequestPin() {}
    func overlayViewDidRequestOCR() {}
    func overlayViewDidRequestQuickSave() {}
    func overlayViewDidRequestFileSave() {}
    func overlayViewDidRequestUpload() {}
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
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
