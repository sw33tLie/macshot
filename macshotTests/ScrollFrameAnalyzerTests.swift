import Cocoa
import XCTest

/// Scroll capture decides where a frozen header ends and where the scrollbar
/// starts by comparing consecutive frames. Get either wrong and the stitched
/// image repeats a header band or drags the scrollbar into the match.
final class ScrollFrameAnalyzerTests: XCTestCase {

    private let layouts: [(CGImageAlphaInfo, CGBitmapInfo, [Int])] = [
        (.premultipliedFirst, .byteOrder32Little, [2, 1, 0]), // BGRA
        (.premultipliedFirst, .byteOrder32Big, [1, 2, 3]),    // ARGB
        (.premultipliedLast, .byteOrder32Little, [3, 2, 1]),  // ABGR
        (.premultipliedLast, .byteOrder32Big, [0, 1, 2]),     // RGBA
        (.noneSkipFirst, .byteOrder32Big, [1, 2, 3]),
        (.noneSkipLast, .byteOrder32Little, [3, 2, 1]),
        (.premultipliedFirst, .byteOrderDefault, [1, 2, 3]),
        (.premultipliedLast, .byteOrderDefault, [0, 1, 2]),
    ]

    private func layoutFrame(_ layout: (CGImageAlphaInfo, CGBitmapInfo, [Int]), unused: UInt8 = 255,
                             pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        let width = 80, height = 40, stride = width * 4 + 16
        var bytes = [UInt8](repeating: unused, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                let rgb = pixel(x, y)
                for component in 0..<3 { bytes[y * stride + x * 4 + layout.2[component]] = rgb[component] }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: layout.0.rawValue | layout.1.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testMatchingColoursCompareAcrossAllSupportedByteLayouts() throws {
        let reference = try layoutFrame(layouts[0]) { _, _ in [40, 80, 120] }
        for layout in layouts {
            let image = try layoutFrame(layout) { _, _ in [40, 80, 120] }
            let colour = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(colour.redComponent, 40.0 / 255, accuracy: 0.01)
            XCTAssertEqual(colour.blueComponent, 120.0 / 255, accuracy: 0.01)
            XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: image, previous: reference, rightMarginPx: 0), 40)
            XCTAssertEqual(ScrollFrameAnalyzer.scrollbarWidth(current: image, previous: reference), 0)
        }
    }

    func testEachColourChannelParticipatesInHeaderAndScrollbarDetection() throws {
        for layout in layouts {
            let before = try layoutFrame(layout) { _, _ in [40, 80, 120] }
            for channel in 0..<3 {
                let after = try layoutFrame(layout) { x, y in
                    var rgb: [UInt8] = [40, 80, 120]
                    if y >= 12 || x >= 74 { rgb[channel] = 240 }
                    return rgb
                }
                XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 6), 12)
                // Use a scrollbar-only change so page content cannot obscure its inner edge.
                let scrollbar = try layoutFrame(layout) { x, _ in
                    var rgb: [UInt8] = [40, 80, 120]
                    if x >= 74 { rgb[channel] = 240 }
                    return rgb
                }
                XCTAssertEqual(ScrollFrameAnalyzer.scrollbarWidth(current: scrollbar, previous: before), 6)
            }
        }
    }

    func testUnusedPixelByteDoesNotLookLikeScrolling() throws {
        for layout in layouts where layout.0 == .noneSkipFirst || layout.0 == .noneSkipLast {
            let before = try layoutFrame(layout, unused: 0) { _, _ in [40, 80, 120] }
            let after = try layoutFrame(layout, unused: 255) { _, _ in [40, 80, 120] }
            XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 0), 40)
            XCTAssertEqual(ScrollFrameAnalyzer.scrollbarWidth(current: after, previous: before), 0)
        }
    }

    // MARK: - Fixtures

    /// Builds an image with an explicit row stride. `rowPadding` extra bytes per
    /// row reproduce what the window server does when it aligns rows — the case
    /// that used to be mis-addressed.
    private func makeFrame(width: Int, height: Int, rowPadding: Int = 0,
                           pixel: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        let bytesPerRow = width * 4 + rowPadding
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = b
                bytes[offset + 1] = g
                bytes[offset + 2] = r
                bytes[offset + 3] = 255
            }
            // Fill the padding with noise: reading it by mistake must be visible.
            for pad in 0..<rowPadding {
                bytes[y * bytesPerRow + width * 4 + pad] = UInt8((y * 31 + pad * 17) % 256)
            }
        }
        let data = try XCTUnwrap(CFDataCreate(nil, bytes, bytes.count))
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// A page with a fixed header of `headerRows` rows and content that scrolls
    /// by `scrollOffset` rows.
    private func makePage(width: Int = 80, height: Int = 60, headerRows: Int,
                          scrollOffset: Int, rowPadding: Int = 0,
                          scrollbarWidth: Int = 0) throws -> CGImage {
        try makeFrame(width: width, height: height, rowPadding: rowPadding) { x, y in
            if scrollbarWidth > 0 && x >= width - scrollbarWidth {
                // The scrollbar thumb moves with the scroll position.
                let thumbTop = 10 + scrollOffset
                return (y >= thumbTop && y < thumbTop + 15) ? (40, 40, 40) : (230, 230, 230)
            }
            if y < headerRows { return (10, 20, 30) }  // frozen header
            // Content: a horizontal stripe pattern that moves with the scroll.
            let contentRow = y + scrollOffset
            let value = UInt8((contentRow * 37) % 256)
            return (value, UInt8((contentRow * 11) % 256), UInt8((x * 5) % 256))
        }
    }

    // MARK: - Frame validation

    func testRegistrationShiftNeedsFiniteOverlappingFrames() {
        for shift: CGFloat in [.nan, .infinity, -.infinity, 800, -800, 1e18] {
            XCTAssertNil(ScrollFrameAnalyzer.validatedVerticalShift(shift, frameHeight: 800))
        }
        XCTAssertNil(ScrollFrameAnalyzer.validatedVerticalShift(10, frameHeight: 0))
        XCTAssertEqual(ScrollFrameAnalyzer.validatedVerticalShift(120.5, frameHeight: 800), 120.5)
        XCTAssertEqual(ScrollFrameAnalyzer.validatedVerticalShift(-120.5, frameHeight: 800), -120.5)
        XCTAssertEqual(ScrollFrameAnalyzer.validatedVerticalShift(0, frameHeight: 800), 0)
    }

    func testFrameRejectsUnsupportedPixelFormats() throws {
        let gray = try XCTUnwrap(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 10,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage())
        XCTAssertNil(ScrollFrameAnalyzer.frame(for: gray),
                     "an 8-bit grayscale buffer must be refused, not indexed as if it were BGRA")
    }

    func testFrameAcceptsAPaddedThirtyTwoBitImage() throws {
        let image = try makePage(headerRows: 0, scrollOffset: 0, rowPadding: 28)
        let frame = try XCTUnwrap(ScrollFrameAnalyzer.frame(for: image))
        XCTAssertEqual(frame.bytesPerRow, 80 * 4 + 28, "the analyzer must use the image's own stride")
    }

    func testOffsetsOutsideTheImageAreRefused() throws {
        let frame = try XCTUnwrap(ScrollFrameAnalyzer.frame(for: try makePage(headerRows: 0, scrollOffset: 0)))
        XCTAssertNil(frame.offset(x: -1, y: 0))
        XCTAssertNil(frame.offset(x: 0, y: -1))
        XCTAssertNil(frame.offset(x: frame.width, y: 0))
        XCTAssertNil(frame.offset(x: 0, y: frame.height))
        XCTAssertNotNil(frame.offset(x: frame.width - 1, y: frame.height - 1))
    }

    // MARK: - Frozen header

    func testHeaderIsFoundWhereTheContentStartsMoving() throws {
        let before = try makePage(headerRows: 18, scrollOffset: 0)
        let after = try makePage(headerRows: 18, scrollOffset: 12)
        XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 0), 18)
    }

    func testHeaderDetectionIsUnaffectedByRowPadding() throws {
        // The old code derived the stride as width*4, so every row after the
        // first was read from the wrong offset once the rows were padded.
        let before = try makePage(headerRows: 18, scrollOffset: 0, rowPadding: 44)
        let after = try makePage(headerRows: 18, scrollOffset: 12, rowPadding: 44)
        XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 0), 18,
                       "padded rows must give the same answer as unpadded ones")
    }

    func testAPageWithoutAHeaderReportsZeroFrozenRows() throws {
        let before = try makePage(headerRows: 0, scrollOffset: 0)
        let after = try makePage(headerRows: 0, scrollOffset: 9)
        XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 0), 0)
    }

    func testIdenticalFramesReportEveryRowFrozen() throws {
        let frame = try makePage(headerRows: 10, scrollOffset: 0)
        XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: frame, previous: frame, rightMarginPx: 0), 60,
                       "a pair that didn't scroll says nothing about a header")
    }

    func testTheScrollbarIsExcludedFromHeaderDetection() throws {
        // With the scrollbar included, its moving thumb makes the very first row
        // look changed and the header is missed.
        let before = try makePage(headerRows: 20, scrollOffset: 0, scrollbarWidth: 6)
        let after = try makePage(headerRows: 20, scrollOffset: 14, scrollbarWidth: 6)
        XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 10), 20)
    }

    func testMismatchedFrameSizesAreRefusedRatherThanGuessed() throws {
        let small = try makePage(width: 40, height: 30, headerRows: 5, scrollOffset: 0)
        let large = try makePage(width: 80, height: 60, headerRows: 5, scrollOffset: 5)
        XCTAssertNil(ScrollFrameAnalyzer.frozenTopRows(current: large, previous: small, rightMarginPx: 0))
        XCTAssertNil(ScrollFrameAnalyzer.scrollbarWidth(current: large, previous: small))
    }

    func testAMarginWiderThanTheFrameStillComparesSomething() throws {
        let before = try makePage(headerRows: 15, scrollOffset: 0)
        let after = try makePage(headerRows: 15, scrollOffset: 10)
        let rows = ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 9999)
        XCTAssertNotNil(rows, "an absurd margin must not divide the scan down to nothing")
    }

    // MARK: - Scrollbar

    func testScrollbarWidthMatchesTheMovingStrip() throws {
        let before = try makePage(headerRows: 0, scrollOffset: 0, scrollbarWidth: 8)
        let after = try makePage(headerRows: 0, scrollOffset: 20, scrollbarWidth: 8)
        let width = try XCTUnwrap(ScrollFrameAnalyzer.scrollbarWidth(current: after, previous: before))
        XCTAssertEqual(width, 8, accuracy: 2, "detected strip should track the scrollbar's real width")
    }

    func testScrollbarDetectionIsUnaffectedByRowPadding() throws {
        let before = try makePage(headerRows: 0, scrollOffset: 0, rowPadding: 12, scrollbarWidth: 8)
        let after = try makePage(headerRows: 0, scrollOffset: 20, rowPadding: 12, scrollbarWidth: 8)
        let width = try XCTUnwrap(ScrollFrameAnalyzer.scrollbarWidth(current: after, previous: before))
        XCTAssertEqual(width, 8, accuracy: 2)
    }

    func testNoScrollbarMeansZeroWidth() throws {
        // Content changes, but the right edge is part of that content and
        // changes too — so there is no *separate* static-then-moving strip.
        let before = try makeFrame(width: 80, height: 60) { _, _ in (100, 100, 100) }
        let after = try makeFrame(width: 80, height: 60) { _, _ in (100, 100, 100) }
        XCTAssertEqual(ScrollFrameAnalyzer.scrollbarWidth(current: after, previous: before), 0,
                       "two identical frames have no moving strip")
    }

    func testTinyFramesDoNotCrashTheScan() throws {
        for size in [1, 2, 3, 5] {
            let before = try makeFrame(width: size, height: size) { x, _ in (UInt8(x * 10), 0, 0) }
            let after = try makeFrame(width: size, height: size) { x, _ in (UInt8(x * 20), 0, 0) }
            XCTAssertNotNil(ScrollFrameAnalyzer.scrollbarWidth(current: after, previous: before),
                            "a \(size)x\(size) frame must still be comparable")
            XCTAssertNotNil(ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 0))
        }
    }

    func testOnePixelFrameIsHandled() throws {
        let a = try makeFrame(width: 1, height: 1) { _, _ in (0, 0, 0) }
        let b = try makeFrame(width: 1, height: 1) { _, _ in (255, 255, 255) }
        XCTAssertEqual(ScrollFrameAnalyzer.scrollbarWidth(current: a, previous: b), 0)
        XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: a, previous: b, rightMarginPx: 0), 0)
    }

    // MARK: - Noise tolerance

    func testSubtleNoiseIsNotMistakenForContentChange() throws {
        // Antialiasing and compression move a channel by a point or two; that
        // must not read as "this row scrolled".
        let before = try makePage(headerRows: 25, scrollOffset: 0)
        let after = try makeFrame(width: 80, height: 60) { x, y in
            if y < 25 { return (10, 21, 30) }  // header, off by one
            let contentRow = y + 12
            return (UInt8((contentRow * 37) % 256), UInt8((contentRow * 11) % 256), UInt8((x * 5) % 256))
        }
        XCTAssertEqual(ScrollFrameAnalyzer.frozenTopRows(current: after, previous: before, rightMarginPx: 0), 25)
    }
}
