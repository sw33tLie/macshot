import Cocoa
import XCTest
@testable import macshot

final class QuickTranslationLayoutTests: XCTestCase {
    @MainActor
    func testCloseShortcutUsesCharacterInsteadOfPhysicalKey() throws {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = QuickTranslationController()
        defer { controller.close() }
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
        })
        var closed = false
        controller.onClose = { closed = true }

        // A rearranged layout can produce a different character at physical W.
        let nonClose = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "z",
            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 13))
        _ = panel.performKeyEquivalent(with: nonClose)
        XCTAssertFalse(closed)

        let close = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 6))
        XCTAssertTrue(panel.performKeyEquivalent(with: close))
        XCTAssertTrue(closed)
    }

    @MainActor
    func testControlsFitAtMinimumContentSize() throws {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = QuickTranslationController()
        defer { controller.close() }
        let panel = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
        })
        panel.setContentSize(panel.contentMinSize)
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded()

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let views = descendants(of: content)
        let popups = views.compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(popups.count, 2)
        for popup in popups {
            let rect = popup.convert(popup.bounds, to: content)
            XCTAssertTrue(content.bounds.contains(rect))
            let row = try XCTUnwrap(popup.superview)
            let label = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextField }.first)
            XCTAssertGreaterThanOrEqual(label.frame.width + 1, label.intrinsicContentSize.width)
            XCTAssertFalse(label.frame.intersects(popup.frame))
        }
        for scrollView in views.compactMap({ $0 as? NSScrollView }) {
            XCTAssertGreaterThan(scrollView.frame.height, 0)
            XCTAssertTrue(content.bounds.contains(scrollView.convert(scrollView.bounds, to: content)))
        }
    }
}
