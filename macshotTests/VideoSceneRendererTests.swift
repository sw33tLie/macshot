import CoreImage
import XCTest

final class VideoSceneRendererTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private let contentSize = CGSize(width: 400, height: 200)

    /// Red frame with a blue square in its top-left corner.
    private var content: CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: contentSize))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 150, width: 50, height: 50))
        return blue.composited(over: red)
    }

    private func layout(padding: Double = 0.1, radius: Double = 0, enabled: Bool = true) -> VideoSceneLayout {
        var frame = VideoFrameStyle()
        frame.enabled = enabled
        frame.padding = padding
        frame.cornerRadius = radius
        return VideoSceneGeometry.layout(contentSize: contentSize, crop: CGRect(x: 0, y: 0, width: 1, height: 1),
                                         frame: frame)!
    }

    private func scene(_ layout: VideoSceneLayout, camera: CameraPath = .empty,
                       cursor: VideoCursorLayer? = nil) -> VideoSceneSnapshot {
        let background = layout.drawsBackground
            ? CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(origin: .zero, size: layout.canvasSize))
            : nil
        return VideoSceneSnapshot(layout: layout, background: background, foreground: nil, camera: camera,
                                  cameraMotionBlur: 0, cursor: cursor, keystrokes: [], keystrokeStyle: VideoKeystrokeStyle(),
                                  captions: [], captionStyle: VideoCaptionStyle(), webcam: nil)
    }

    /// RGBA bytes at a top-left pixel coordinate.
    private func pixel(_ image: CIImage, _ x: Int, _ yTop: Int) -> [UInt8] {
        let extent = image.extent
        var bytes = [UInt8](repeating: 0, count: 4)
        let y = Int(extent.height) - 1 - yTop
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    private func assertColor(_ rgba: [UInt8], _ r: UInt8, _ g: UInt8, _ b: UInt8,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Int(rgba[0]), Int(r), accuracy: 12, "red", file: file, line: line)
        XCTAssertEqual(Int(rgba[1]), Int(g), accuracy: 12, "green", file: file, line: line)
        XCTAssertEqual(Int(rgba[2]), Int(b), accuracy: 12, "blue", file: file, line: line)
    }

    func testFramePlacesRecordingOverBackground() {
        let layout = layout()
        let image = VideoSceneRenderer.render(content: content, time: 0, scene: scene(layout), censors: [], texts: [])
        XCTAssertEqual(image.extent.size, layout.canvasSize)
        assertColor(pixel(image, 2, 2), 0, 255, 0)
        assertColor(pixel(image, Int(layout.videoRect.midX), Int(layout.videoRect.midY)), 255, 0, 0)
        // Top-left of the recording is the blue marker (orientation preserved).
        assertColor(pixel(image, Int(layout.videoRect.minX) + 5, Int(layout.videoRect.minY) + 5), 0, 0, 255)
    }

    func testRoundedCornersRevealTheBackground() {
        let layout = layout(radius: 400)
        XCTAssertGreaterThan(layout.cornerRadius, 20)
        let image = VideoSceneRenderer.render(content: content, time: 0, scene: scene(layout), censors: [], texts: [])
        assertColor(pixel(image, Int(layout.videoRect.maxX) - 1, Int(layout.videoRect.maxY) - 1), 0, 255, 0)
        assertColor(pixel(image, Int(layout.videoRect.midX), Int(layout.videoRect.maxY) - 2), 255, 0, 0)
    }

    func testCameraZoomFillsTheOutputWithTheRecording() {
        let layout = layout(padding: 0.05)
        let path = CameraPathBuilder.build(zooms: [.init(start: 0, end: 10, level: 3, center: CGPoint(x: 0.5, y: 0.5),
                                                         follows: false, rampIn: 0, rampOut: 0)],
                                           layout: layout, cursor: nil, connect: false)
        let image = VideoSceneRenderer.render(content: content, time: 5, scene: scene(layout, camera: path),
                                              censors: [], texts: [])
        for (x, y) in [(1, 1), (Int(layout.canvasSize.width) - 2, Int(layout.canvasSize.height) - 2)] {
            assertColor(pixel(image, x, y), 255, 0, 0)
        }
    }

    func testCameraMotionBlurPreservesBrightness() {
        let layout = layout(enabled: false)
        let solid = CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: contentSize))
        // Two zooms far apart: the connected pan between them moves fast.
        let path = CameraPathBuilder.build(zooms: [
            .init(start: 0, end: 1, level: 3, center: CGPoint(x: 0.1, y: 0.1), follows: false, rampIn: 0, rampOut: 0),
            .init(start: 1.1, end: 3, level: 3, center: CGPoint(x: 0.9, y: 0.9), follows: false, rampIn: 0, rampOut: 0),
        ], layout: layout, cursor: nil, connect: true)
        let snapshot = VideoSceneSnapshot(layout: layout, background: nil, foreground: nil, camera: path,
                                          cameraMotionBlur: 1, cursor: nil, keystrokes: [], keystrokeStyle: VideoKeystrokeStyle(),
                                          captions: [], captionStyle: VideoCaptionStyle(), webcam: nil)
        let image = VideoSceneRenderer.render(content: solid, time: 1.2, scene: snapshot, censors: [], texts: [])
        assertColor(pixel(image, 200, 100), 204, 102, 51)
    }

    func testCensorObscuresContentAnchoredRect() throws {
        let layout = layout(enabled: false)
        let segment = VideoCensorSegment(startTime: 0, endTime: 5, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                                         style: .solid)
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout),
                                              censors: [VideoCensorSnapshot(segment)], texts: [])
        assertColor(pixel(image, 300, 100), 0, 0, 0)
        assertColor(pixel(image, 100, 100), 255, 0, 0)
    }

    func testCursorIsDrawnAtItsHotspotAndHonorsVisibility() {
        let layout = layout(enabled: false)
        let white = CIImage(color: CIColor.white).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 40))
        let sprite = CursorSprite(image: white, hotspot: .zero, size: CGSize(width: 10, height: 10))
        let header = CursorTelemetry.Header(sourcePointSize: contentSize, pixelSize: contentSize, frameRate: 30,
                                            cursorHiddenInVideo: true, overlaysInTelemetry: true)
        let recording = CursorRecording(header: header, events: [.start(time: 0), .move(time: 0, x: 0.5, y: 0.5)])
        let track = CursorMotion.buildTrack(from: recording, smoothing: 0)
        var style = VideoCursorStyle()
        style.size = 1
        style.motionBlur = 0
        style.pressBounce = false
        style.clickEffect = .none
        func cursorLayer(_ style: VideoCursorStyle) -> VideoCursorLayer {
            VideoCursorLayer(track: track, shapeTimes: [], shapeIDs: [], sprites: [:], fallback: sprite, style: style,
                             pixelsPerPoint: 1, clicks: [], keyTimes: [], rippleSprite: white, ringSprite: white,
                             loopRange: nil)
        }
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout, cursor: cursorLayer(style)),
                                              censors: [], texts: [])
        assertColor(pixel(image, 204, 104), 255, 255, 255)
        assertColor(pixel(image, 196, 96), 255, 0, 0)
        assertColor(pixel(image, 215, 104), 255, 0, 0)
        style.show = false
        let hidden = VideoSceneRenderer.render(content: content, time: 1, scene: scene(layout, cursor: cursorLayer(style)),
                                               censors: [], texts: [])
        assertColor(pixel(hidden, 204, 104), 255, 0, 0)
    }

    func testKeystrokeLabelRendersOnScreen() {
        let layout = layout(enabled: false)
        let snapshot = VideoSceneSnapshot(layout: layout, background: nil, foreground: nil, camera: .empty,
                                          cameraMotionBlur: 0, cursor: nil,
                                          keystrokes: [.init(start: 0, end: 5, text: "⌘ C")],
                                          keystrokeStyle: VideoKeystrokeStyle(), captions: [],
                                          captionStyle: VideoCaptionStyle(), webcam: nil)
        let image = VideoSceneRenderer.render(content: content, time: 1, scene: snapshot, censors: [], texts: [])
        // The pill darkens the bottom center of the red frame.
        let bottom = pixel(image, 200, Int(layout.canvasSize.height) - 16)
        XCTAssertLessThan(Int(bottom[0]), 200)
    }

    func testTextCacheReturnsSameImageForSameLabel() {
        let cache = OverlayTextCache()
        let a = cache.pill(text: "⌘ ⇧ 4", fontSize: 30, maxWidth: 800, light: false, weight: .semibold)
        let b = cache.pill(text: "⌘ ⇧ 4", fontSize: 30, maxWidth: 800, light: false, weight: .semibold)
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b)
        XCTAssertNotNil(cache.caption(text: "A caption that is long enough to wrap onto more than one line",
                                      fontSize: 40, maxWidth: 300, background: true))
    }
}

final class VideoIconButtonLayoutTests: XCTestCase {
    /// Highlights fill `bounds`; if the frame outgrows the constrained size,
    /// neighbouring rail buttons' hover and selection fills overlap.
    func testIconButtonFrameMatchesItsConstrainedSize() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        var buttons: [VideoIconButton] = []
        for symbol in ["photo.on.rectangle", "cursorarrow.rays", "plus.magnifyingglass"] {
            let button = VideoIconButton(symbol: symbol, size: 16, tooltip: symbol, target: nil, action: nil)
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 60, height: 300)
        stack.layoutSubtreeIfNeeded()
        for button in buttons { XCTAssertEqual(button.frame.size, NSSize(width: 38, height: 38)) }
        for (upper, lower) in zip(buttons, buttons.dropFirst()) {
            XCTAssertEqual(abs(upper.frame.minY - lower.frame.maxY), 6, accuracy: 0.01, "highlights must not touch")
        }
    }
}
