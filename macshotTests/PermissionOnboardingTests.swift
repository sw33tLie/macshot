import Cocoa
import XCTest

/// After a signing change macOS asks existing users for Screen Recording
/// again; they should see a reassuring "turn it back on" window, not a
/// first-run welcome.
final class PermissionOnboardingTests: XCTestCase {
    func testReturningUserDetection() {
        withDefaults(["SUHasLaunchedBefore": nil, "screenRecordingGrantedBefore": nil]) {
            XCTAssertFalse(PermissionOnboardingController.isReturningUser())
        }
        withDefaults(["SUHasLaunchedBefore": true, "screenRecordingGrantedBefore": nil]) {
            XCTAssertTrue(PermissionOnboardingController.isReturningUser())
        }
        withDefaults(["SUHasLaunchedBefore": nil, "screenRecordingGrantedBefore": nil]) {
            PermissionOnboardingController.rememberGranted()
            XCTAssertTrue(PermissionOnboardingController.isReturningUser())
        }
    }

    func testReturningWindowFitsTheNoteAboveTheGuide() throws {
        for returning in [false, true] {
            let controller = PermissionOnboardingController(returningUser: returning)
            controller.window?.appearance = NSAppearance(named: .aqua)
            let content = try XCTUnwrap(controller.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let labels = content.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
            let note = labels.first { $0.stringValue.hasPrefix(L("After some updates, macOS asks you to allow macshot again.")) }
            XCTAssertEqual(note != nil, returning)
            if let note {
                let images = content.subviews.compactMap { $0 as? NSImageView }
                let guide = try XCTUnwrap(images.max { $0.frame.width < $1.frame.width })
                XCTAssertGreaterThanOrEqual(note.frame.minY, guide.frame.maxY, "note overlaps the guide image")
                XCTAssertGreaterThan(note.frame.height, 30, "note should wrap onto several lines")
            }
            for view in content.subviews where !view.isHidden {
                XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.frame), "\(view) is clipped")
            }
            // The reset fallback (#496) is only for returning users, sits below
            // the main button, and shows the exact command it copies.
            let buttons = allSubviews(of: content).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            let copy = buttons.first { $0.title == L("Copy Command") }
            let restart = buttons.first { $0.title == L("Restart macshot") }
            XCTAssertEqual(copy != nil, returning)
            XCTAssertEqual(restart != nil, returning)
            let command = PermissionOnboardingController.permissionResetCommand(
                bundleID: Bundle.main.bundleIdentifier ?? "com.sw33tlie.macshot.macshot")
            let commandField = allSubviews(of: content).compactMap { $0 as? NSTextField }.first { $0.stringValue == command }
            XCTAssertEqual(commandField != nil, returning)
            if returning, let copy, let restart, let commandField {
                let open = try XCTUnwrap(buttons.first { $0.title == L("Open Screen Recording Settings") })
                let openFrame = open.convert(open.bounds, to: content)
                for view in [copy, restart, commandField] as [NSView] {
                    let frame = view.convert(view.bounds, to: content)
                    XCTAssertLessThan(frame.maxY, openFrame.minY, "\(view) should sit below the main button")
                    XCTAssertTrue(content.bounds.contains(frame), "\(view) is clipped")
                }
                let fieldWidth = commandField.convert(commandField.bounds, to: content).width
                XCTAssertGreaterThanOrEqual(fieldWidth + 0.5, commandField.intrinsicContentSize.width,
                                            "command is truncated")
            }
            if returning {
                let png = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                if let png { content.cacheDisplay(in: content.bounds, to: png)
                    try? png.representation(using: .png, properties: [:])?
                        .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-returning.png")) }
            }
            controller.close()
        }
    }

    func testResetCommandTargetsOnlyThisApp() {
        XCTAssertEqual(PermissionOnboardingController.permissionResetCommand(bundleID: "com.sw33tlie.macshot.macshot"),
                       "tccutil reset All com.sw33tlie.macshot.macshot")
        XCTAssertEqual(PermissionOnboardingController.permissionResetCommand(bundleID: "com.sw33tlie.macshot.offline"),
                       "tccutil reset All com.sw33tlie.macshot.offline")
        // Never let an unusual identifier become shell syntax, and never emit
        // an unscoped reset that would wipe every app's permissions.
        XCTAssertEqual(PermissionOnboardingController.permissionResetCommand(bundleID: "a b;rm 'x'"),
                       "tccutil reset All 'a b;rm '\\''x'\\'''")
        XCTAssertEqual(PermissionOnboardingController.permissionResetCommand(bundleID: ""),
                       "tccutil reset All com.sw33tlie.macshot.macshot")
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}
