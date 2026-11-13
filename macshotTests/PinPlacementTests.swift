import Cocoa
import XCTest

/// Where a pin opens. The default keeps the long-standing centered placement;
/// the capture-location option (#331) must put the pin back over the pixels it
/// was captured from without ever leaving it off screen.
@MainActor
final class PinPlacementTests: XCTestCase {

    private let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let mainVisible = NSRect(x: 0, y: 70, width: 1440, height: 805)
    /// An external display to the left of and above the main one.
    private let external = NSRect(x: -1920, y: 300, width: 1920, height: 1080)

    private func frame(
        _ size: NSSize,
        source: NSRect?,
        contentOrigin: NSPoint? = nil,
        placement: PinPlacement = .captureLocation,
        screens: [NSRect]? = nil
    ) -> NSRect {
        PinWindowController.initialFrame(
            imageSize: size,
            source: source.map { PinSource(rect: $0, contentOrigin: contentOrigin) },
            placement: placement,
            screenFrames: screens ?? [main, external],
            preferredVisibleFrame: mainVisible
        )
    }

    private func centered(_ size: NSSize) -> NSRect {
        NSRect(x: mainVisible.midX - size.width / 2, y: mainVisible.midY - size.height / 2,
               width: size.width, height: size.height)
    }

    private func assertOnScreen(_ rect: NSRect, _ screen: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(screen.insetBy(dx: -0.001, dy: -0.001).contains(rect), "\(rect) left \(screen)",
                      file: file, line: line)
    }

    // MARK: - Default placement

    func testScreenCenterIgnoresTheSourceRect() {
        let size = NSSize(width: 300, height: 200)
        XCTAssertEqual(frame(size, source: NSRect(x: 10, y: 10, width: 300, height: 200), placement: .screenCenter),
                       centered(size))
    }

    func testScreenCenterStillCapsAtEightyPercent() {
        let result = frame(NSSize(width: 2880, height: 1800), source: nil, placement: .screenCenter)
        XCTAssertEqual(result.height, mainVisible.height * 0.8, accuracy: 0.001)
        XCTAssertEqual(result.width, mainVisible.height * 0.8 * 1.6, accuracy: 0.001)
        XCTAssertEqual(result.midX, mainVisible.midX, accuracy: 0.001)
        XCTAssertEqual(result.midY, mainVisible.midY, accuracy: 0.001)
    }

    func testPinsWithoutASourceRectStayCentered() {
        let size = NSSize(width: 300, height: 200)
        XCTAssertEqual(frame(size, source: nil), centered(size))
    }

    // MARK: - Capture location

    func testSelectionSizedImageLandsExactlyOverItsSource() {
        let source = NSRect(x: 120.5, y: 340, width: 300, height: 200)
        XCTAssertEqual(frame(source.size, source: source), source)
    }

    func testFullScreenCaptureKeepsTheEightyPercentCap() {
        let result = frame(main.size, source: main)
        XCTAssertEqual(result.width, main.width * 0.8, accuracy: 0.001)
        XCTAssertEqual(result.height, main.height * 0.8, accuracy: 0.001)
        XCTAssertEqual(result.midX, main.midX, accuracy: 0.001)
        XCTAssertEqual(result.midY, main.midY, accuracy: 0.001)
    }

    func testSelectionWithinTheCapIsNotScaled() {
        let source = NSRect(x: 100, y: 50, width: main.width * 0.8, height: main.height * 0.8)
        XCTAssertEqual(frame(source.size, source: source), source)
    }

    func testPaddedImageWithoutAContentOriginIsCenteredOnTheSelection() {
        let source = NSRect(x: 500, y: 400, width: 300, height: 200)
        let result = frame(NSSize(width: 380, height: 280), source: source)
        XCTAssertEqual(result.midX, source.midX, accuracy: 0.001)
        XCTAssertEqual(result.midY, source.midY, accuracy: 0.001)
        XCTAssertEqual(result.size, NSSize(width: 380, height: 280))
    }

    func testBeautifiedContentGoesBackOverItsSelection() {
        let source = NSRect(x: 500, y: 300, width: 300, height: 200)
        for mode in [BeautifyMode.window, .rounded] {
            var config = BeautifyConfig()
            config.mode = mode
            let output = BeautifyRenderer.render(image: ImageProbe.solidImage(width: 300, height: 200), config: config)
            let content = BeautifyRenderer.contentRect(forImageSize: source.size, config: config)

            let result = frame(output.size, source: source, contentOrigin: content.origin)
            XCTAssertEqual(result.size, output.size, "\(mode)")
            XCTAssertEqual(result.minX + content.minX, source.minX, accuracy: 0.001, "\(mode)")
            XCTAssertEqual(result.minY + content.minY, source.minY, accuracy: 0.001, "\(mode)")
        }
    }

    func testContentRectMatchesTheRenderedLayout() {
        var config = BeautifyConfig()
        config.padding = 40
        let size = NSSize(width: 300, height: 200)

        config.mode = .rounded
        let rounded = BeautifyRenderer.render(image: ImageProbe.solidImage(width: 300, height: 200), config: config)
        XCTAssertEqual(BeautifyRenderer.contentRect(forImageSize: size, config: config),
                       NSRect(x: 40, y: 40, width: 300, height: 200))
        XCTAssertEqual(rounded.size, NSSize(width: 380, height: 280))

        // The window style's title bar sits above the content, not around it.
        config.mode = .window
        let window = BeautifyRenderer.render(image: ImageProbe.solidImage(width: 300, height: 200), config: config)
        let content = BeautifyRenderer.contentRect(forImageSize: size, config: config)
        XCTAssertEqual(content.minY, 40)
        XCTAssertGreaterThan(window.size.height - content.maxY, content.minY)
    }

    func testPaddingPastTheScreenEdgeIsPushedBackOnScreen() {
        let source = NSRect(x: 0, y: 700, width: 300, height: 200)
        let result = frame(NSSize(width: 380, height: 280), source: source)
        XCTAssertEqual(result.size, NSSize(width: 380, height: 280))
        assertOnScreen(result, main)
    }

    func testPixelSnappingPastTheEdgeStillClamps() {
        // A 2x selection snapped to 440.5 + 1000 ends half a point past the
        // screen. That sliver must not count as spanning a display.
        let source = NSRect(x: 440.5, y: 0, width: 1000, height: 100)
        let padded = NSSize(width: 1096, height: 196)
        let right = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        for screens in [[main], [main, right]] {
            let result = frame(padded, source: source, contentOrigin: NSPoint(x: 48, y: 48), screens: screens)
            assertOnScreen(result, main)
        }
    }

    func testSelectionOvershootingIntoNoDisplayIsClamped() {
        // Repositioning a selection with Space can carry it past an edge with no neighbour.
        let source = NSRect(x: 1400, y: 400, width: 90, height: 60)
        let result = frame(source.size, source: source, screens: [main])
        XCTAssertEqual(result.size, source.size)
        assertOnScreen(result, main)
    }

    func testUsesTheDisplayItWasCapturedFrom() {
        let source = NSRect(x: -1800, y: 1200, width: 400, height: 150)
        XCTAssertEqual(frame(source.size, source: source), source)
        XCTAssertEqual(frame(NSSize(width: 480, height: 230), source: source).maxY, external.maxY, accuracy: 0.001)
    }

    func testSelectionSpanningDisplaysStaysWhereItWas() {
        let source = NSRect(x: -200, y: 400, width: 600, height: 300)
        XCTAssertEqual(frame(source.size, source: source), source)
    }

    func testBeautifiedSelectionSpanningDisplaysKeepsItsContentInPlace() {
        let source = NSRect(x: -200, y: 400, width: 600, height: 300)
        let result = frame(NSSize(width: 696, height: 424), source: source, contentOrigin: NSPoint(x: 48, y: 48))
        XCTAssertEqual(result, NSRect(x: -248, y: 352, width: 696, height: 424))
    }

    func testImageLargerThanTheCapIsScaledToFit() {
        let result = frame(NSSize(width: 1600, height: 1000), source: main)
        XCTAssertEqual(result.width / result.height, 1.6, accuracy: 0.001)
        XCTAssertEqual(result.width, main.width * 0.8, accuracy: 0.001)
        assertOnScreen(result, main)
    }

    func testSourceOnADisconnectedDisplayFallsBackToCenter() {
        let size = NSSize(width: 300, height: 200)
        XCTAssertEqual(frame(size, source: NSRect(x: 5000, y: 5000, width: 300, height: 200)), centered(size))
    }

    // MARK: - Overlay source rect

    /// The pin's frame is the snapped selection, so it must be exactly the
    /// region the capture rendered, on Retina and 1x displays alike.
    func testSnappedSelectionMatchesTheCapturedImage() throws {
        for scale in [1, 2] {
            let view = OverlayView()
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            let pixels = ImageProbe.quadrantImage(width: 400 * scale, height: 300 * scale)
            let cg = try XCTUnwrap(pixels.cgImage(forProposedRect: nil, context: nil, hints: nil))
            view.screenshotImage = NSImage(cgImage: cg, size: NSSize(width: 400, height: 300))
            view.applySelection(NSRect(x: 10.3, y: 20.7, width: 100.45, height: 50.2))

            let snapped = view.pixelSnappedSelectionRect
            let captured = try XCTUnwrap(view.captureSelectedRegion())
            let capturedCG = try XCTUnwrap(captured.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(captured.size, snapped.size, "\(scale)x")
            XCTAssertEqual(CGFloat(capturedCG.width), snapped.width * CGFloat(scale), "\(scale)x")
            XCTAssertEqual(CGFloat(capturedCG.height), snapped.height * CGFloat(scale), "\(scale)x")
            for value in [snapped.minX, snapped.minY, snapped.width, snapped.height] {
                XCTAssertEqual(value * CGFloat(scale), (value * CGFloat(scale)).rounded(), "\(scale)x: \(snapped)")
            }
        }
    }

    // MARK: - Preference

    func testPreferenceDefaultsToScreenCenter() {
        withDefaults([PinPlacement.userDefaultsKey: nil]) {
            XCTAssertEqual(PinPlacement.current, .screenCenter)
        }
        withDefaults([PinPlacement.userDefaultsKey: 7]) {
            XCTAssertEqual(PinPlacement.current, .screenCenter)
        }
        withDefaults([PinPlacement.userDefaultsKey: PinPlacement.captureLocation.rawValue]) {
            XCTAssertEqual(PinPlacement.current, .captureLocation)
        }
    }
}
