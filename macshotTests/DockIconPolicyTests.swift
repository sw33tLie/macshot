import Cocoa
import XCTest

/// "Hide Dock icon" (Settings → General) keeps macshot a menu bar app while
/// Settings or an editor window is open. By default those windows still put
/// it in the Dock.
final class DockIconPolicyTests: XCTestCase {
    func testOpenWindowsShowTheDockIconByDefault() {
        withDefaults([DockIconPolicy.hideKey: nil]) {
            XCTAssertEqual(DockIconPolicy.policyForOpenWindow(), .regular)
        }
    }

    func testHideDockIconKeepsMacshotInTheMenuBar() {
        withDefaults([DockIconPolicy.hideKey: true]) {
            XCTAssertEqual(DockIconPolicy.policyForOpenWindow(), .accessory)
        }
        withDefaults([DockIconPolicy.hideKey: false]) {
            XCTAssertEqual(DockIconPolicy.policyForOpenWindow(), .regular)
        }
    }
}
