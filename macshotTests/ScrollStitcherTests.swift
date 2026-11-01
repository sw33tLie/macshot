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

    /// Wikipedia: a short sticky table of contents moves its highlight to the
    /// section scrolling in. Neither that pair nor a highlight region may put
    /// slices of it into the content, and the first frame shows it as seen.
    func testStickyContentsWithAMovingHighlightAppearsOnce() {
        // It follows the page until the header above it has scrolled away.
        let feed = 100..<340, toc = 0..<90, tocRows = 130, header = 50
        let path = [0, 30, 64, 101, 140, 182, 226, 262, 300, 341, 380, 420]
        func contents(_ context: CGContext, scroll: Int) {
            let top = max(0, header - scroll)
            context.saveGState()
            context.clip(to: CGRect(x: toc.lowerBound, y: top, width: toc.count, height: tocRows))
            let item = min(4, scroll / 90)
            context.setFillColor(CGColor(red: 0.75, green: 0.85, blue: 1, alpha: 1))
            context.fill(CGRect(x: toc.lowerBound, y: top + item * 22 + 2, width: toc.count, height: 18))
            self.drawPage(context, scroll: -top, height: tocRows + header, columns: toc)
            context.restoreGState()
        }
        let stitched = stitch(path) { context, scroll in
            self.drawPage(context, scroll: scroll, height: self.height, columns: feed)
            contents(context, scroll: scroll)
        }
        let total = height + path.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total, columns: feed) }
        assertSameRows(stitched, expected, rows: 0..<total, columns: feed)
        // The contents appears once, as in the first frame.
        let first = image(height: height) { contents($0, scroll: 0) }
        assertSameRows(stitched, first, rows: 0..<(header + tocRows), columns: toc)
        // Below it the column is plain: no slices of the contents.
        let below = pixels(stitched, rows: height..<total, columns: toc)
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

    /// A playing video must appear as one moment, not as strips from
    /// different moments stacked into a staircase.
    func testPlayingVideoIsPastedFromOneFrame() {
        let videoTop = 330, videoColumns = 60..<300
        func video(_ context: CGContext, top: Int, moment: Int) {
            var seed = UInt64(moment) &* 2862933555777941757 &+ 3037000493
            for y in stride(from: 0, to: 120, by: 8) {
                for x in stride(from: videoColumns.lowerBound, to: videoColumns.upperBound, by: 8) {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    context.setFillColor(CGColor(gray: CGFloat(seed >> 56) / 255, alpha: 1))
                    context.fill(CGRect(x: x, y: top + y, width: 8, height: 8))
                }
            }
        }
        let path = [0, 40, 85, 130, 170, 215, 260, 300]
        let stitched = stitch(path) { context, scroll in
            self.drawPage(context, scroll: scroll, height: self.height)
            video(context, top: videoTop - scroll, moment: scroll)
        }
        let rows = (videoTop + 8)..<(videoTop + 112), columns = (videoColumns.lowerBound + 8)..<(videoColumns.upperBound - 8)
        let got = pixels(stitched, rows: rows, columns: columns)
        let total = height + path.last!
        let moments = path.filter { p in
            let expected = image(height: total) { context in
                self.drawPage(context, scroll: 0, height: total)
                video(context, top: videoTop, moment: p)
            }
            return pixels(expected, rows: rows, columns: columns) == got
        }
        XCTAssertEqual(moments.count, 1, "the video region must match exactly one frame")
        // Everything outside the video is still the page, pixel for pixel.
        let expectedPage = image(height: total) { self.drawPage($0, scroll: 0, height: total) }
        assertSameRows(stitched, expectedPage, rows: 0..<(videoTop - 20))
        assertSameRows(stitched, expectedPage, rows: (videoTop + 140)..<total)
    }

    /// Figma: the cookie box slides up into view after the capture started.
    /// Strips taken while it moved must not keep slices of it; it appears
    /// once, at the end.
    func testABoxThatSlidesInAfterTheStartAppearsOnlyAtTheEnd() {
        func box(_ context: CGContext, rise: Int) {
            let top = height - rise
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(CGRect(x: 160, y: top, width: 190, height: 90))
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 172, y: top + 14, width: 150, height: 9))
            context.fill(CGRect(x: 172, y: top + 34, width: 120, height: 9))
            context.fill(CGRect(x: 172, y: top + 60, width: 60, height: 16))
        }
        // The box rises 0 → 100 px over the first frames, then stays.
        let path = [0, 30, 62, 95, 128, 160, 195, 230, 262, 300, 333, 370]
        let rises = [0, 25, 50, 75, 100, 100, 100, 100, 100, 100, 100, 100]
        let stitcher = ScrollStitcher(firstFrame: image(height: height) { self.drawPage($0, scroll: 0, height: self.height) })
        for (position, rise) in zip(path, rises).dropFirst() {
            stitcher.add(image(height: height) { context in
                self.drawPage(context, scroll: position, height: self.height)
                box(context, rise: rise)
            })
        }
        let stitched = stitcher.finish()
        let total = height + path.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total) }
        // Everything above the final box is the page, with no slices of the box.
        assertSameRows(stitched, expected, rows: 0..<(total - 100), columns: 150..<360)
    }

    /// The mouse pointer sits still over the page while it scrolls, so it
    /// looks like a small changing region. Pasting it would stamp a pointer
    /// into the image again and again (seen on Twitch and x.com).
    /// Booking.com: a cookie panel is held back, so each strip is taken from
    /// just above it, where the pointer rests (turning into a hand over
    /// links, so it isn't held back with the panel). The pointer is appended
    /// with the strips and is in the first frame; each spot is covered with
    /// the same content from a later frame that shows it uncovered. Only the
    /// last strips, which no later frame shows clear of it, may keep it.
    func testThePointerInTheAppendedRowsIsReplacedFromALaterFrame() {
        let panel = 70
        let pointer = CGRect(x: 230, y: height - panel - 30, width: 20, height: 26)
        func box(_ context: CGContext) {
            context.setFillColor(CGColor(gray: 0.15, alpha: 1))
            context.fill(CGRect(x: 0, y: height - panel, width: width, height: panel))
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 22, y: height - panel + 14, width: 110, height: 9))
            context.fill(CGRect(x: 22, y: height - panel + 34, width: 40, height: 14))
        }
        func arrow(_ context: CGContext, hand: Bool = false) {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(hand ? pointer.insetBy(dx: 3, dy: 0) : pointer)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(pointer.insetBy(dx: hand ? 6 : 4, dy: hand ? 8 : 5))
        }
        let path = [0, 40, 84, 126, 170, 212, 256, 300, 342, 386]
        let stitcher = ScrollStitcher(firstFrame: image(height: height) { context in
            self.drawPage(context, scroll: 0, height: self.height)
            box(context)
            arrow(context)
        })
        for (index, position) in path.enumerated().dropFirst() {
            stitcher.add(image(height: height) { context in
                self.drawPage(context, scroll: position, height: self.height)
                box(context)
                arrow(context, hand: index % 2 == 1)
            }, pointer: pointer.insetBy(dx: -6, dy: -6))
        }
        let stitched = stitcher.finish()
        let total = height + path.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total) }
        // Down to the last two strips, the page is exact.
        let lastStrips = path.last! - path[path.count - 3]
        assertSameRows(stitched, expected, rows: 0..<(total - panel - lastStrips))
    }

    /// A pointer resting over a fixed sidebar, outside the scrolling band,
    /// is no spot to patch from the content (and must not trip over the
    /// empty column range).
    func testAPointerOverAFixedSidebarIsLeftAlone() {
        let feed = 90..<270
        let pointer = CGRect(x: 30, y: height - 40, width: 20, height: 26)
        let stitcher = ScrollStitcher(firstFrame: image(height: height) { context in
            self.drawPage(context, scroll: 0, height: self.height, columns: feed)
            self.drawPage(context, scroll: 0, height: self.height, columns: 0..<80)
        })
        for position in positions.dropFirst() {
            stitcher.add(image(height: height) { context in
                self.drawPage(context, scroll: position, height: self.height, columns: feed)
                self.drawPage(context, scroll: 0, height: self.height, columns: 0..<80)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(pointer)
            }, pointer: pointer.insetBy(dx: -6, dy: -6))
        }
        let stitched = stitcher.finish()
        let total = height + positions.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total, columns: feed) }
        assertSameRows(stitched, expected, rows: 0..<total, columns: feed)
    }

    /// nature.com: a consent banner over most of the frame is held back, so
    /// little of each frame is left between the navbar and the banner. The
    /// rows that follow the scroll can then begin below where the usable
    /// part of the frame ends; that must give an empty range, not a crash.
    func testATallPanelUnderANavbarLeavingFewRowsDoesNotCrash() {
        let navbar = 40, panel = 196
        func chrome(_ context: CGContext) {
            context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.16, alpha: 0.6))
            context.fill(CGRect(x: 0, y: 0, width: self.width, height: navbar))
            context.setFillColor(CGColor(gray: 0.15, alpha: 1))
            context.fill(CGRect(x: 0, y: self.height - panel, width: self.width, height: panel))
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 22, y: self.height - panel + 20, width: 160, height: 10))
            context.fill(CGRect(x: 22, y: self.height - panel + 60, width: 90, height: 14))
        }
        let path = [0, 20, 44, 66, 90, 112, 136, 160, 182, 206, 230]
        let pointer = CGRect(x: 200, y: navbar + 20, width: 20, height: 26)
        let stitcher = ScrollStitcher(firstFrame: image(height: height) { context in
            self.drawPage(context, scroll: 0, height: self.height)
            chrome(context)
        })
        for position in path.dropFirst() {
            stitcher.add(image(height: height) { context in
                self.drawPage(context, scroll: position, height: self.height)
                chrome(context)
            }, pointer: pointer)
        }
        XCTAssertGreaterThanOrEqual(stitcher.finish().height, height)
    }

    /// Under a tall held-back panel the rows that follow the scroll can
    /// begin below the end of the usable frame (nature.com: a crash while
    /// patching the pointer). Derived ranges collapse instead of trapping.
    func testDerivedRowRangesCollapseInsteadOfTrapping() {
        XCTAssertEqual(ScrollStitcher.clampedRange(640, 460), 640..<640)
        XCTAssertEqual(ScrollStitcher.clampedRange(10, 40), 10..<40)
        XCTAssertEqual(ScrollStitcher.clampedRows(640, 460), 640...640)
        XCTAssertEqual(ScrollStitcher.clampedRows(10, 40), 10...40)
    }

    func testTheMousePointerIsNotPastedDownTheImage() {
        let pointer = CGRect(x: 170, y: 140, width: 20, height: 26)
        func arrow(_ context: CGContext) {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(pointer)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(pointer.insetBy(dx: 4, dy: 5))
        }
        let path = [0, 30, 62, 95, 128, 160, 195, 230, 262, 300]
        let stitcher = ScrollStitcher(firstFrame: image(height: height) { self.drawPage($0, scroll: 0, height: self.height) })
        for position in path.dropFirst() {
            stitcher.add(image(height: height) { context in
                self.drawPage(context, scroll: position, height: self.height)
                arrow(context)
            }, pointer: pointer.insetBy(dx: -6, dy: -6))
        }
        let stitched = stitcher.finish()
        let total = height + path.last!
        XCTAssertEqual(stitched.height, total)
        let expected = image(height: total) { self.drawPage($0, scroll: 0, height: total) }
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
