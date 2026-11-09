import AppKit
import XCTest

/// `NSScreen.screens` is empty while every display is asleep, during a display
/// reconfiguration, and on a headless Mac. Indexing it traps — for a menu-bar
/// app that runs for days, that reads as "it just quit on its own" (#387).
@MainActor
final class ScreenFallbackTests: XCTestCase {

    func testPreferredScreenMatchesWhatAppKitReports() {
        if NSScreen.screens.isEmpty {
            XCTAssertNil(NSScreen.preferred)
        } else {
            XCTAssertNotNil(NSScreen.preferred)
        }
    }

    func testPreferredScreenPrefersTheMainOne() throws {
        try XCTSkipIf(NSScreen.main == nil, "no main screen in this environment")
        XCTAssertEqual(NSScreen.preferred, NSScreen.main)
    }

    func testTheFallbackFrameIsAlwaysUsable() {
        let frame = NSScreen.preferredVisibleFrame
        XCTAssertGreaterThan(frame.width, 0, "UI positioned against this frame must not collapse")
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
    }

    func testTheFallbackFrameMatchesTheRealScreenWhenThereIsOne() throws {
        let screen = try XCTUnwrap(NSScreen.preferred)
        XCTAssertEqual(NSScreen.preferredVisibleFrame, screen.visibleFrame)
    }

    func testNoAppCodeIndexesTheScreenArrayDirectly() throws {
        // The whole point of the helper: a regression here is invisible until a
        // user's displays sleep at the wrong moment.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macshot")

        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  url.lastPathComponent != "ScreenFallback.swift",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                guard !text.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                if text.contains("NSScreen.screens[") || text.contains("NSScreen.screens.first!") {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            These index NSScreen.screens without a guard, which traps when no display is \
            available — use NSScreen.preferred / preferredVisibleFrame instead:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
