import CoreGraphics
import XCTest

/// Scroll capture has to measure the scroll exactly even when parts of the
/// frame don't scroll: translucent navbars (macshot.io), fixed sidebars beside
/// a feed (x.com), fixed gradient backgrounds, floating cookie boxes. Frames
/// here are drawn from a deterministic "page" at a given scroll offset, with
/// those elements layered on top, and the matcher must report the true shift.
@MainActor
final class ScrollFrameMatcherTests: XCTestCase {

    private let width = 400, height = 320

    /// Deterministic page content: rows of "words" (dark blocks) with varied
    /// widths and positions, so any shift is unambiguous.
    private func drawPage(_ context: CGContext, scroll: Int, rowHeight: Int = 24, sparse: Bool = false,
                          repetitive: Bool = false, columns: Range<Int>? = nil) {
        let area = columns ?? 0..<width
        let first = max(0, scroll / rowHeight - 1), last = (scroll + height) / rowHeight + 1
        for row in first...last {
            if sparse, row % 4 != 0 { continue }
            var seed = UInt64(repetitive ? 7 : row) &* 6364136223846793005 &+ 1442695040888963407
            func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
            let y = row * rowHeight - scroll
            var x = area.lowerBound + 12 + (repetitive ? 0 : next() % 20)
            while x < area.upperBound - 30 {
                let w = 10 + next() % 40
                context.setFillColor(CGColor(gray: CGFloat(next() % 60) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y + 6, width: min(w, area.upperBound - 12 - x), height: 11))
                x += w + 6 + next() % 10
            }
            if repetitive {
                // Only a small "row number" tells otherwise identical rows apart.
                context.setFillColor(CGColor(gray: 0.1, alpha: 1))
                context.fill(CGRect(x: area.upperBound - 28, y: y + 6, width: 4 + row % 16, height: 11))
            }
        }
    }

    /// A frame with top-left drawing coordinates.
    private func frame(_ draw: (CGContext) -> Void) -> ScrollFrameMatcher.Samples {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return ScrollFrameMatcher.samples(of: context.makeImage()!)!
    }

    private func match(_ from: Int, _ to: Int, hint: Int = 0,
                       _ draw: @escaping (CGContext, Int) -> Void) -> ScrollFrameMatcher.Match? {
        ScrollFrameMatcher.match(previous: frame { draw($0, from) }, current: frame { draw($0, to) }, hint: hint)
    }

    // MARK: - Shifts

    func testPlainScrollIsMeasuredExactly() {
        for shift in [7, 40, 121, 200, -60] {
            let start = 300
            let result = match(start, start + shift) { self.drawPage($0, scroll: $1) }
            XCTAssertEqual(result?.shift, shift, "scrolled \(shift) px")
            XCTAssertEqual(result?.fixedSides, [])
        }
    }

    func testIdenticalFramesMeanNoScroll() {
        XCTAssertEqual(match(500, 500) { self.drawPage($0, scroll: $1) }?.shift, 0)
    }

    /// Content that no shift explains (the page was replaced, or scrolled
    /// past all overlap) is reported as unmatched, not forced into a shift.
    func testUnrelatedFramesAreNotMatched() {
        let page = frame { self.drawPage($0, scroll: 100) }
        let other = frame { self.drawPage($0, scroll: 0, repetitive: true) }
        XCTAssertNil(ScrollFrameMatcher.match(previous: page, current: other))
    }

    /// macshot.io: a navbar that blurs (here: tints) whatever scrolls under it,
    /// so its pixels change on every frame. It must not pull the shift to 0.
    func testTranslucentNavbarDoesNotHideTheScroll() {
        let result = match(400, 460) { context, scroll in
            self.drawPage(context, scroll: scroll)
            context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 0.55))
            context.fill(CGRect(x: 0, y: 0, width: self.width, height: 48))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 20, y: 18, width: 70, height: 12))   // the logo
        }
        XCTAssertEqual(result?.shift, 60)
    }

    /// x.com: fixed columns on both sides of the feed. They are reported so
    /// the stitched image shows them once, and they don't affect the shift.
    func testFixedSidebarsAreReportedAndIgnored() {
        let result = match(200, 290) { context, scroll in
            self.drawPage(context, scroll: scroll, columns: 100..<300)
            self.drawPage(context, scroll: 0, columns: 0..<90)        // left nav: never moves
            self.drawPage(context, scroll: 1000, columns: 310..<400)  // right sidebar
        }
        XCTAssertEqual(result?.shift, 90)
        let sides = result?.fixedSides ?? []
        XCTAssertEqual(sides.count, 2)
        XCTAssertEqual(sides.first?.lowerBound, 0)
        XCTAssertLessThanOrEqual(sides.first?.upperBound ?? .max, 112)
        XCTAssertGreaterThanOrEqual(sides.last?.lowerBound ?? 0, 285)
        XCTAssertEqual(sides.last?.upperBound, 400)
    }

    /// A background gradient that stays put while sparse text scrolls over it
    /// shifts whole rows' brightness; it must not decide the match.
    func testFixedGradientBackgroundCancelsOut() {
        let result = match(600, 680) { context, scroll in
            let colors = [CGColor(red: 0.12, green: 0.24, blue: 0.45, alpha: 1),
                          CGColor(red: 0.69, green: 0.42, blue: 0.70, alpha: 1)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil)!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: self.height), options: [])
            self.drawPage(context, scroll: scroll, sparse: true)
        }
        XCTAssertEqual(result?.shift, 80)
    }

    /// Rows that differ only by a small number: the right shift still wins.
    func testRepetitiveRowsStillAlignExactly() {
        let result = match(240, 285, hint: 40) { self.drawPage($0, scroll: $1, repetitive: true) }
        XCTAssertEqual(result?.shift, 45)
    }

    // MARK: - Pinned bottom content

    /// Vercel: a cookie box floating at the bottom-left over part of the
    /// width. Its rows must be held back so it isn't repeated in every strip.
    func testFloatingBottomBoxIsHeldBack() {
        let result = match(300, 370) { context, scroll in
            self.drawPage(context, scroll: scroll)
            context.setFillColor(CGColor(gray: 0.15, alpha: 1))
            context.fill(CGRect(x: 10, y: 250, width: 180, height: 60))
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 24, y: 262, width: 120, height: 10))   // "We use cookies"
            context.fill(CGRect(x: 24, y: 284, width: 40, height: 14))    // "Accept"
        }
        XCTAssertEqual(result?.shift, 70)
        XCTAssertGreaterThanOrEqual(result?.staticBottomRows ?? 0, 70, "the whole box, including its top padding")
        XCTAssertLessThanOrEqual(result?.staticBottomRows ?? .max, height * 35 / 100)
    }

    func testAPageWithoutPinnedContentHoldsNothingBack() {
        XCTAssertEqual(match(300, 370) { self.drawPage($0, scroll: $1) }?.staticBottomRows, 0)
    }

    func testFullWidthBannerWithPlainPaddingIsHeldBack() {
        let result = match(300, 350) { context, scroll in
            self.drawPage(context, scroll: scroll)
            context.setFillColor(CGColor(gray: 0.13, alpha: 1))
            context.fill(CGRect(x: 0, y: 250, width: self.width, height: 70))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 30, y: 290, width: 200, height: 10))   // text near the bottom only
        }
        XCTAssertEqual(result?.shift, 50)
        XCTAssertGreaterThanOrEqual(result?.staticBottomRows ?? 0, 70)
    }
}
