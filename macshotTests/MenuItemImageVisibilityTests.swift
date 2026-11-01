import AppKit
import XCTest

/// macOS 27 hides menu symbol images by default (#313); the capture and
/// record items ask to keep theirs.
@MainActor
final class MenuItemImageVisibilityTests: XCTestCase {

    func testKeepImageVisibleAsksForTheImageOnMacOS27AndIsHarmlessBefore() {
        let item = NSMenuItem(title: "Capture Area", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "crop", accessibilityDescription: nil)
        item.keepImageVisible()
        if #available(macOS 27.0, *) {
            XCTAssertEqual(item.value(forKey: "preferredImageVisibility") as? Int, NSMenuItem.imageVisibilityVisible)
        } else {
            XCTAssertFalse(item.responds(to: NSSelectorFromString("preferredImageVisibility")))
        }
        XCTAssertNotNil(item.image)
    }
}
