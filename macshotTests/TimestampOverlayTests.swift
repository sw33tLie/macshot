import AppKit
import XCTest

@MainActor
final class TimestampOverlayTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_759_184_260)

    func testStampIsDrawnAfterExistingPixels() throws {
        let image = ImageProbe.makeImage(width: 400, height: 220) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 220))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 240, y: 0, width: 160, height: 70))
        }
        XCTAssertTrue(isBlue(try bottomRightPixel(image)))

        let stamped = TimestampOverlay.stamp(image, capturedAt: capturedAt)

        XCTAssertFalse(isBlue(try bottomRightPixel(stamped)),
                       "the timestamp must remain visible over an annotation in the corner")
    }

    func testStampUsesTheFinalBeautifiedCorner() throws {
        let image = ImageProbe.solidImage(
            width: 496,
            height: 316,
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        XCTAssertTrue(isGreen(try bottomRightPixel(image)))

        let stamped = TimestampOverlay.stamp(image, capturedAt: capturedAt)

        XCTAssertFalse(isGreen(try bottomRightPixel(stamped)),
                       "burn-in belongs after Beautify, in the final output corner")
    }

    func testMissingDateAndTinyImagesStayUnchanged() {
        let image = ImageProbe.quadrantImage(width: 100, height: 80)
        XCTAssertTrue(TimestampOverlay.stamp(image, capturedAt: nil) === image)

        let tiny = ImageProbe.solidImage(width: 20, height: 20)
        XCTAssertTrue(TimestampOverlay.stamp(tiny, capturedAt: capturedAt) === tiny)
    }

    func testTransformsRedrawTimestampInTheNewBottomRightCorner() throws {
        let raw = ImageProbe.solidImage(
            width: 400,
            height: 220,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let data = CaptureAnnotationData.timestampOnly(rawImage: raw, capturedAt: capturedAt)
        let stamped = TimestampOverlay.stamp(raw, capturedAt: capturedAt)

        for transform in [
            ImageContextTransform.rotateLeft,
            .rotateRight,
            .flipHorizontal,
            .flipVertical,
        ] {
            let result = try XCTUnwrap(CaptureTransform.apply(
                transform,
                to: stamped,
                annotationData: data))

            let rotates = transform == .rotateLeft || transform == .rotateRight
            XCTAssertEqual(
                result.image.size,
                rotates ? NSSize(width: 220, height: 400) : raw.size)
            XCTAssertFalse(isBlue(try bottomRightPixel(result.image)))
            let transformedRaw = try XCTUnwrap(result.annotationData?.rawImage)
            XCTAssertTrue(isBlue(try bottomRightPixel(transformedRaw)),
                          "editable pixels must stay unstamped after \(transform)")
            XCTAssertEqual(result.annotationData?.editState?.capturedAt, capturedAt)
            XCTAssertTrue(result.annotationData?.annotations.isEmpty == true)
        }
    }

    func testTransformWithoutCaptureDateKeepsFlattenedBehavior() throws {
        let image = ImageProbe.quadrantImage(width: 400, height: 220)
        let result = try XCTUnwrap(CaptureTransform.apply(
            .rotateRight,
            to: image,
            annotationData: CaptureAnnotationData(
                rawImage: image,
                annotations: [],
                editState: nil)))

        XCTAssertEqual(result.image.size, NSSize(width: 220, height: 400))
        XCTAssertNil(result.annotationData)
    }

    private func bottomRightPixel(_ image: NSImage) throws -> NSColor {
        let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: image))
        return try XCTUnwrap(bitmap.colorAt(
            x: max(0, bitmap.pixelsWide - 12),
            y: max(0, bitmap.pixelsHigh - 12)))
    }

    private func isBlue(_ color: NSColor) -> Bool {
        color.redComponent < 0.1 && color.greenComponent < 0.1 && color.blueComponent > 0.9
    }

    private func isGreen(_ color: NSColor) -> Bool {
        color.redComponent < 0.1 && color.greenComponent > 0.9 && color.blueComponent < 0.1
    }
}
