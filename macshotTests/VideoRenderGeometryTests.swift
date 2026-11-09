import CoreGraphics
import XCTest

final class VideoRenderGeometryTests: XCTestCase {
    func testOrientationLayoutNormalizesBoundsAndRejectsInvalidMetadata() throws {
        let size = CGSize(width: 80, height: 48)
        for transform in [CGAffineTransform(rotationAngle: .pi / 4),
                          CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: -100, ty: 200)] {
            let target = CGSize(width: 40, height: 24)
            let layout = try XCTUnwrap(VideoRenderGeometry.layout(sourceSize: size,
                preferredTransform: transform, renderSize: target))
            for matrix in [layout.layerTransform, layout.coreImageTransform] {
                let bounds = CGRect(origin: .zero, size: size).applying(matrix)
                XCTAssertEqual(bounds.minX, 0, accuracy: 0.000001)
                XCTAssertEqual(bounds.minY, 0, accuracy: 0.000001)
                XCTAssertEqual(bounds.width, target.width, accuracy: 0.000001)
                XCTAssertEqual(bounds.height, target.height, accuracy: 0.000001)
            }
        }
        for width: CGFloat in [.nan, .infinity, -1, 0] {
            XCTAssertNil(VideoRenderGeometry.layout(sourceSize: CGSize(width: width, height: 48),
                                                      preferredTransform: .identity))
        }
        XCTAssertNil(VideoRenderGeometry.layout(sourceSize: size,
            preferredTransform: CGAffineTransform(scaleX: 0, y: 1)))
        XCTAssertNil(VideoRenderGeometry.layout(sourceSize: size,
            preferredTransform: CGAffineTransform(translationX: .infinity, y: 0)))
        XCTAssertNil(VideoRenderGeometry.layout(sourceSize: size, preferredTransform: .identity,
                                                renderSize: CGSize(width: CGFloat.infinity, height: 1)))
    }

    func testSelectedZoomRegionFillsTheOutputAtEveryCornerAndScale() {
        let source = CGSize(width: 1920, height: 1080)
        for output in [source, CGSize(width: 960, height: 540), CGSize(width: 540, height: 960)] {
            for zoom: CGFloat in [1.2, 2, 5] {
                for point in [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1),
                              CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5)] {
                    let center = VideoZoomSegment.clampedCenter(point, zoom: zoom)
                    let segment = VideoZoomSegment(startTime: 0, endTime: 4, zoomLevel: zoom,
                                                   center: center, fadeIn: 0, fadeOut: 0)
                    let selected = CGRect(x: center.x - 0.5 / zoom, y: center.y - 0.5 / zoom,
                                          width: 1 / zoom, height: 1 / zoom)
                    let rendered = VideoRenderGeometry.overlayRect(selected, naturalSize: source,
                        renderSize: output, zoom: zoom, translation: segment.translation(zoom: zoom, videoSize: source))
                    XCTAssertEqual(rendered.minX, 0, accuracy: 0.00001)
                    XCTAssertEqual(rendered.minY, 0, accuracy: 0.00001)
                    XCTAssertEqual(rendered.width, output.width, accuracy: 0.00001)
                    XCTAssertEqual(rendered.height, output.height, accuracy: 0.00001)
                }
            }
        }
    }

    func testZoomFadesNeverExposeBlackEdges() {
        let size = CGSize(width: 960, height: 540)
        let output = CGRect(origin: .zero, size: size)
        for center in [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.75, y: 0.75)] {
            let segment = VideoZoomSegment(startTime: 0, endTime: 4, zoomLevel: 2, center: center)
            for time in stride(from: 0.0, through: 4.0, by: 0.01) {
                let zoom = segment.zoomLevel(at: time)
                let transform = VideoRenderGeometry.zoomTransform(zoom: zoom,
                    translation: segment.translation(zoom: zoom, videoSize: size), naturalSize: size, renderSize: size)
                XCTAssertTrue(output.applying(transform).insetBy(dx: -0.0001, dy: -0.0001).contains(output))
            }
        }
    }

    func testCensorAndTextRectsFollowTheSameTransformAsTheImage() {
        let size = CGSize(width: 960, height: 540)
        let output = CGSize(width: 480, height: 270)
        let segment = VideoZoomSegment(startTime: 0, endTime: 4, center: CGPoint(x: 0.3, y: 0.7))
        let rect = CGRect(x: 0.25, y: 0.65, width: 0.1, height: 0.1)
        let translation = segment.translation(zoom: 2, videoSize: size)
        let imageTransform = VideoRenderGeometry.zoomTransform(zoom: 2, translation: translation,
                                                               naturalSize: size, renderSize: output)
        let contentPoint = CGPoint(x: rect.midX * output.width, y: (1 - rect.midY) * output.height)
            .applying(imageTransform)
        let overlay = VideoRenderGeometry.overlayRect(rect, naturalSize: size, renderSize: output,
                                                       zoom: 2, translation: translation)
        XCTAssertEqual(overlay.midX, contentPoint.x, accuracy: 0.00001)
        XCTAssertEqual(overlay.midY, contentPoint.y, accuracy: 0.00001)
        XCTAssertEqual(overlay.width, rect.width * output.width * 2, accuracy: 0.00001)
    }
}
