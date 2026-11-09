import Cocoa
import XCTest

@MainActor
final class RecordingSetupTests: XCTestCase {
    private func withOverlay(_ body: (RecordingSetupOverlay, RecordingSetupDelegate) -> Void) {
        withDefaults([
            "recordMouseHighlight": false, "recordKeystroke": false,
            "recordMicAudio": false, "recordWebcam": false,
            "overlayToolShortcuts": nil,
        ]) {
            // Invalidate the shortcut cache both before use and before the
            // surrounding helper restores the previous preferences.
            ToolShortcutManager.setKey(" ", for: .moveSelection)
            defer { ToolShortcutManager.setKey(" ", for: .moveSelection) }
            let view = RecordingSetupOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = RecordingSetupDelegate()
            view.overlayDelegate = delegate
            view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
            body(view, delegate)
        }
    }

    func testBothInputOverlayButtonsRequestPermissionBeforeEnabling() {
        withOverlay { view, delegate in
            view.permissionGranted = false
            for (action, key) in [(ToolbarButtonAction.mouseHighlight, "recordMouseHighlight"),
                                  (.showKeystrokes, "recordKeystroke")] {
                let previousRequests = delegate.inputPermissionRequests
                view.handleToolbarAction(action)
                XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
                XCTAssertEqual(delegate.inputPermissionRequests, previousRequests + 1)
            }
        }
    }

    func testInputOverlayCanBeEnabledAfterPermissionAndDisabledAfterRevocation() {
        withOverlay { view, delegate in
            for (action, key) in [(ToolbarButtonAction.mouseHighlight, "recordMouseHighlight"),
                                  (.showKeystrokes, "recordKeystroke")] {
                view.permissionGranted = true
                view.handleToolbarAction(action)
                XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
                view.permissionGranted = false
                view.handleToolbarAction(action)
                XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
            }
            XCTAssertEqual(delegate.inputPermissionRequests, 0)
        }
    }

    func testSavedMouseHighlightWithoutPermissionStaysOffWithoutPromptingOnEntry() {
        withOverlay { view, delegate in
            view.permissionGranted = false
            UserDefaults.standard.set(true, forKey: "recordMouseHighlight")
            view.isRecording = true
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "recordMouseHighlight"))
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "recordKeystroke"))
            XCTAssertEqual(delegate.inputPermissionRequests, 0)

            // A fresh capture must also keep unavailable options off without
            // interrupting recording setup with an optional permission prompt.
            let reopened = RecordingSetupOverlay(frame: view.frame)
            reopened.permissionGranted = false
            reopened.overlayDelegate = delegate
            reopened.applySelection(view.selectionRect)
            reopened.isRecording = true
            XCTAssertEqual(delegate.inputPermissionRequests, 0)
            let buttons = ToolbarLayout.rightButtons(isRecording: true)
            XCTAssertEqual(buttons.first { if case .mouseHighlight = $0.action { return true }; return false }?.isSelected, false)
            XCTAssertEqual(buttons.first { if case .showKeystrokes = $0.action { return true }; return false }?.isSelected, false)
            reopened.handleToolbarAction(.mouseHighlight)
            XCTAssertEqual(delegate.inputPermissionRequests, 1)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "recordMouseHighlight"))
        }
    }

    func testRecordingSetupDisablesBothUnavailableSavedOptionsWithoutPrompting() {
        withOverlay { view, delegate in
            view.permissionGranted = false
            UserDefaults.standard.set(true, forKey: "recordMouseHighlight")
            UserDefaults.standard.set(true, forKey: "recordKeystroke")
            view.isRecording = true
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "recordMouseHighlight"))
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "recordKeystroke"))
            XCTAssertEqual(delegate.inputPermissionRequests, 0)
        }
    }

    func testRecordingSetupKeepsPermittedInputOptionsAndDoesNotPromptWhenDisabled() {
        withOverlay { view, delegate in
            view.permissionGranted = false
            view.isRecording = true
            XCTAssertEqual(delegate.inputPermissionRequests, 0)
            view.isRecording = false
            view.permissionGranted = true
            UserDefaults.standard.set(true, forKey: "recordMouseHighlight")
            UserDefaults.standard.set(true, forKey: "recordKeystroke")
            view.isRecording = true
            XCTAssertTrue(UserDefaults.standard.bool(forKey: "recordMouseHighlight"))
            XCTAssertTrue(UserDefaults.standard.bool(forKey: "recordKeystroke"))
            XCTAssertEqual(delegate.inputPermissionRequests, 0)
        }
    }

    func testSpaceStartsMoveInBothScreenshotAndRecordingSetup() {
        withOverlay { view, _ in
            let space = TestKeyEvent.keyDown(characters: " ", keyCode: 49)
            view.keyDown(with: space)
            XCTAssertEqual(view.moveEligibility, [true])
            view.isRecording = true
            view.keyDown(with: space)
            XCTAssertEqual(view.moveEligibility, [true, true])
            XCTAssertTrue(view.isRecording)
        }
    }

    func testRecordingMoveUsesConfiguredCharacterAndRejectsModifiedOrRepeatedKeys() {
        withOverlay { view, _ in
            ToolShortcutManager.setKey("k", for: .moveSelection)
            view.isRecording = true
            view.keyDown(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
            for modifiers in [NSEvent.ModifierFlags.command, .option, .control] {
                view.keyDown(with: TestKeyEvent.keyDown(characters: "k", keyCode: 16, modifiers: modifiers))
            }
            let repeated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "k",
                charactersIgnoringModifiers: "k", isARepeat: true, keyCode: 16)!
            view.keyDown(with: repeated)
            XCTAssertTrue(view.moveEligibility.isEmpty)
            // Use a different physical key to verify character-based matching.
            view.keyDown(with: TestKeyEvent.keyDown(characters: "k", keyCode: 16))
            XCTAssertEqual(view.moveEligibility, [true])
        }
    }

    func testRecordingMoveStillRequiresSelectionAndDoesNotEnableScreenshotActions() {
        withOverlay { view, delegate in
            view.isRecording = true
            view.clearSelection()
            view.keyDown(with: TestKeyEvent.keyDown(characters: " ", keyCode: 49))
            XCTAssertEqual(view.moveEligibility, [false])
            view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
            let tool = view.currentTool
            for event in [TestKeyEvent.keyDown(characters: "r", keyCode: 15),
                          TestKeyEvent.keyDown(characters: "\r", keyCode: 36),
                          TestKeyEvent.keyDown(characters: "s", keyCode: 1, modifiers: .command)] {
                view.keyDown(with: event)
            }
            XCTAssertEqual(view.currentTool, tool)
            XCTAssertEqual(delegate.outputRequests, 0)
            XCTAssertEqual(view.moveEligibility, [false])
            view.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
            XCTAssertFalse(view.isRecording)
            XCTAssertEqual(delegate.cancellations, 1)
        }
    }
}

@MainActor
private final class RecordingSetupOverlay: OverlayView {
    var permissionGranted = true
    var moveEligibility: [Bool] = []

    override var hasRecordingInputMonitoringPermission: Bool { permissionGranted }

    override func startKeyboardMoveSelection() -> Bool {
        // Exercise real key routing and the real eligibility predicate without
        // constructing a window or moving the user's pointer in headless tests.
        let allowed = canStartKeyboardMoveSelection()
        moveEligibility.append(allowed)
        return allowed
    }
}

@MainActor
private final class RecordingSetupDelegate: OverlayViewDelegate {
    var inputPermissionRequests = 0
    var cancellations = 0
    var outputRequests = 0
    func overlayViewDidRequestInputMonitoringPermission() { inputPermissionRequests += 1 }
    func overlayViewDidCancel() { cancellations += 1 }
    func overlayViewDidConfirm() { outputRequests += 1 }
    func overlayViewDidRequestSave() { outputRequests += 1 }
    func overlayViewDidRequestQuickSave() { outputRequests += 1 }
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidRequestSaveAs() {}
    func overlayViewDidRequestPin() {}
    func overlayViewDidRequestOCR() {}
    func overlayViewDidRequestQuickTranslation() {}
    func overlayViewDidRequestFileSave() {}
    func overlayViewDidRequestUpload() {}
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestCancelScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidChangeSnapMode() {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidRequestAddCapture() {}
}
