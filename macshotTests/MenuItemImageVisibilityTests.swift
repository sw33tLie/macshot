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

/// #497: with the menu bar menu open, ⌘V opens the clipboard image and ⌘O a
/// file, unless the user already chose a shortcut or another item owns it.
@MainActor
final class StatusMenuDefaultShortcutTests: XCTestCase {
    func testDefaultChordIsAddedWhenFree() {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open from Clipboard", action: nil, keyEquivalent: "")
        menu.addItem(item)
        AppDelegate.applyDefaultMenuKeyEquivalent("v", to: item, in: menu)
        XCTAssertEqual(item.keyEquivalent, "v")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
    }

    func testAUserShortcutIsKept() {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open from Clipboard", action: nil, keyEquivalent: "p")
        item.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(item)
        AppDelegate.applyDefaultMenuKeyEquivalent("v", to: item, in: menu)
        XCTAssertEqual(item.keyEquivalent, "p")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func testAChordAnotherItemOwnsIsNotDuplicated() {
        let menu = NSMenu()
        let other = NSMenuItem(title: "Pin from Clipboard", action: nil, keyEquivalent: "v")
        other.keyEquivalentModifierMask = .command
        let item = NSMenuItem(title: "Open from Clipboard", action: nil, keyEquivalent: "")
        menu.addItem(other)
        menu.addItem(item)
        AppDelegate.applyDefaultMenuKeyEquivalent("v", to: item, in: menu)
        XCTAssertEqual(item.keyEquivalent, "")
    }
}
