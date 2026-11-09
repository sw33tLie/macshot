import Cocoa
import XCTest

final class WebcamPlacementTests: XCTestCase {
    func testResizeDoesNotJumpWhenGrabbingInsideTheBubble() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 500)
        for corner in [WebcamPosition.bottomLeft, .bottomRight, .topLeft, .topRight] {
            let frame = WebcamPlacement.cornerFrame(corner, size: 120, in: bounds)
            let direction = WebcamPlacement.handleDirection(for: frame, in: bounds)
            let mouse = NSPoint(x: frame.midX + 120 * 0.31 * direction.dx,
                                y: frame.midY + 120 * 0.31 * direction.dy)
            let gesture = WebcamPlacement.ResizeGesture(frame: frame, mouse: mouse, bounds: bounds)
            XCTAssertEqual(gesture.frame(at: mouse, in: bounds), frame)
            let moved = NSPoint(x: mouse.x + 20 * direction.dx, y: mouse.y + 20 * direction.dy)
            let resized = gesture.frame(at: moved, in: bounds)
            XCTAssertEqual(resized.width, 140, accuracy: 0.001)
            XCTAssertEqual(direction.dx > 0 ? resized.minX : resized.maxX, gesture.anchor.x)
            XCTAssertEqual(direction.dy > 0 ? resized.minY : resized.maxY, gesture.anchor.y)
        }
    }

    func testResizeAtAnEdgeKeepsTheOppositeCornerFixed() {
        let bounds = NSRect(x: 100, y: 200, width: 500, height: 300)
        let frame = NSRect(x: 250, y: 300, width: 120, height: 120)
        let mouse = NSPoint(x: 347.2, y: 322.8)
        let gesture = WebcamPlacement.ResizeGesture(frame: frame, mouse: mouse, bounds: bounds)
        let result = gesture.frame(at: NSPoint(x: 2000, y: -2000), in: bounds)
        XCTAssertEqual(result.minX, gesture.anchor.x)
        XCTAssertEqual(result.maxY, gesture.anchor.y)
        XCTAssertTrue(bounds.insetBy(dx: 12, dy: 12).contains(result))
    }
}
