import CoreGraphics
import XCTest

/// Scroll capture along either axis: frames of a synthetic page go through
/// `ScrollCaptureStitcher`, which must find the axis the page scrolls on and
/// produce the page in one piece, pixel for pixel. Horizontal scrolling used
/// to be measured as "no movement" and never grew past the first frame.
@MainActor
final class ScrollCaptureStitcherTests: XCTestCase {

    private let width = 360, height = 300
    private let positions = [0, 37, 90, 151, 230, 300, 372]

    // MARK: - Synthetic pages

    /// A wide sheet of cells, drawn into a context whose left edge is page
    /// column `scroll`: rows of text-like bars in 72-pixel cells, each cell
    /// seeded by its position so every frame draws the same page.
    /// - Parameters:
    ///   - context: a top-left-origin context from `image(width:height:_:)`.
    ///   - scroll: the page column at the context's left edge.
    ///   - width: how many page columns to draw.
    ///   - rows: the context rows to draw into (default: the whole frame height).
    private func drawWidePage(_ context: CGContext, scroll: Int, width: Int, rows: Range<Int>? = nil) {
        let area = rows ?? 0..<height
        let cellWidth = 72, rowHeight = 22
        for column in max(0, scroll / cellWidth - 1)...((scroll + width) / cellWidth + 1) {
            for row in 0...(area.upperBound / rowHeight) {
                let y = row * rowHeight
                guard y >= area.lowerBound, y + 15 <= area.upperBound else { continue }
                var seed = UInt64(column * 7919 + row) &* 6364136223846793005 &+ 1442695040888963407
                func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
                let end = (column + 1) * cellWidth - scroll - 4
                var x = column * cellWidth - scroll + 4 + next() % 10
                while x < end - 6 {
                    let w = 6 + next() % 26
                    context.setFillColor(CGColor(gray: CGFloat(next() % 70) / 255, alpha: 1))
                    context.fill(CGRect(x: x, y: y + 5, width: min(w, end - x), height: 10))
                    x += w + 4 + next() % 8
                }
            }
        }
    }

    /// A tall page of text-like rows (as in `ScrollStitcherTests`), drawn into
    /// a context whose top edge is page row `scroll`.
    /// - Parameters:
    ///   - context: a top-left-origin context from `image(width:height:_:)`.
    ///   - scroll: the page row at the context's top edge.
    ///   - height: how many page rows to draw.
    private func drawTallPage(_ context: CGContext, scroll: Int, height: Int) {
        let rowHeight = 22
        for row in max(0, scroll / rowHeight - 1)...((scroll + height) / rowHeight + 1) {
            var seed = UInt64(row) &* 6364136223846793005 &+ 1442695040888963407
            func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
            let y = row * rowHeight - scroll
            var x = 10 + next() % 18
            while x < width - 24 {
                let w = 8 + next() % 36
                context.setFillColor(CGColor(gray: CGFloat(next() % 70) / 255, alpha: 1))
                context.fill(CGRect(x: x, y: y + 5, width: min(w, width - 10 - x), height: 10))
                x += w + 5 + next() % 9
            }
        }
    }

    /// A white BGRA sRGB image drawn with a top-left origin, like a capture.
    /// - Parameters:
    ///   - width: image width in pixels.
    ///   - height: image height in pixels.
    ///   - draw: draws the content over the white background.
    /// - Returns: the rendered image.
    private func image(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
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

    /// A frame-sized capture of the page drawn by `draw`.
    private func frame(_ draw: (CGContext) -> Void) -> CGImage {
        image(width: width, height: height, draw)
    }

    // MARK: - Pixel comparison

    /// RGB bytes of the pixel at column `x`, row `y` (top-left origin), or
    /// an empty array outside the image so a wrong size fails, not traps.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        guard let frame = ScrollFrameAnalyzer.frame(for: image), let o = frame.offset(x: x, y: y) else { return [] }
        return [frame.bytes[o + frame.redOffset], frame.bytes[o + frame.greenOffset], frame.bytes[o + frame.blueOffset]]
    }

    /// Exact comparison over `columns` × `rows` that reports which columns
    /// differ. Fails (instead of reading out of bounds) when the area isn't
    /// inside both images.
    private func assertSamePixels(_ a: CGImage, _ b: CGImage, columns: Range<Int>, rows: Range<Int>? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let rows = rows ?? 0..<min(a.height, b.height)
        guard columns.upperBound <= min(a.width, b.width), rows.upperBound <= min(a.height, b.height),
              let fa = ScrollFrameAnalyzer.frame(for: a), let fb = ScrollFrameAnalyzer.frame(for: b) else {
            XCTAssertTrue(false, "compared area \(columns) × \(rows) is outside \(a.width)×\(a.height) or \(b.width)×\(b.height)",
                          file: file, line: line)
            return
        }
        var differing: [Int] = []
        for x in columns {
            for y in rows {
                let oa = fa.offset(x: x, y: y)!, ob = fb.offset(x: x, y: y)!
                if fa.bytes[oa + fa.redOffset] != fb.bytes[ob + fb.redOffset]
                    || fa.bytes[oa + fa.greenOffset] != fb.bytes[ob + fb.greenOffset]
                    || fa.bytes[oa + fa.blueOffset] != fb.bytes[ob + fb.blueOffset] {
                    differing.append(x)
                    break
                }
            }
        }
        XCTAssertTrue(differing.isEmpty, "\(differing.count) columns differ, first at \(differing.first ?? -1), last at \(differing.last ?? -1)",
                      file: file, line: line)
    }

    // MARK: - Transposition

    func testTransposingSwapsRowsAndColumnsAndUndoesItself() {
        let source = image(width: 7, height: 4) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 5, y: 1, width: 1, height: 1))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 3, width: 2, height: 1))
        }
        let flipped = ScrollCaptureStitcher.transposed(source)!
        XCTAssertEqual(flipped.width, 4)
        XCTAssertEqual(flipped.height, 7)
        for x in 0..<7 { for y in 0..<4 { XCTAssertEqual(pixel(flipped, y, x), pixel(source, x, y), "(\(x), \(y))") } }
        XCTAssertEqual(pixel(flipped, 1, 5), [255, 0, 0])
        let back = ScrollCaptureStitcher.transposed(flipped)!
        XCTAssertEqual(back.width, 7)
        XCTAssertEqual(back.height, 4)
        assertSamePixels(back, source, columns: 0..<7)
        XCTAssertEqual(ScrollCaptureStitcher.transposed(CGRect(x: 10, y: 20, width: 30, height: 40)),
                       CGRect(x: 20, y: 10, width: 40, height: 30))
    }

    // MARK: - Axis detection

    /// The regression itself: measured in rows, a page scrolling sideways
    /// never appends anything.
    func testRowMatchingAloneNeverSeesAHorizontalScroll() {
        let rowsOnly = ScrollStitcher(firstFrame: frame { self.drawWidePage($0, scroll: 0, width: self.width) })
        for position in positions.dropFirst() {
            XCTAssertNotEqual(rowsOnly.add(frame { self.drawWidePage($0, scroll: position, width: self.width) }), .appended)
        }
        XCTAssertEqual(rowsOnly.finish().width, width)
    }

    func testHorizontalScrollStitchesPixelExact() {
        let stitcher = ScrollCaptureStitcher(firstFrame: frame { self.drawWidePage($0, scroll: 0, width: self.width) })
        for position in positions.dropFirst() {
            stitcher.add(frame { self.drawWidePage($0, scroll: position, width: self.width) })
        }
        XCTAssertEqual(stitcher.axis, .horizontal)
        let total = width + positions.last!
        XCTAssertEqual(stitcher.length, total)
        let stitched = stitcher.finish()
        XCTAssertEqual(stitched.width, total)
        XCTAssertEqual(stitched.height, height)
        let expected = image(width: total, height: height) { self.drawWidePage($0, scroll: 0, width: total) }
        assertSamePixels(stitched, expected, columns: 0..<total)
    }

    /// Frames decide: scroll events pointing the other way only break ties.
    func testAPreferredAxisDoesNotOverrideWhatTheFramesShow() {
        let stitcher = ScrollCaptureStitcher(firstFrame: frame { self.drawWidePage($0, scroll: 0, width: self.width) })
        for position in positions.dropFirst() {
            stitcher.add(frame { self.drawWidePage($0, scroll: position, width: self.width) }, preferredAxis: .vertical)
        }
        XCTAssertEqual(stitcher.axis, .horizontal)
        XCTAssertEqual(stitcher.finish().width, width + positions.last!)
    }

    /// A vertical capture is exactly what `ScrollStitcher` alone produces.
    func testVerticalScrollIsStitchedAsBefore() {
        let first = frame { self.drawTallPage($0, scroll: 0, height: self.height) }
        let both = ScrollCaptureStitcher(firstFrame: first)
        let rowsOnly = ScrollStitcher(firstFrame: first)
        for position in positions.dropFirst() {
            let next = frame { self.drawTallPage($0, scroll: position, height: self.height) }
            XCTAssertEqual(both.add(next), rowsOnly.add(next), "at \(position)")
        }
        XCTAssertEqual(both.axis, .vertical)
        let stitched = both.finish(), reference = rowsOnly.finish()
        let total = height + positions.last!
        XCTAssertEqual(stitched.height, total)
        XCTAssertEqual(stitched.width, width)
        XCTAssertEqual(reference.height, total)
        assertSamePixels(stitched, reference, columns: 0..<width)
    }

    func testStillFramesLeaveTheAxisUndecided() {
        let first = frame { self.drawWidePage($0, scroll: 0, width: self.width) }
        let stitcher = ScrollCaptureStitcher(firstFrame: first)
        XCTAssertEqual(stitcher.add(frame { self.drawWidePage($0, scroll: 0, width: self.width) }), .noMovement)
        XCTAssertNil(stitcher.axis)
        XCTAssertEqual(stitcher.length, height)
        let result = stitcher.finish()
        XCTAssertEqual(result.width, width)
        XCTAssertEqual(result.height, height)
    }

    // MARK: - Sticky content, sideways

    /// A spreadsheet's frozen first column stays once at the left; everything
    /// to its right is the sheet.
    func testAFrozenFirstColumnAppearsOnce() {
        let frozen = 56
        func column(_ context: CGContext) {
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: frozen, height: height))
            for row in 0..<(height / 22) {
                context.setFillColor(CGColor(gray: 0.3, alpha: 1))
                context.fill(CGRect(x: 8, y: row * 22 + 6, width: 10 + (row * 7) % 30, height: 9))
            }
        }
        let stitcher = ScrollCaptureStitcher(firstFrame: frame { context in
            self.drawWidePage(context, scroll: 0, width: self.width)
            column(context)
        })
        for position in positions.dropFirst() {
            stitcher.add(frame { context in
                self.drawWidePage(context, scroll: position, width: self.width)
                column(context)
            })
        }
        XCTAssertEqual(stitcher.axis, .horizontal)
        let total = width + positions.last!
        let stitched = stitcher.finish()
        XCTAssertEqual(stitched.width, total)
        let expected = image(width: total, height: height) { context in
            self.drawWidePage(context, scroll: 0, width: total)
            column(context)
        }
        assertSamePixels(stitched, expected, columns: 0..<total)
    }

    /// A toolbar above sideways-scrolling content (a timeline, a board) shows
    /// once in the first frame; past it, its rows are one flat colour instead
    /// of repeated toolbar slices, and the content is exact.
    func testAToolbarAboveTheScrollingContentAppearsOnce() {
        let toolbar = 0..<60, content = 70..<height
        let stitcher = ScrollCaptureStitcher(firstFrame: frame { context in
            self.drawWidePage(context, scroll: 0, width: self.width, rows: content)
            self.drawWidePage(context, scroll: 0, width: self.width, rows: toolbar)
        })
        for position in positions.dropFirst() {
            stitcher.add(frame { context in
                self.drawWidePage(context, scroll: position, width: self.width, rows: content)
                self.drawWidePage(context, scroll: 0, width: self.width, rows: toolbar)
            })
        }
        XCTAssertEqual(stitcher.axis, .horizontal)
        let total = width + positions.last!
        let stitched = stitcher.finish()
        XCTAssertEqual(stitched.width, total)
        let expected = image(width: total, height: height) { self.drawWidePage($0, scroll: 0, width: total, rows: content) }
        assertSamePixels(stitched, expected, columns: 0..<total, rows: content)
        // Right of the first frame the toolbar rows are one flat colour.
        let colors = Set((width..<max(width, stitched.width)).flatMap { x in (0..<50).map { y in pixel(stitched, x, y) } })
        XCTAssertEqual(colors.count, 1)
    }

    /// The pointer stays put while the page slides under it; it must not be
    /// stamped across the image, so its rectangle is transposed with the frame.
    /// It sits well off the frame's diagonal, where a rectangle left
    /// untransposed would cover a different spot and let the pointer through.
    func testTheMousePointerIsNotPastedAcrossTheImage() {
        let pointer = CGRect(x: 60, y: 200, width: 20, height: 26)
        func arrow(_ context: CGContext) {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(pointer)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(pointer.insetBy(dx: 4, dy: 5))
        }
        let path = [0, 30, 62, 95, 128, 160, 195, 230, 262, 300]
        let stitcher = ScrollCaptureStitcher(firstFrame: frame { self.drawWidePage($0, scroll: 0, width: self.width) })
        for position in path.dropFirst() {
            stitcher.add(frame { context in
                self.drawWidePage(context, scroll: position, width: self.width)
                arrow(context)
            }, pointer: pointer.insetBy(dx: -6, dy: -6))
        }
        XCTAssertEqual(stitcher.axis, .horizontal)
        let total = width + path.last!
        let stitched = stitcher.finish()
        XCTAssertEqual(stitched.width, total)
        let expected = image(width: total, height: height) { self.drawWidePage($0, scroll: 0, width: total) }
        assertSamePixels(stitched, expected, columns: 0..<total)
    }
}
