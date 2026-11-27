import XCTest

/// Move area: the pixels cut from `moveSourceRect` are drawn at the
/// annotation's rect, and the hole they leave is filled from its surroundings.
final class MoveAreaTests: XCTestCase {

    private let canvas = NSRect(x: 0, y: 0, width: 100, height: 60)

    /// White canvas with a red 10x10 square at (10, 20) in AppKit coordinates.
    private func screenshot() -> NSImage {
        ImageProbe.makeImage(width: 100, height: 60) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 10, y: 20, width: 10, height: 10))
        }
    }

    private func moveArea(over rect: NSRect, image: NSImage) -> Annotation {
        let ann = Annotation(tool: .moveArea, startPoint: rect.origin,
                             endPoint: NSPoint(x: rect.maxX, y: rect.maxY),
                             color: .red, strokeWidth: 2)
        ann.sourceImage = image
        ann.sourceImageBounds = canvas
        ann.moveSourceRect = rect
        ann.bakeMoveArea()
        return ann
    }

    /// Screenshot with the annotation on top, as the editor renders it.
    private func render(_ image: NSImage, _ ann: Annotation) -> NSImage {
        ImageProbe.makeImage(width: 100, height: 60) { ctx in
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = ns
            image.draw(in: canvas, from: .zero, operation: .copy, fraction: 1)
            ann.draw(in: ns)
            NSGraphicsContext.current = previous
        }
    }

    /// `y` is AppKit's (from the bottom); the probe counts from the top.
    private func isRed(_ image: NSImage, x: Int, y: Int, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let c = ImageProbe.pixelColor(image, x: x, y: 59 - y) else {
            XCTFail("no pixel", file: file, line: line); return false
        }
        return c.redComponent > 0.9 && c.greenComponent < 0.1 && c.blueComponent < 0.1
    }

    private func isWhite(_ image: NSImage, x: Int, y: Int) -> Bool {
        guard let c = ImageProbe.pixelColor(image, x: x, y: 59 - y) else { return false }
        return c.redComponent > 0.9 && c.greenComponent > 0.9 && c.blueComponent > 0.9
    }

    func testBakeCutsPixelsAndFillsHole() {
        let ann = moveArea(over: NSRect(x: 5, y: 15, width: 20, height: 20), image: screenshot())
        XCTAssertNotNil(ann.stampImage, "the moved pixels")
        XCTAssertNotNil(ann.bakedBlurNSImage, "the filled hole")
    }

    func testInPlaceLooksUnchanged() {
        let image = screenshot()
        let ann = moveArea(over: NSRect(x: 5, y: 15, width: 20, height: 20), image: image)
        let out = render(image, ann)
        XCTAssertTrue(isRed(out, x: 15, y: 25))
        XCTAssertTrue(isWhite(out, x: 7, y: 17))
    }

    func testDraggingMovesPixelsAndLeavesFilledHole() {
        let image = screenshot()
        let ann = moveArea(over: NSRect(x: 5, y: 15, width: 20, height: 20), image: image)
        ann.move(dx: 50, dy: 0)

        XCTAssertEqual(ann.moveSourceRect, NSRect(x: 5, y: 15, width: 20, height: 20),
                       "dragging moves the pixels, not the hole")
        let out = render(image, ann)
        XCTAssertTrue(isRed(out, x: 65, y: 25), "pixels at their new place")
        XCTAssertTrue(isWhite(out, x: 15, y: 25), "hole filled with the white around it")
    }

    func testSurvivesCodableRoundTrip() throws {
        let image = screenshot()
        let ann = moveArea(over: NSRect(x: 5, y: 15, width: 20, height: 20), image: image)
        ann.move(dx: 50, dy: 0)

        let data = try JSONEncoder().encode([ann.toCodable()])
        let decoded = try JSONDecoder().decode([CodableAnnotation].self, from: data)
        let restored = try XCTUnwrap(Annotation.fromCodable(decoded[0]))

        XCTAssertEqual(restored.tool, .moveArea)
        XCTAssertEqual(restored.moveSourceRect, ann.moveSourceRect)
        let out = render(image, restored)
        XCTAssertTrue(isRed(out, x: 65, y: 25))
        XCTAssertTrue(isWhite(out, x: 15, y: 25))
    }

    func testRendersUnderShapes() {
        let ann = moveArea(over: NSRect(x: 5, y: 15, width: 20, height: 20), image: screenshot())
        XCTAssertTrue(ann.rendersInImageLayer)
        let arrow = Annotation(tool: .arrow, startPoint: .zero, endPoint: NSPoint(x: 1, y: 1),
                               color: .red, strokeWidth: 2)
        XCTAssertFalse(arrow.rendersInImageLayer)
    }
}
