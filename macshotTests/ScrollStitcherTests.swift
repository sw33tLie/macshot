import CoreGraphics
import XCTest

/// End to end without a screen: frames of a synthetic page at a sequence of
/// scroll positions go through `ScrollStitcher`, and the result is compared
/// pixel for pixel with the page rendered in one piece. Elements that don't
/// scroll must appear exactly once.
@MainActor
final class ScrollStitcherTests: XCTestCase {

    private let width = 360, height = 300

    /// Page rows drawn into a context whose top-left is page row `scroll`.
    private func drawPage(_ context: CGContext, scroll: Int, height: Int, columns: Range<Int>? = nil) {
        let area = columns ?? 0..<width
        let rowHeight = 22
        for row in max(0, scroll / rowHeight - 1)...((scroll + height) / rowHeight + 1) {
            var seed = UInt64(row) &* 6364136223846793005 &+ 1442695040888963407
            func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
            let y = row * rowHeight - scroll
            var x = area.lowerBound + 10 + next() % 18
            while x < area.upperBound - 24 {
                let w = 8 + next() % 36
                context.setFillColor(CGColor(gray: CGFloat(next() % 70) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y + 5, width: min(w, area.upperBound - 10 - x), height: 10))
                x += w + 5 + next() % 9
            }
        }
    }

    private func image(height: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()!
    }

    private func stitch(_ positions: [Int], handlesPinnedContent: Bool = true,
                        frame: @escaping (CGContext, Int) -> Void) -> CGImage {
        let stitcher = ScrollStitcher(firstFrame: image(height: height) { frame($0, positions[0]) },
                                      handlesPinnedContent: handlesPinnedContent)
        for position in positions.dropFirst() {
            stitcher.add(image(height: height) { frame($0, position) })
        }
        return stitcher.finish()
    }

    /// Bytes of rows `rows` and columns `columns`, for exact comparison.
    private func pixels(_ image: CGImage, rows: Range<Int>, columns: Range<Int>? = nil) -> [UInt8] {
        let frame = ScrollFrameAnalyzer.frame(for: image)!
        let span = columns ?? 0..<image.width
        var out: [UInt8] = []
        for y in rows { for x in span { let o = frame.offset(x: x, y: y)!; out += [frame.bytes[o], frame.bytes[o + 1], frame.bytes[o + 2]] } }
        return out
    }


    /// Exact comparison that reports where images differ instead of dumping pixels.
    private func assertSameRows(_ a: CGImage, _ b: CGImage, rows: Range<Int>, columns: Range<Int>? = nil,
                                file: StaticString = #filePath, line: UInt = #line) {
        var differing: [Int] = []
        for row in rows where pixels(a, rows: row..<(row + 1), columns: columns) != pixels(b, rows: row..<(row + 1), columns: columns) {
            differing.append(row)
        }
        XCTAssertTrue(differing.isEmpty, "\(differing.count) rows differ, first at \(differing.first ?? -1), last at \(differing.last ?? -1)",
                      file: file, line: line)
    }

    private let positions = [0, 37, 90, 151, 230, 300, 372]

    func testPlainPageStitchesPixelExact() {
        let stitched = stitch(positions) { self.drawPage($0, scroll: $1, height: self.height) }
        let total = height + positions.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total) }
        assertSameRows(stitched, expected, rows: 0..<total)
    }

    /// Scrolling back up and down again must not add those rows twice.
    func testScrollingBackUpAddsNothingTwice() {
        let path = [0, 80, 160, 100, 40, 120, 200, 280]
        let stitched = stitch(path) { self.drawPage($0, scroll: $1, height: self.height) }
        let total = height + 280
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total) }
        assertSameRows(stitched, expected, rows: 0..<total)
    }

    /// A translucent navbar stays at the top once; everything below it is the page.
    func testTranslucentNavbarAppearsOnce() {
        let navbar = 40
        let stitched = stitch(positions) { context, scroll in
            self.drawPage(context, scroll: scroll, height: self.height)
            context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.16, alpha: 0.6))
            context.fill(CGRect(x: 0, y: 0, width: self.width, height: navbar))
        }
        let total = height + positions.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total) }
        assertSameRows(stitched, expected, rows: navbar..<total)
    }

    /// x.com: only the feed scrolls. Sidebars show once (first frame); below,
    /// their columns are plain background instead of repeated sidebar slices.
    func testFixedSidebarsAppearOnceAndTheFeedIsExact() {
        let feed = 90..<270
        let stitched = stitch(positions) { context, scroll in
            self.drawPage(context, scroll: scroll, height: self.height, columns: feed)
            self.drawPage(context, scroll: 0, height: self.height, columns: 0..<80)
            self.drawPage(context, scroll: 0, height: self.height, columns: 280..<360)
        }
        let total = height + positions.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total, columns: feed) }
        assertSameRows(stitched, expected, rows: 0..<total, columns: feed)
        // Below the first frame the sidebar columns are one flat colour.
        let below = pixels(stitched, rows: height..<total, columns: 0..<60)
        XCTAssertEqual(Set(stride(from: 0, to: below.count, by: 3).map { below[$0] }).count, 1)
    }

    /// Vercel: a cookie box floating at the bottom appears once, at the end.
    func testFloatingBottomBoxAppearsOnceAtTheEnd() {
        func box(_ context: CGContext) {
            context.setFillColor(CGColor(gray: 0.15, alpha: 1))
            context.fill(CGRect(x: 10, y: height - 70, width: 170, height: 56))
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 22, y: height - 58, width: 110, height: 9))
            context.fill(CGRect(x: 22, y: height - 38, width: 40, height: 14))
        }
        let stitched = stitch(positions) { context, scroll in
            self.drawPage(context, scroll: scroll, height: self.height)
            box(context)
        }
        let total = height + positions.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { context in
            self.drawPage(context, scroll: 0, height: total)
            context.translateBy(x: 0, y: CGFloat(total - self.height))
            box(context)
        }
        assertSameRows(stitched, expected, rows: 0..<total)
    }

    func testWithPinnedHandlingOffFramesAreStitchedAsCaptured() {
        let stitched = stitch([0, 120], handlesPinnedContent: false) { context, scroll in
            self.drawPage(context, scroll: scroll, height: self.height)
            context.setFillColor(CGColor(gray: 0.15, alpha: 1))
            context.fill(CGRect(x: 0, y: self.height - 40, width: self.width, height: 40))
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 20, y: self.height - 26, width: 100, height: 10))
        }
        XCTAssertEqual(stitched.height, height + 120)
    }
}
