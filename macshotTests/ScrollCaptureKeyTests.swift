import AppKit
import XCTest

/// Keys while a scroll capture runs (#437): ⌘C used to fall through to the
/// overlay's own Copy, which copied only the first selected frame and left the
/// scroll-capture HUD and preview on screen.
@MainActor
final class ScrollCaptureKeyTests: XCTestCase {

    private func key(_ characters: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        TestKeyEvent.keyDown(characters: characters, keyCode: code, modifiers: modifiers)
    }

    func testEscapeCancels() {
        XCTAssertEqual(OverlayView.scrollCaptureKeyAction(for: key("\u{1b}", TestKeyEvent.Code.escape)), .cancel)
    }

    func testReturnAndEnterStopLikeTheStopButton() {
        XCTAssertEqual(OverlayView.scrollCaptureKeyAction(for: key("\r", TestKeyEvent.Code.returnKey)), .stop)
        XCTAssertEqual(OverlayView.scrollCaptureKeyAction(for: key("\u{3}", 76)), .stop, "keypad Enter")
    }

    func testCommandCStopsAndCopies() {
        XCTAssertEqual(OverlayView.scrollCaptureKeyAction(for: key("c", TestKeyEvent.Code.c, .command)), .stopAndCopy)
    }

    /// Follows the character, not the physical key: on Dvorak "c" is
    /// elsewhere, and the key under QWERTY's C types "j".
    func testCommandCFollowsTheLayoutCharacter() {
        XCTAssertNil(OverlayView.scrollCaptureKeyAction(for: key("j", TestKeyEvent.Code.c, .command)))
        XCTAssertEqual(OverlayView.scrollCaptureKeyAction(for: key("c", 34, .command)), .stopAndCopy)
    }

    func testOtherKeysPassThrough() {
        XCTAssertNil(OverlayView.scrollCaptureKeyAction(for: key("c", TestKeyEvent.Code.c)), "plain C")
        XCTAssertNil(OverlayView.scrollCaptureKeyAction(for: key("c", TestKeyEvent.Code.c, [.command, .shift])))
        XCTAssertNil(OverlayView.scrollCaptureKeyAction(for: key("v", TestKeyEvent.Code.v, .command)))
        XCTAssertNil(OverlayView.scrollCaptureKeyAction(for: key("\r", TestKeyEvent.Code.returnKey, .command)))
        XCTAssertNil(OverlayView.scrollCaptureKeyAction(for: key("a", TestKeyEvent.Code.a)))
    }

    // MARK: - Stopping

    /// Stop, Return and ⌘C can all arrive for one session; only the first may
    /// report a result, or a later empty one tears down the capture.
    func testASessionReportsItsResultOnce() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first, "no screen attached")
        let controller = ScrollCaptureController(captureRect: NSRect(x: 0, y: 0, width: 100, height: 100), screen: screen)
        var reports = 0
        controller.onSessionDone = { _ in reports += 1 }
        controller.stopSession()
        controller.stopSession()
        controller.stopSession()
        XCTAssertEqual(reports, 1)
    }

    // MARK: - Delivery

    /// Stop (button or Return) keeps delivering exactly as the capture mode says.
    func testStopDeliversAsTheCaptureModeSays() {
        for mode in QuickCaptureMode.allCases {
            let delivery = mode.scrollCaptureDelivery(copyRequested: false)
            XCTAssertEqual(delivery.copyImage, mode.shouldCopyImage, "\(mode)")
            XCTAssertEqual(delivery.save, mode.shouldSave, "\(mode)")
            XCTAssertEqual(delivery.copyPath, mode.copyPathOverride, "\(mode)")
        }
    }

    /// ⌘C always leaves the image on the clipboard; a mode that saves still
    /// saves, but never puts the path over the copied image.
    func testCommandCAlwaysCopiesTheImage() {
        for mode in QuickCaptureMode.allCases {
            let delivery = mode.scrollCaptureDelivery(copyRequested: true)
            XCTAssertTrue(delivery.copyImage, "\(mode)")
            XCTAssertEqual(delivery.save, mode.shouldSave, "\(mode)")
            XCTAssertNotEqual(delivery.copyPath, true, "\(mode): the path must not replace the image")
        }
    }
}
