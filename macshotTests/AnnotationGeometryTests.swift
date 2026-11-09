import Cocoa
import XCTest

/// Geometry that decides what the user can click, drag and select. These run
/// without a window: `boundingRect`, `hitTest` and `move` are pure functions of
/// the annotation's own state.
final class AnnotationGeometryTests: XCTestCase {

    private func make(
        _ tool: AnnotationTool,
        from start: NSPoint = NSPoint(x: 20, y: 30),
        to end: NSPoint = NSPoint(x: 120, y: 90),
        strokeWidth: CGFloat = 4
    ) -> Annotation {
        Annotation(tool: tool, startPoint: start, endPoint: end, color: .red, strokeWidth: strokeWidth)
    }

    // MARK: - boundingRect

    func testBoundingRectIsNormalizedWhateverTheDragDirection() {
        let downLeft = make(.rectangle, from: NSPoint(x: 120, y: 90), to: NSPoint(x: 20, y: 30))
        XCTAssertEqual(downLeft.boundingRect, NSRect(x: 20, y: 30, width: 100, height: 60),
                       "dragging up-left must give the same box as dragging down-right")
    }

    func testBoundingRectCoversBendAndAnchorPoints() {
        let bent = make(.line)
        bent.controlPoint = NSPoint(x: 200, y: 400)
        // NSRect.contains excludes the far edges, so check the bounds directly:
        // the box has to reach the bend handle or it can't be grabbed.
        XCTAssertEqual(bent.boundingRect.maxX, 200)
        XCTAssertEqual(bent.boundingRect.maxY, 400)
        XCTAssertEqual(bent.boundingRect.origin, NSPoint(x: 20, y: 30))

        let multi = make(.arrow)
        multi.anchorPoints = [NSPoint(x: 20, y: 30), NSPoint(x: -50, y: 10), NSPoint(x: 120, y: 90)]
        XCTAssertEqual(multi.boundingRect.minX, -50)
    }

    func testNumberBoundingRectIsCenteredOnItsCircle() {
        let number = make(.number, from: NSPoint(x: 100, y: 100), to: NSPoint(x: 100, y: 100), strokeWidth: 4)
        let radius: CGFloat = 8 + 4 * 3
        XCTAssertEqual(number.boundingRect.midX, 100, accuracy: 0.001)
        XCTAssertEqual(number.boundingRect.midY, 100, accuracy: 0.001)
        XCTAssertEqual(number.boundingRect.width, radius * 2, accuracy: 0.001)
    }

    func testNumberBoundingRectGrowsToIncludeItsPointer() {
        let number = make(.number, from: NSPoint(x: 100, y: 100), to: NSPoint(x: 300, y: 100))
        XCTAssertGreaterThanOrEqual(number.boundingRect.maxX, 300)
    }

    func testZeroSizeAnnotationHasZeroSizeBox() {
        let dot = make(.rectangle, from: NSPoint(x: 5, y: 5), to: NSPoint(x: 5, y: 5))
        XCTAssertEqual(dot.boundingRect, NSRect(x: 5, y: 5, width: 0, height: 0))
    }

    // MARK: - hitTest

    func testFilledRectangleIsHitAnywhereInside() {
        let rect = make(.filledRectangle)
        XCTAssertTrue(rect.hitTest(point: NSPoint(x: 70, y: 60)))
        XCTAssertFalse(rect.hitTest(point: NSPoint(x: 300, y: 300)))
    }

    func testOutlinedRectangleIsHitOnItsEdgeButNotItsHollowMiddle() {
        let rect = make(.rectangle)
        rect.rectFillStyle = .stroke
        XCTAssertTrue(rect.hitTest(point: NSPoint(x: 20, y: 60)), "the left edge is part of the shape")
        XCTAssertFalse(rect.hitTest(point: NSPoint(x: 70, y: 60)), "the hollow middle must let clicks through to what's underneath")
    }

    func testFilledRectangleStyleMakesTheMiddleClickable() {
        let rect = make(.rectangle)
        rect.rectFillStyle = .fill
        XCTAssertTrue(rect.hitTest(point: NSPoint(x: 70, y: 60)))
    }

    func testLineIsHitNearItButNotFarFromIt() {
        let line = make(.line, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 100, y: 0))
        XCTAssertTrue(line.hitTest(point: NSPoint(x: 50, y: 3)))
        XCTAssertFalse(line.hitTest(point: NSPoint(x: 50, y: 40)))
        XCTAssertFalse(line.hitTest(point: NSPoint(x: 200, y: 0)), "past the end of the segment is a miss")
    }

    func testLineHitTestFollowsItsBend() {
        let line = make(.line, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 100, y: 0))
        line.controlPoint = NSPoint(x: 50, y: 100)
        // Drawn as a cubic with both control points on the bend handle, so the
        // curve's midpoint sits at 3/4 of the way to the handle — the hit test
        // samples the same formula.
        XCTAssertTrue(line.hitTest(point: NSPoint(x: 50, y: 74)),
                      "the curve bulges toward the control point, so the midpoint moves with it")
        XCTAssertFalse(line.hitTest(point: NSPoint(x: 50, y: 50)),
                       "halfway to the handle is not where the curve is drawn")
        XCTAssertFalse(line.hitTest(point: NSPoint(x: 50, y: 0)),
                       "the straight path is no longer where the line is drawn")
    }

    func testMultiAnchorArrowIsHitAlongEverySegment() {
        let arrow = make(.arrow, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 100, y: 100))
        arrow.anchorPoints = [NSPoint(x: 0, y: 0), NSPoint(x: 100, y: 0), NSPoint(x: 100, y: 100)]
        XCTAssertTrue(arrow.hitTest(point: NSPoint(x: 50, y: 1)), "first leg")
        XCTAssertTrue(arrow.hitTest(point: NSPoint(x: 99, y: 50)), "second leg")
        XCTAssertFalse(arrow.hitTest(point: NSPoint(x: 40, y: 60)), "inside the corner is not on the path")
    }

    func testPencilHitTestFollowsTheStroke() {
        let pencil = make(.pencil)
        pencil.points = [NSPoint(x: 0, y: 0), NSPoint(x: 10, y: 10), NSPoint(x: 20, y: 40)]
        XCTAssertTrue(pencil.hitTest(point: NSPoint(x: 10, y: 12)))
        XCTAssertFalse(pencil.hitTest(point: NSPoint(x: 100, y: 100)))
    }

    func testPencilWithNoPointsIsNeverHit() {
        XCTAssertFalse(make(.pencil).hitTest(point: NSPoint(x: 20, y: 30)))
    }

    func testMarkerHasAWiderHitAreaThanAPencil() {
        let stroke = [NSPoint(x: 0, y: 0), NSPoint(x: 100, y: 0)]
        let pencil = make(.pencil, strokeWidth: 6)
        pencil.points = stroke
        let marker = make(.marker, strokeWidth: 6)
        marker.points = stroke
        let offEdge = NSPoint(x: 0, y: 15)
        XCTAssertFalse(pencil.hitTest(point: offEdge))
        XCTAssertTrue(marker.hitTest(point: offEdge), "the highlighter draws ~6x wider, so it must hit test wider")
    }

    func testEllipseIsHitOnItsRimAndMissesTheCorners() {
        let ellipse = make(.ellipse, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 200, y: 100))
        XCTAssertTrue(ellipse.hitTest(point: NSPoint(x: 100, y: 100)), "top of the rim")
        XCTAssertFalse(ellipse.hitTest(point: NSPoint(x: 2, y: 98)), "the box corner is outside the ellipse")
        XCTAssertFalse(ellipse.hitTest(point: NSPoint(x: 100, y: 50)), "an outlined ellipse is hollow")
    }

    func testFilledEllipseIsHitInTheMiddle() {
        let ellipse = make(.ellipse, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 200, y: 100))
        ellipse.rectFillStyle = .fill
        XCTAssertTrue(ellipse.hitTest(point: NSPoint(x: 100, y: 50)))
    }

    func testDegenerateEllipseIsNotHit() {
        let flat = make(.ellipse, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 0, y: 0))
        XCTAssertFalse(flat.hitTest(point: .zero), "a zero-size ellipse must not divide by zero or claim the click")
    }

    func testTextIsHitInsideItsBox() {
        let text = make(.text)
        text.textDrawRect = NSRect(x: 10, y: 10, width: 100, height: 40)
        XCTAssertTrue(text.hitTest(point: NSPoint(x: 50, y: 30)))
        XCTAssertFalse(text.hitTest(point: NSPoint(x: 200, y: 30)))
    }

    func testNumberIsHitOnItsCircleAndOnItsPointer() {
        let number = make(.number, from: NSPoint(x: 100, y: 100), to: NSPoint(x: 300, y: 100))
        XCTAssertTrue(number.hitTest(point: NSPoint(x: 100, y: 100)), "the badge itself")
        XCTAssertTrue(number.hitTest(point: NSPoint(x: 250, y: 100)), "the pointer line")
        XCTAssertFalse(number.hitTest(point: NSPoint(x: 250, y: 200)))
    }

    func testRootedLoupeIsHitOnBothItsCircles() {
        let loupe = make(.loupe, from: NSPoint(x: 0, y: 0), to: NSPoint(x: 100, y: 100))
        loupe.loupeSourceRect = NSRect(x: 300, y: 300, width: 40, height: 40)
        XCTAssertTrue(loupe.hitTest(point: NSPoint(x: 50, y: 50)), "the lens")
        XCTAssertTrue(loupe.hitTest(point: NSPoint(x: 320, y: 320)), "the rooted source spot")
        XCTAssertFalse(loupe.hitTest(point: NSPoint(x: 200, y: 200)))
    }

    func testRotatedRectangleHitTestsInItsRotatedFrame() {
        let rect = make(.rectangle, from: NSPoint(x: 0, y: 40), to: NSPoint(x: 200, y: 60))
        rect.rectFillStyle = .fill
        rect.rotation = .pi / 2  // now a tall thin bar through the same center
        XCTAssertTrue(rect.hitTest(point: NSPoint(x: 100, y: 140)), "the rotated shape now covers this point")
        XCTAssertFalse(rect.hitTest(point: NSPoint(x: 190, y: 50)), "…and no longer covers its old right edge")
    }

    func testSelectAndTranslateAreNotHitTestable() {
        XCTAssertFalse(make(.select).hitTest(point: NSPoint(x: 50, y: 50)))
        XCTAssertFalse(make(.translateOverlay).hitTest(point: NSPoint(x: 50, y: 50)))
    }

    func testOnlyRealAnnotationsAreMovable() {
        XCTAssertFalse(make(.select).isMovable)
        XCTAssertFalse(make(.translateOverlay).isMovable)
        for tool in AnnotationTool.allCases where tool != .select && tool != .translateOverlay {
            XCTAssertTrue(make(tool).isMovable, "\(tool) should be draggable")
        }
    }

    // MARK: - move

    func testMoveShiftsEveryPieceOfGeometryTogether() {
        let ann = make(.pencil)
        ann.points = [NSPoint(x: 0, y: 0), NSPoint(x: 10, y: 10)]
        ann.controlPoint = NSPoint(x: 5, y: 5)
        ann.anchorPoints = [NSPoint(x: 1, y: 1), NSPoint(x: 2, y: 2)]
        ann.textDrawRect = NSRect(x: 3, y: 3, width: 20, height: 10)

        ann.move(dx: 7, dy: -4)

        XCTAssertEqual(ann.startPoint, NSPoint(x: 27, y: 26))
        XCTAssertEqual(ann.endPoint, NSPoint(x: 127, y: 86))
        XCTAssertEqual(ann.points?[1], NSPoint(x: 17, y: 6))
        XCTAssertEqual(ann.controlPoint, NSPoint(x: 12, y: 1))
        XCTAssertEqual(ann.anchorPoints?[0], NSPoint(x: 8, y: -3))
        XCTAssertEqual(ann.textDrawRect.origin, NSPoint(x: 10, y: -1))
    }

    func testMoveKeepsTheBoxTheSameSize() {
        let ann = make(.rectangle)
        let before = ann.boundingRect
        ann.move(dx: 100, dy: 200)
        let after = ann.boundingRect
        XCTAssertEqual(after.size, before.size)
        XCTAssertEqual(after.origin, NSPoint(x: before.origin.x + 100, y: before.origin.y + 200))
    }

    func testMoveIsReversible() {
        let ann = make(.arrow)
        ann.points = [NSPoint(x: 1, y: 2)]
        let before = Reflect.describedProperties(of: ann)
        ann.move(dx: 33.5, dy: -12.25)
        ann.move(dx: -33.5, dy: 12.25)
        XCTAssertEqual(Reflect.describedProperties(of: ann), before)
    }

    func testMoveLeavesTheRootedLoupeSourceInPlace() {
        let loupe = make(.loupe)
        loupe.loupeSourceRect = NSRect(x: 300, y: 300, width: 40, height: 40)
        loupe.move(dx: 50, dy: 50)
        XCTAssertEqual(loupe.loupeSourceRect, NSRect(x: 300, y: 300, width: 40, height: 40),
                       "dragging the lens must leave the magnified spot where it is (#197)")
    }

    func testMoveKeepsHitTestingConsistent() {
        let rect = make(.filledRectangle)
        XCTAssertTrue(rect.hitTest(point: NSPoint(x: 70, y: 60)))
        rect.move(dx: 500, dy: 0)
        XCTAssertFalse(rect.hitTest(point: NSPoint(x: 70, y: 60)))
        XCTAssertTrue(rect.hitTest(point: NSPoint(x: 570, y: 60)))
    }

    // MARK: - waypoints

    func testWaypointsFallBackToTheEndpoints() {
        let line = make(.line)
        XCTAssertEqual(line.waypoints, [line.startPoint, line.endPoint])
        XCTAssertFalse(line.hasMultiAnchor)
    }

    func testTwoAnchorsAreNotAMultiAnchorPath() {
        let line = make(.line)
        line.anchorPoints = [NSPoint(x: 0, y: 0), NSPoint(x: 1, y: 1)]
        XCTAssertFalse(line.hasMultiAnchor, "a start and an end is just a straight line")
        XCTAssertEqual(line.waypoints.count, 2)
    }

    func testThreeAnchorsMakeAMultiAnchorPath() {
        let line = make(.line)
        line.anchorPoints = [NSPoint(x: 0, y: 0), NSPoint(x: 1, y: 1), NSPoint(x: 2, y: 0)]
        XCTAssertTrue(line.hasMultiAnchor)
        XCTAssertEqual(line.waypoints.count, 3)
    }

    // MARK: - Rotation support

    func testOnlyShapesWithAFrameSupportRotation() {
        for tool in [AnnotationTool.rectangle, .filledRectangle, .ellipse, .stamp, .text, .number] {
            XCTAssertTrue(make(tool).supportsRotation, "\(tool) has a frame and should rotate")
        }
        for tool in [AnnotationTool.pencil, .line, .arrow, .marker, .measure, .loupe, .blur] {
            XCTAssertFalse(make(tool).supportsRotation, "\(tool) is defined by its path, not a frame")
        }
    }
}
