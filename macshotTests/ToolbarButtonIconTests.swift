import AppKit
import XCTest

final class ToolbarButtonIconTests: XCTestCase {

    /// The text tool must not use a locale-sensitive SF Symbol: "textformat"
    /// renders as a CJK glyph on Chinese systems. The custom "T" icon has to
    /// actually paint pixels in the button center.
    @MainActor
    func testCustomTextIconRendersGlyph() throws {
        let view = ToolbarButtonView(action: .tool(.text), sfSymbol: "_custom.text", tooltip: "Text")
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        var opaque = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                opaque += 1
            }
        }
        XCTAssertGreaterThan(opaque, 20, "text icon drew nothing")
    }
}
