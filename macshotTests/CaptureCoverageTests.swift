import CoreGraphics
import XCTest

/// On some macOS 26+ setups `SCScreenshotManager.captureScreenshot(rect:)`
/// returns a buffer of the requested Retina size with only the 1x content
/// painted in the top-left quadrant and the rest transparent. Such a capture
/// must be rejected so the content-filter path takes over.
final class CaptureCoverageTests: XCTestCase {

    /// An image whose top-left `paintedWidth` x `paintedHeight` pixels (image
    /// space, y down) are opaque and the rest left transparent.
    private func capture(width: Int, height: Int, paintedWidth: Int, paintedHeight: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        // CGContext has a bottom-left origin: the image's top rows are the high y.
        context.fill(CGRect(x: 0, y: height - paintedHeight, width: paintedWidth, height: paintedHeight))
        return try XCTUnwrap(context.makeImage())
    }

    func testAFullyPaintedCaptureIsAccepted() throws {
        let image = try capture(width: 512, height: 288, paintedWidth: 512, paintedHeight: 288)
        XCTAssertFalse(ScreenCaptureManager.isUnderPaintedCapture(image))
    }

    func testOneXContentInATwoXBufferIsRejected() throws {
        // 5120x2880 requested, 2560x1440 painted — scaled down to keep the test fast.
        let image = try capture(width: 512, height: 288, paintedWidth: 256, paintedHeight: 144)
        XCTAssertTrue(ScreenCaptureManager.isUnderPaintedCapture(image))
    }

    func testAShortPaintedHeightIsStillRejected() throws {
        // The reported file: 5120x2820 canvas, content about 2560x1410.
        let image = try capture(width: 512, height: 282, paintedWidth: 256, paintedHeight: 141)
        XCTAssertTrue(ScreenCaptureManager.isUnderPaintedCapture(image))
    }

    func testClearCornersAloneDoNotRejectACapture() throws {
        // A fully painted display whose four corner pixels came back clear,
        // as a rounded-corner mask would leave them.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 512, height: 288,
            bitsPerComponent: 8, bytesPerRow: 512 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 288))
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 504, y: 0), CGPoint(x: 0, y: 280), CGPoint(x: 504, y: 280)] {
            context.clear(CGRect(origin: corner, size: CGSize(width: 8, height: 8)))
        }
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertFalse(ScreenCaptureManager.isUnderPaintedCapture(image))
    }

    func testAnEmptyCaptureIsRejected() throws {
        let image = try capture(width: 64, height: 36, paintedWidth: 0, paintedHeight: 0)
        XCTAssertTrue(ScreenCaptureManager.isUnderPaintedCapture(image))
    }

    func testASinglePixelCaptureIsJudgedByThatPixel() throws {
        XCTAssertFalse(ScreenCaptureManager.isUnderPaintedCapture(
            try capture(width: 1, height: 1, paintedWidth: 1, paintedHeight: 1)))
        XCTAssertTrue(ScreenCaptureManager.isUnderPaintedCapture(
            try capture(width: 1, height: 1, paintedWidth: 0, paintedHeight: 0)))
    }
}
