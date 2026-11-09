import Cocoa
import XCTest

/// Selection snapping reads the screenshot's own edges so a drag lands exactly
/// on a window or toolbar boundary. A wrong mapping snaps to the wrong place,
/// which is worse than not snapping at all.
final class BoundarySnapIndexTests: XCTestCase {

    /// An image with one hard vertical edge at `edgeX` and one horizontal edge
    /// at `edgeY` (both in image pixels, y from the bottom).
    private func edgedImage(width: Int = 200, height: Int = 160,
                            edgeX: Int = 80, edgeY: Int = 60) -> CGImage {
        let image = ImageProbe.makeImage(width: width, height: height) { context in
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0.05, alpha: 1))
            context.fill(CGRect(x: edgeX, y: 0, width: width - edgeX, height: height))
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: edgeY))
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testAVerticalEdgeIsFound() throws {
        let drawRect = NSRect(x: 0, y: 0, width: 200, height: 160)
        let index = try XCTUnwrap(BoundarySnapIndex.build(from: edgedImage(), drawRect: drawRect))
        let hit = try XCTUnwrap(index.nearestVertical(toViewX: 76, yMinView: 100, yMaxView: 150, radiusPoints: 12),
                                "a hard light/dark edge must be snappable")
        XCTAssertEqual(hit.viewPosition, 80, accuracy: 1.5)
    }

    func testAHorizontalEdgeIsFound() throws {
        let drawRect = NSRect(x: 0, y: 0, width: 200, height: 160)
        let index = try XCTUnwrap(BoundarySnapIndex.build(from: edgedImage(), drawRect: drawRect))
        // The band's top edge is 60px up from the bottom of the image, and the
        // index maps image rows back to AppKit's bottom-left origin, so it
        // lands at view Y 60.
        let hit = try XCTUnwrap(index.nearestHorizontal(toViewY: 56, xMinView: 10, xMaxView: 60, radiusPoints: 12))
        XCTAssertEqual(hit.viewPosition, 60, accuracy: 1.5)
    }

    func testNothingSnapsInAFlatImage() throws {
        let flat = ImageProbe.solidImage(width: 100, height: 100, color: CGColor(gray: 0.6, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let index = try XCTUnwrap(BoundarySnapIndex.build(from: flat, drawRect: NSRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertNil(index.nearestVertical(toViewX: 50, yMinView: 10, yMaxView: 90, radiusPoints: 20),
                     "a blank wall of colour has no edge to snap to")
        XCTAssertNil(index.nearestHorizontal(toViewY: 50, xMinView: 10, xMaxView: 90, radiusPoints: 20))
    }

    func testAnEdgeOutsideTheSnapRadiusIsIgnored() throws {
        let index = try XCTUnwrap(BoundarySnapIndex.build(
            from: edgedImage(), drawRect: NSRect(x: 0, y: 0, width: 200, height: 160)))
        XCTAssertNil(index.nearestVertical(toViewX: 20, yMinView: 10, yMaxView: 150, radiusPoints: 5),
                     "snapping must not yank the selection across the screen")
    }

    func testDegenerateImagesAreRefused() throws {
        let onePixel = ImageProbe.solidImage(width: 1, height: 1)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        XCTAssertNil(BoundarySnapIndex.build(from: onePixel, drawRect: NSRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertNil(BoundarySnapIndex.build(from: edgedImage(), drawRect: .zero),
                     "a zero draw rect has no mapping to image pixels")
    }

    func testAnInvertedSpanStillWorks() throws {
        // The caller may pass the drag's start/end in either order.
        let index = try XCTUnwrap(BoundarySnapIndex.build(
            from: edgedImage(), drawRect: NSRect(x: 0, y: 0, width: 200, height: 160)))
        let forward = index.nearestVertical(toViewX: 78, yMinView: 20, yMaxView: 140, radiusPoints: 12)
        let reversed = index.nearestVertical(toViewX: 78, yMinView: 140, yMaxView: 20, radiusPoints: 12)
        XCTAssertEqual(forward?.viewPosition, reversed?.viewPosition)
    }

    func testASpanOutsideTheImageDoesNotCrash() throws {
        let index = try XCTUnwrap(BoundarySnapIndex.build(
            from: edgedImage(), drawRect: NSRect(x: 0, y: 0, width: 200, height: 160)))
        _ = index.nearestVertical(toViewX: -500, yMinView: -900, yMaxView: 900, radiusPoints: 30)
        _ = index.nearestHorizontal(toViewY: 9999, xMinView: -50, xMaxView: 9999, radiusPoints: 30)
    }

    func testAScaledDrawRectMapsBackToViewCoordinates() throws {
        // A Retina capture: 400x320 pixels drawn into a 200x160 point rect.
        let retina = edgedImage(width: 400, height: 320, edgeX: 160, edgeY: 120)
        let index = try XCTUnwrap(BoundarySnapIndex.build(
            from: retina, drawRect: NSRect(x: 0, y: 0, width: 200, height: 160)))
        let hit = try XCTUnwrap(index.nearestVertical(toViewX: 76, yMinView: 20, yMaxView: 140, radiusPoints: 12))
        XCTAssertEqual(hit.viewPosition, 80, accuracy: 1.5, "pixel 160 of a 2x capture is point 80")
    }
}

/// The preview image behind the overlay is a downscale of the capture. It has
/// to stay proportional and never collapse to nothing.
final class DisplayPreviewImageTests: XCTestCase {

    private func image(_ width: Int, _ height: Int) -> CGImage {
        ImageProbe.solidImage(width: width, height: height)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testALargeCaptureIsScaledDownToTheCap() {
        let preview = ScreenCaptureManager.makeDisplayPreviewImage(from: image(5120, 2880), maxPixelDimension: 1400)
        XCTAssertEqual(max(preview.width, preview.height), 1400)
        XCTAssertEqual(Double(preview.width) / Double(preview.height),
                       5120.0 / 2880.0, accuracy: 0.01, "aspect ratio must survive")
    }

    func testASmallCaptureIsReturnedUntouched() {
        let original = image(800, 600)
        let preview = ScreenCaptureManager.makeDisplayPreviewImage(from: original, maxPixelDimension: 1400)
        XCTAssertEqual(preview.width, 800)
        XCTAssertEqual(preview.height, 600)
    }

    func testAnExtremeAspectRatioKeepsBothDimensionsAtLeastOnePixel() {
        let preview = ScreenCaptureManager.makeDisplayPreviewImage(from: image(10000, 3), maxPixelDimension: 1400)
        XCTAssertEqual(preview.width, 1400)
        XCTAssertGreaterThanOrEqual(preview.height, 1, "a zero-height image can't be drawn")
    }

    func testAOnePixelCaptureSurvives() {
        let preview = ScreenCaptureManager.makeDisplayPreviewImage(from: image(1, 1), maxPixelDimension: 1400)
        XCTAssertEqual(preview.width, 1)
        XCTAssertEqual(preview.height, 1)
    }
}

/// Beautify's shadow curves drive how the framed screenshot looks. They're
/// pure numbers, and all five have to stay in a sane range for any radius the
/// slider can produce.
final class BeautifyShadowCurveTests: XCTestCase {

    private let radii: [CGFloat] = [0, 0.5, 1, 10, 20, 50, 100, 500, 10_000]

    func testNoShadowAtZeroRadius() {
        XCTAssertEqual(BeautifyRenderer.shadowAlpha(for: 0), 0)
        XCTAssertEqual(BeautifyRenderer.contactShadowAlpha(for: 0), 0)
        XCTAssertEqual(BeautifyRenderer.shadowOffset(for: 0), 0)
        XCTAssertEqual(BeautifyRenderer.contactShadowOffset(for: 0), 0)
        XCTAssertEqual(BeautifyRenderer.contactShadowBlur(for: 0), 0)
    }

    func testNegativeRadiusIsTreatedAsNoShadow() {
        for radius in [-1, -100] as [CGFloat] {
            XCTAssertEqual(BeautifyRenderer.shadowAlpha(for: radius), 0)
            XCTAssertEqual(BeautifyRenderer.shadowOffset(for: radius), 0)
        }
    }

    func testAlphasStayWithinAValidRange() {
        for radius in radii {
            XCTAssertTrue((0...1).contains(BeautifyRenderer.shadowAlpha(for: radius)),
                          "alpha out of range at radius \(radius)")
            XCTAssertTrue((0...1).contains(BeautifyRenderer.contactShadowAlpha(for: radius)))
        }
    }

    func testOffsetsAndBlurAreCapped() {
        for radius in radii {
            XCTAssertLessThanOrEqual(BeautifyRenderer.shadowOffset(for: radius), 18)
            XCTAssertLessThanOrEqual(BeautifyRenderer.contactShadowOffset(for: radius), 10)
            XCTAssertLessThanOrEqual(BeautifyRenderer.contactShadowBlur(for: radius), 16)
        }
    }

    func testABiggerRadiusNeverProducesASmallerShadow() {
        var previousAlpha: CGFloat = -1
        var previousOffset: CGFloat = -1
        for radius in radii.sorted() {
            let alpha = BeautifyRenderer.shadowAlpha(for: radius)
            let offset = BeautifyRenderer.shadowOffset(for: radius)
            XCTAssertGreaterThanOrEqual(alpha, previousAlpha, "alpha dipped at radius \(radius)")
            XCTAssertGreaterThanOrEqual(offset, previousOffset, "offset dipped at radius \(radius)")
            previousAlpha = alpha
            previousOffset = offset
        }
    }

    func testTheContactShadowStaysTighterThanTheMainOne() {
        for radius in radii where radius > 0 {
            XCTAssertLessThan(BeautifyRenderer.contactShadowOffset(for: radius),
                              BeautifyRenderer.shadowOffset(for: radius),
                              "the contact shadow is the tight one under the window")
        }
    }
}
