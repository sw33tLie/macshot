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
            if returning {
                let png = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                if let png { content.cacheDisplay(in: content.bounds, to: png)
                    try? png.representation(using: .png, properties: [:])?
                        .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-returning.png")) }
            }
            controller.close()
        }
    }
}
