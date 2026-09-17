import Cocoa
import Translation
import XCTest
@testable import macshot

final class TranslationLifecycleTests: XCTestCase {
    @MainActor
    func testQueuedRequestsKeepOnlyLatestPerWindow() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Apple Translation requires macOS 15") }
        let bridge = TranslationBridge()
        let firstWindow = UUID()
        let secondWindow = UUID()
        let config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "fr"))
        var completed: [String] = []

        bridge.translate(texts: ["first"], configuration: config, requestScope: firstWindow) { _ in
            completed.append("first")
        }
        bridge.translate(texts: ["old"], configuration: config, requestScope: secondWindow) { _ in
            completed.append("old")
        }
        bridge.translate(texts: ["latest"], configuration: config, requestScope: secondWindow) { _ in
            completed.append("latest")
        }
        XCTAssertEqual(completed, ["old"])
        bridge.cancel(requestScope: firstWindow)
        XCTAssertEqual(completed, ["old", "first"])
        XCTAssertNotNil(bridge.config)
        bridge.cancel(requestScope: secondWindow)
        XCTAssertEqual(completed, ["old", "first", "latest"])
        XCTAssertNil(bridge.config)
    }

    @MainActor
    func testReplacingActiveRequestDoesNotCancelAnotherWindow() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Apple Translation requires macOS 15") }
        let bridge = TranslationBridge()
        let firstWindow = UUID()
        let secondWindow = UUID()
        let config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "fr"))
        var completed: [String] = []

        bridge.translate(texts: ["old"], configuration: config, requestScope: firstWindow) { _ in
            completed.append("old")
        }
        bridge.translate(texts: ["other"], configuration: config, requestScope: secondWindow) { _ in
            completed.append("other")
        }
        bridge.translate(texts: ["latest"], configuration: config, requestScope: firstWindow) { _ in
            completed.append("latest")
        }
        XCTAssertEqual(completed, ["old"])
        bridge.cancel(requestScope: firstWindow)
        XCTAssertEqual(completed, ["old", "latest"])
        XCTAssertNotNil(bridge.config)
        bridge.cancel(requestScope: secondWindow)
        XCTAssertEqual(completed, ["old", "latest", "other"])
        XCTAssertNil(bridge.config)
    }

    @MainActor
    func testCancelledWindowCanStartFreshRequest() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Apple Translation requires macOS 15") }
        let bridge = TranslationBridge()
        let scope = UUID()
        let config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "fr"))
        var oldCount = 0
        var newCount = 0
        bridge.translate(texts: ["old"], configuration: config, requestScope: scope) { _ in
            oldCount += 1
        }
        bridge.cancel(requestScope: scope)
        bridge.cancel(requestScope: scope)
        XCTAssertEqual(oldCount, 1)
        bridge.translate(texts: ["new"], configuration: config, requestScope: scope) { _ in
            newCount += 1
        }
        XCTAssertEqual(newCount, 0)
        XCTAssertNotNil(bridge.config)
        bridge.cancel(requestScope: scope)
        XCTAssertEqual(oldCount, 1)
        XCTAssertEqual(newCount, 1)
    }

    @MainActor
    func testOverlayResetInvalidatesPendingTranslation() {
        let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let scope = overlay.translationRequestScope
        let requestID = overlay.translationRequestID
        overlay.isTranslating = true
        overlay.reset()
        XCTAssertNotEqual(overlay.translationRequestID, requestID)
        XCTAssertEqual(overlay.translationRequestScope, scope)
        XCTAssertFalse(overlay.isTranslating)
    }
}
