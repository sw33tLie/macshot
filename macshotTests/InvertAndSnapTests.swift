import Cocoa
import XCTest

/// Inverting colours with a window-snapped selection used to flip the
/// screenshot behind the overlay while leaving the captured window — the part
/// that actually gets exported — in its original colours (issue #88).
@MainActor
final class InvertAndSnapTests: XCTestCase {

    private func makeOverlay() -> OverlayView {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        view.screenshotImage = ImageProbe.solidImage(
            width: 200, height: 160, color: CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        view.applySelection(NSRect(x: 20, y: 20, width: 100, height: 80))
        return view
    }

    private func red(_ image: NSImage?) -> CGFloat? {
        guard let image else { return nil }
        return ImageProbe.pixelColor(image, x: 5, y: 5)?.redComponent
    }

    // MARK: - The inversion itself

    func testInvertedCopyReversesTheOrderOfTheChannels() throws {
        // CIColorInvert works in Core Image's linear space, so the result isn't
        // 1 - value in sRGB terms; what must hold is that a dark channel comes
        // back bright and a bright one comes back dark.
        let source = ImageProbe.solidImage(
            width: 8, height: 8, color: CGColor(srgbRed: 0.75, green: 0.25, blue: 0, alpha: 1))
        let inverted = try XCTUnwrap(OverlayView.invertedCopy(of: source))
        let pixel = try XCTUnwrap(ImageProbe.pixelColor(inverted, x: 4, y: 4))

        XCTAssertLessThan(pixel.redComponent, 0.75, "the bright channel must darken")
        XCTAssertGreaterThan(pixel.greenComponent, 0.25, "the dim channel must brighten")
        XCTAssertEqual(pixel.blueComponent, 1.0, accuracy: 0.02, "black inverts to white")
        XCTAssertGreaterThan(pixel.greenComponent, pixel.redComponent)
    }

    func testInvertingTwiceReturnsTheOriginalColours() throws {
        let source = ImageProbe.quadrantImage(width: 16, height: 16)
        let once = try XCTUnwrap(OverlayView.invertedCopy(of: source))
        let twice = try XCTUnwrap(OverlayView.invertedCopy(of: once))

        for (x, y) in [(2, 2), (12, 2), (2, 12), (12, 12)] {
            let before = try XCTUnwrap(ImageProbe.pixelColor(source, x: x, y: y))
            let after = try XCTUnwrap(ImageProbe.pixelColor(twice, x: x, y: y))
            XCTAssertEqual(after.redComponent, before.redComponent, accuracy: 0.03, "pixel \(x),\(y)")
            XCTAssertEqual(after.blueComponent, before.blueComponent, accuracy: 0.03, "pixel \(x),\(y)")
        }
    }

    func testInvertedCopyKeepsTheSize() throws {
        let source = ImageProbe.solidImage(width: 37, height: 11)
        let inverted = try XCTUnwrap(OverlayView.invertedCopy(of: source))
        XCTAssertEqual(inverted.size, source.size)
    }

    // MARK: - Invert with a snapped window

    func testSnappedWindowPreviewKeepsEffectsWithAndWithoutShadows() throws {
        for shadow: CGFloat in [0, 20] {
            let overlay = makeOverlay()
            let windowImage = ImageProbe.solidImage(width: 100, height: 80,
                color: CGColor(srgbRed: 0.1, green: 0.8, blue: 0.3, alpha: 1))
            overlay.snappedWindowImage = windowImage
            overlay.selectionIsWindowSnap = true
            overlay.beautifyEnabled = true
            overlay.beautifyMode = .window
            overlay.beautifyPadding = 16
            overlay.beautifyShadowRadius = shadow
            overlay.beautifyStyleIndex = 0
            overlay.effectsPreset = .mono
            overlay.effectsBrightness = 0
            overlay.effectsContrast = 1
            overlay.effectsSaturation = 1
            overlay.effectsSharpness = 0
            let preview = ImageProbe.makeImage(width: 200, height: 160) { cg in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
                overlay.draw(overlay.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            let actual = try XCTUnwrap(ImageProbe.pixelColor(preview, x: 70, y: 100))
            let expected = try XCTUnwrap(ImageProbe.pixelColor(
                ImageEffects.apply(to: windowImage, config: overlay.effectsConfig), x: 50, y: 40))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.03, "shadow \(shadow)")
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.03, "shadow \(shadow)")
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.03, "shadow \(shadow)")
        }
    }

    func testInvertFlipsTheSnappedWindowCaptureToo() throws {
        let overlay = makeOverlay()
        overlay.snappedWindowImage = ImageProbe.solidImage(
            width: 100, height: 80, color: CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        let originalSnapRed = try XCTUnwrap(red(overlay.snappedWindowImage))

        overlay.handleToolbarAction(.invertColors)

        let invertedSnapRed = try XCTUnwrap(red(overlay.snappedWindowImage))
        XCTAssertLessThan(invertedSnapRed, originalSnapRed - 0.3,
                          "the window capture is what gets exported, so it has to invert as well")
    }

    func testInvertStillFlipsTheScreenshot() throws {
        let overlay = makeOverlay()
        let before = try XCTUnwrap(red(overlay.screenshotImage))
        overlay.handleToolbarAction(.invertColors)
        let after = try XCTUnwrap(red(overlay.screenshotImage))
        XCTAssertLessThan(after, before - 0.1, "a bright red screenshot must come back darker")
    }

    func testUndoRestoresBothImages() throws {
        let overlay = makeOverlay()
        overlay.snappedWindowImage = ImageProbe.solidImage(
            width: 100, height: 80, color: CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        let screenshotBefore = try XCTUnwrap(red(overlay.screenshotImage))
        let snapBefore = try XCTUnwrap(red(overlay.snappedWindowImage))

        overlay.handleToolbarAction(.invertColors)
        overlay.undo()

        XCTAssertEqual(try XCTUnwrap(red(overlay.screenshotImage)), screenshotBefore, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(red(overlay.snappedWindowImage)), snapBefore, accuracy: 0.03,
                       "undo has to put the window capture back too")
    }

    func testRedoAppliesTheInversionAgain() throws {
        let overlay = makeOverlay()
        overlay.snappedWindowImage = ImageProbe.solidImage(
            width: 100, height: 80, color: CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        let snapBefore = try XCTUnwrap(red(overlay.snappedWindowImage))

        overlay.handleToolbarAction(.invertColors)
        let afterInvert = try XCTUnwrap(red(overlay.snappedWindowImage))
        overlay.undo()
        overlay.redo()

        XCTAssertEqual(try XCTUnwrap(red(overlay.snappedWindowImage)), afterInvert, accuracy: 0.03)
        XCTAssertLessThan(afterInvert, snapBefore - 0.3)
    }

    func testInvertWorksWithoutASnappedWindow() throws {
        let overlay = makeOverlay()
        let before = try XCTUnwrap(red(overlay.screenshotImage))
        overlay.handleToolbarAction(.invertColors)
        XCTAssertNil(overlay.snappedWindowImage)
        XCTAssertLessThan(try XCTUnwrap(red(overlay.screenshotImage)), before - 0.1)
    }

    func testFlippingDoesNotDisturbTheSnappedWindowImage() throws {
        // Only invert touches it; a flip must leave it alone rather than
        // restoring a nil over it on undo.
        let overlay = makeOverlay()
        let snap = ImageProbe.solidImage(width: 100, height: 80)
        overlay.snappedWindowImage = snap

        overlay.flipImageHorizontally()
        XCTAssertTrue(overlay.snappedWindowImage === snap)
        overlay.undo()
        XCTAssertTrue(overlay.snappedWindowImage === snap, "undoing a flip must not clear the window capture")
    }
}
