import Cocoa
import XCTest

/// Beautify can leave its padding clear. The shadow is the one beautify already
/// draws, and the canvas stays image + padding — the radius slider does not
/// grow the output.
final class TransparentShadowTests: XCTestCase {

    func testNoBackgroundKeepsTheShadowInsideThePadding() {
        let width = 40
        let height = 30
        let padding: CGFloat = 24
        let image = ImageProbe.solidImage(
            width: width, height: height,
            color: CGColor(srgbRed: 1, green: 0.2, blue: 0.6, alpha: 1))
        var config = BeautifyConfig()
        config.mode = .rounded
        config.padding = padding
        config.cornerRadius = 0
        config.shadowRadius = 20
        config.backgroundEnabled = false

        let result = BeautifyRenderer.render(image: image, config: config)
        XCTAssertEqual(result.size.width, CGFloat(width) + padding * 2, accuracy: 0.01)
        XCTAssertEqual(result.size.height, CGFloat(height) + padding * 2, accuracy: 0.01)
        XCTAssertTrue(result.flattensJPEGOntoWhite)

        let corner = ImageProbe.pixelColor(result, x: 0, y: 0)
        XCTAssertEqual(corner?.alphaComponent ?? 1, 0, accuracy: 0.02, "the padding corner stays clear")

        let margin = Int(padding)
        let center = ImageProbe.pixelColor(result, x: margin + width / 2, y: margin + height / 2)
        XCTAssertEqual(center?.alphaComponent ?? 0, 1, accuracy: 0.02)
        XCTAssertEqual(center?.redComponent ?? 0, 1, accuracy: 0.05)

        // The offset points downward, which is toward the bottom of the bitmap.
        let shadow = ImageProbe.pixelColor(result, x: margin + width / 2, y: margin + height + 6)
        XCTAssertGreaterThan(shadow?.alphaComponent ?? 0, 0.02)
        XCTAssertLessThan(shadow?.alphaComponent ?? 1, 1)
        XCTAssertLessThan(shadow?.redComponent ?? 1, 0.2)

        config.shadowRadius = 100
        let wider = BeautifyRenderer.render(image: image, config: config)
        XCTAssertEqual(wider.size, result.size, "raising the radius must not grow the canvas")
    }

    func testATransparentCornerStillShapesTheShadow() {
        let image = ImageProbe.makeImage(width: 40, height: 40) { context in
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 10, y: 0, width: 30, height: 40))
            context.fill(CGRect(x: 0, y: 10, width: 10, height: 30))
        }
        var config = BeautifyConfig()
        config.isWindowSnap = true
        config.padding = 16
        config.shadowRadius = 12
        config.backgroundEnabled = false
        let result = BeautifyRenderer.render(image: image, config: config)
        let pad = 16
        let totalH = Int(result.size.height.rounded())
        func bitmapY(sourceYFromBottom: Int) -> Int { totalH - 1 - (pad + sourceYFromBottom) }
        let emptyCorner = ImageProbe.pixelColor(result, x: pad + 2, y: bitmapY(sourceYFromBottom: 2))
        XCTAssertLessThan(emptyCorner?.alphaComponent ?? 1, 0.99)
        if let emptyCorner, emptyCorner.alphaComponent > 0.05 {
            XCTAssertLessThan(emptyCorner.redComponent, 0.5)
        }
        let body = ImageProbe.pixelColor(result, x: pad + 20, y: bitmapY(sourceYFromBottom: 20))
        XCTAssertEqual(body?.alphaComponent ?? 0, 1, accuracy: 0.02)
    }

    func testBeautifyStillPaintsAnOpaqueBackground() {
        let image = ImageProbe.solidImage(width: 20, height: 16)
        var config = BeautifyConfig()
        config.mode = .rounded
        config.padding = 24
        config.shadowRadius = 12
        config.styleIndex = 0
        let result = BeautifyRenderer.render(image: image, config: config)
        XCTAssertGreaterThan(result.size.width, image.size.width)
        let corner = ImageProbe.pixelColor(result, x: 0, y: 0)
        XCTAssertEqual(corner?.alphaComponent ?? 0, 1, accuracy: 0.02,
                       "beautify's shadow is composited onto its background")
        XCTAssertFalse(result.flattensJPEGOntoWhite)
    }

    func testJPEGMatsTheShadowOntoWhite() throws {
        guard ImageEncoder.isFormatAvailable(.jpeg) else { return }
        let image = ImageProbe.solidImage(width: 24, height: 18)
        var config = BeautifyConfig()
        config.mode = .rounded
        config.padding = 12
        config.cornerRadius = 0
        config.shadowRadius = 12
        config.backgroundEnabled = false
        let shadowed = BeautifyRenderer.render(image: image, config: config)
        XCTAssertTrue(shadowed.flattensJPEGOntoWhite)

        var data: Data?
        withDefaults(["imageFormat": "jpeg"]) {
            data = ImageEncoder.encode(shadowed)
        }
        let encoded = try XCTUnwrap(data)
        guard let rep = NSBitmapImageRep(data: encoded),
              let corner = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else {
            XCTFail("JPEG did not decode")
            return
        }
        XCTAssertGreaterThan(corner.redComponent, 0.9)
        XCTAssertGreaterThan(corner.greenComponent, 0.9)
        XCTAssertGreaterThan(corner.blueComponent, 0.9)
    }
}
