import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

// MARK: - Render inputs (immutable, shared with background render queues)

/// A cursor image and where its hotspot is. Images are high resolution; the
/// renderer scales them to the exact output size so zoomed exports stay sharp.
nonisolated struct CursorSprite: @unchecked Sendable {
    /// Extent starts at the origin; bottom-left coordinates.
    let image: CIImage
    /// Hotspot in points from the top-left corner.
    let hotspot: CGPoint
    /// Logical size in points.
    let size: CGSize
}

nonisolated final class VideoCursorLayer: @unchecked Sendable {
    let track: CursorTrack
    let shapeTimes: [Double]
    let shapeIDs: [UInt32]
    let sprites: [UInt32: CursorSprite]
    let fallback: CursorSprite
    let style: VideoCursorStyle
    /// Source-video pixels per cursor point.
    let pixelsPerPoint: CGFloat
    let clicks: [CursorRecording.Click]
    let keyTimes: [Double]
    let rippleSprite: CIImage
    let ringSprite: CIImage
    /// Source-time range whose end glides back to its start (loop mode).
    let loopRange: ClosedRange<Double>?

    init(track: CursorTrack, shapeTimes: [Double], shapeIDs: [UInt32], sprites: [UInt32: CursorSprite],
         fallback: CursorSprite, style: VideoCursorStyle, pixelsPerPoint: CGFloat, clicks: [CursorRecording.Click],
         keyTimes: [Double], rippleSprite: CIImage, ringSprite: CIImage, loopRange: ClosedRange<Double>?) {
        self.track = track
        self.shapeTimes = shapeTimes
        self.shapeIDs = shapeIDs
        self.sprites = sprites
        self.fallback = fallback
        self.style = style
        self.pixelsPerPoint = pixelsPerPoint
        self.clicks = clicks
        self.keyTimes = keyTimes
        self.rippleSprite = rippleSprite
        self.ringSprite = ringSprite
        self.loopRange = loopRange
    }

    func sprite(at t: Double) -> CursorSprite {
        guard style.appearance == .system else { return fallback }
        guard let i = CursorRecording.index(in: shapeTimes, atOrBefore: t) else {
            return shapeIDs.first.flatMap { sprites[$0] } ?? fallback
        }
        return sprites[shapeIDs[i]] ?? fallback
    }

    /// Pointer position (normalized content) including the loop glide.
    func position(at t: Double) -> CGPoint? {
        guard var p = track.position(at: t) else { return nil }
        if let range = loopRange, let home = track.position(at: range.lowerBound) {
            let glide = min(0.9, (range.upperBound - range.lowerBound) / 3)
            let from = range.upperBound - glide
            if t > from {
                let w = CGFloat(CameraPathBuilder.smootherstep((t - from) / glide))
                p = CGPoint(x: p.x + (home.x - p.x) * w, y: p.y + (home.y - p.y) * w)
            }
        }
        return p
    }

    func opacity(at t: Double) -> CGFloat {
        var alpha: CGFloat = 1
        if style.hideWhenIdle { alpha = min(alpha, track.idleOpacity(at: t, delay: style.idleDelay)) }
        if style.hideWhileTyping { alpha = min(alpha, CursorMotion.typingOpacity(at: t, keyTimes: keyTimes, track: track)) }
        return alpha
    }
}

/// A second camera video (webcam) composited as a bubble.
nonisolated final class VideoWebcamLayer: @unchecked Sendable {
    let trackID: Int32
    let style: VideoCameraStyle
    /// Upright transform for the camera track's natural image.
    let uprightTransform: CGAffineTransform
    let uprightSize: CGSize
    /// Where the bubble sat while recording; used when the style follows it.
    let placement: CameraPlacementTrack?

    init(trackID: Int32, style: VideoCameraStyle, uprightTransform: CGAffineTransform, uprightSize: CGSize,
         placement: CameraPlacementTrack? = nil) {
        self.trackID = trackID
        self.style = style
        self.uprightTransform = uprightTransform
        self.uprightSize = uprightSize
        self.placement = placement
    }
}

/// Everything the compositor needs to draw the framed, camera-driven scene.
nonisolated final class VideoSceneSnapshot: @unchecked Sendable {
    let layout: VideoSceneLayout
    /// Static canvas-sized background + shadow (bottom-left coordinates).
    let background: CIImage?
    /// Static decorations drawn over the recording (border).
    let foreground: CIImage?
    let camera: CameraPath
    let cameraMotionBlur: CGFloat
    let cursor: VideoCursorLayer?
    let keystrokes: [KeystrokeTimeline.Label]
    let keystrokeStyle: VideoKeystrokeStyle
    let captions: [VideoCaptionSegment]
    let captionStyle: VideoCaptionStyle
    let webcam: VideoWebcamLayer?
    let textCache = OverlayTextCache()

    init(layout: VideoSceneLayout, background: CIImage?, foreground: CIImage?, camera: CameraPath,
         cameraMotionBlur: CGFloat, cursor: VideoCursorLayer?, keystrokes: [KeystrokeTimeline.Label],
         keystrokeStyle: VideoKeystrokeStyle, captions: [VideoCaptionSegment], captionStyle: VideoCaptionStyle,
         webcam: VideoWebcamLayer?) {
        self.layout = layout
        self.background = background
        self.foreground = foreground
        self.camera = camera
        self.cameraMotionBlur = cameraMotionBlur
        self.cursor = cursor
        self.keystrokes = keystrokes
        self.keystrokeStyle = keystrokeStyle
        self.captions = captions
        self.captionStyle = captionStyle
        self.webcam = webcam
    }
}

// MARK: - Renderer

nonisolated enum VideoSceneRenderer {
    /// Shutter (seconds) at motion-blur amount 1.
    static let maxShutter: Double = 1.0 / 40

    /// - Parameters:
    ///   - content: Upright source frame, extent (0, 0, contentSize), bottom-left.
    ///   - time: Source-asset time of the frame.
    ///   - webcamFrame: Upright camera frame, if a webcam track exists.
    static func render(content: CIImage, time: Double, scene: VideoSceneSnapshot,
                       censors: [VideoCensorSnapshot],
                       texts: [EffectsCompositionInstruction.TextSnapshot],
                       webcamFrame: CIImage? = nil) -> CIImage {
        let layout = scene.layout
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        let H = layout.canvasSize.height
        let cw = layout.contentSize.width, ch = layout.contentSize.height

        // 1. Content-anchored redaction happens before anything moves.
        var frame = content
        let contentRect = CGRect(x: 0, y: 0, width: cw, height: ch)
        for censor in censors {
            let opacity = censor.opacity(at: time)
            guard opacity > 0.001 else { continue }
            let r = censor.rect
            let rect = CGRect(x: r.minX * cw, y: (1 - r.maxY) * ch, width: r.width * cw, height: r.height * ch)
            frame = VideoCensorRenderer.apply(style: censor.style, opacity: opacity, rect: rect,
                                              to: frame, bounds: contentRect)
        }

        // 2. Crop and place the recording in its frame.
        let crop = layout.crop
        let cropRect = CGRect(x: crop.minX * cw, y: (1 - crop.maxY) * ch, width: crop.width * cw, height: crop.height * ch)
        let videoRect = CGRect(x: layout.videoRect.minX, y: H - layout.videoRect.maxY,
                               width: layout.videoRect.width, height: layout.videoRect.height)
        let place = CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
            .concatenating(CGAffineTransform(scaleX: videoRect.width / max(cropRect.width, 1),
                                             y: videoRect.height / max(cropRect.height, 1)))
            .concatenating(CGAffineTransform(translationX: videoRect.minX, y: videoRect.minY))
        var video = frame.cropped(to: cropRect).transformed(by: place).cropped(to: videoRect)
        if layout.cornerRadius > 0.5 {
            let mask = CIFilter.roundedRectangleGenerator()
            mask.extent = videoRect
            mask.radius = Float(layout.cornerRadius)
            mask.color = CIColor.white
            if let maskImage = mask.outputImage {
                let blend = CIFilter.blendWithAlphaMask()
                blend.inputImage = video
                blend.backgroundImage = CIImage.empty()
                blend.maskImage = maskImage
                video = blend.outputImage ?? video
            }
        }
        var composed: CIImage
        if let background = scene.background {
            composed = video.composited(over: background)
        } else {
            composed = video.composited(over: CIImage(color: CIColor.black).cropped(to: canvas))
        }
        if let foreground = scene.foreground { composed = foreground.composited(over: composed) }
        composed = composed.cropped(to: canvas)

        // 3. Camera over the whole scene, with optional motion blur.
        let camera = scene.camera.state(at: time)
        if !camera.isIdentity || scene.camera.spans.contains(where: { $0.start <= time && time <= $0.end }) {
            composed = applyCamera(composed, time: time, scene: scene, camera: camera)
        }

        // 4. Output-space overlays: text boxes follow content through the camera.
        let cameraTransform = camera.transform(canvasSize: layout.canvasSize)
        for text in texts {
            let opacity = text.opacity(at: time)
            guard opacity > 0.001 else { continue }
            let r = layout.canvasRect(forContent: text.rect).applying(cameraTransform)
            let out = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
            let extent = text.image.extent
            guard out.width > 1, out.height > 1, extent.width > 0, extent.height > 0 else { continue }
            let transform = CGAffineTransform(scaleX: out.width / extent.width, y: out.height / extent.height)
                .concatenating(CGAffineTransform(translationX: out.minX, y: out.minY))
            composed = withOpacity(text.image.transformed(by: transform), opacity).composited(over: composed)
        }

        // 5. Pointer and click effects.
        if let cursor = scene.cursor, cursor.style.show {
            composed = drawCursor(on: composed, cursor: cursor, time: time, scene: scene, camera: camera)
        }

        // 6. Camera bubble, keystrokes, captions — fixed to the screen.
        if let webcam = scene.webcam, let webcamFrame, webcam.style.show {
            composed = drawWebcam(webcamFrame, on: composed, layer: webcam, layout: layout, camera: camera, time: time)
        }
        if scene.keystrokeStyle.show, let (label, opacity) = KeystrokeTimeline.active(at: time, in: scene.keystrokes) {
            composed = drawKeystroke(label.text, opacity: opacity, on: composed, scene: scene)
        }
        if scene.captionStyle.show, let (caption, opacity) = CaptionTimeline.active(at: time, in: scene.captions) {
            composed = drawCaption(caption.text, opacity: opacity, on: composed, scene: scene)
        }
        return composed.cropped(to: canvas)
    }

    /// Top-left canvas transform → Core Image (bottom-left) transform.
    static func coreImageTransform(_ t: CGAffineTransform, height H: CGFloat) -> CGAffineTransform {
        // flip · t · flip, where flip(y) = H - y
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        return flip.concatenating(t).concatenating(flip)
    }

    private static func applyCamera(_ scene: CIImage, time: Double, scene snapshot: VideoSceneSnapshot,
                                    camera: CameraState) -> CIImage {
        let layout = snapshot.layout
        let H = layout.canvasSize.height
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        let current = coreImageTransform(camera.transform(canvasSize: layout.canvasSize), height: H)
        let shutter = maxShutter * Double(snapshot.cameraMotionBlur)
        guard shutter > 0 else { return scene.transformed(by: current).cropped(to: canvas) }
        let previous = snapshot.camera.state(at: time - shutter)
        let before = coreImageTransform(previous.transform(canvasSize: layout.canvasSize), height: H)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: canvas.width, y: 0),
                       CGPoint(x: 0, y: canvas.height), CGPoint(x: canvas.width, y: canvas.height)]
        let displacement = corners.map { p -> CGFloat in
            let a = p.applying(current), b = p.applying(before)
            return hypot(a.x - b.x, a.y - b.y)
        }.max() ?? 0
        // Sub-pixel motion needs no blur; cap the sample count for cost.
        guard displacement > 1.5 else { return scene.transformed(by: current).cropped(to: canvas) }
        let samples = min(10, max(3, Int(displacement / 3)))
        var accumulated: CIImage?
        let weight = 1 / CGFloat(samples)
        for k in 0..<samples {
            let fraction = Double(k) / Double(samples - 1)
            let state = snapshot.camera.state(at: time - shutter * (1 - fraction))
            let transform = coreImageTransform(state.transform(canvasSize: layout.canvasSize), height: H)
            let sample = scaled(scene.transformed(by: transform).cropped(to: canvas), weight)
            if let current = accumulated {
                accumulated = sample.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: current])
            } else {
                accumulated = sample
            }
        }
        return (accumulated ?? scene.transformed(by: current)).cropped(to: canvas)
    }

    /// Weights an image for averaging. Core Image color matrices work on
    /// unpremultiplied color, so scaling alpha alone scales every
    /// premultiplied channel once (scaling RGB too would apply it twice).
    static func scaled(_ image: CIImage, _ factor: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: factor),
        ])
    }

    static func withOpacity(_ image: CIImage, _ opacity: CGFloat) -> CIImage {
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity)),
        ])
    }

    /// Tints a white sprite with `color` (straight RGBA) at `opacity`.
    static func tinted(_ image: CIImage, _ color: VideoRGBA, opacity: CGFloat) -> CIImage {
        let a = CGFloat(color.a) * opacity
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(color.r) * a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(color.g) * a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(color.b) * a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
        ])
    }

    // MARK: Cursor

    /// Output position (top-left pixels) of a normalized content point.
    static func outputPoint(_ p: CGPoint, layout: VideoSceneLayout, camera: CameraState) -> CGPoint {
        layout.canvasPoint(forContent: p).applying(camera.transform(canvasSize: layout.canvasSize))
    }

    private static func drawCursor(on image: CIImage, cursor: VideoCursorLayer, time: Double,
                                   scene: VideoSceneSnapshot, camera: CameraState) -> CIImage {
        let layout = scene.layout
        let H = layout.canvasSize.height
        guard let p = cursor.position(at: time) else { return image }
        let alpha = cursor.opacity(at: time)
        let style = cursor.style
        var output = image
        let pointScale = cursor.pixelsPerPoint * layout.contentScale * camera.zoom * CGFloat(style.size)

        // Click effect, under the pointer.
        if style.clickEffect != .none, let (click, progress) = CursorClickEffect.activeClick(at: time, clicks: cursor.clicks),
           let clickPoint = cursor.position(at: click.time) {
            let o = outputPoint(clickPoint, layout: layout, camera: camera)
            let center = CGPoint(x: o.x, y: H - o.y)
            output = drawClickEffect(style.clickEffect, progress: progress, center: center, pointScale: pointScale,
                                     color: style.clickColor, cursor: cursor, on: output, canvas: layout.canvasSize)
        }
        guard alpha > 0.01 else { return output }

        let sprite = cursor.sprite(at: time)
        let press = style.pressBounce ? CursorClickEffect.pressScale(at: time, clicks: cursor.clicks) : 1
        let scale = pointScale * press
        let extent = sprite.image.extent
        guard extent.width > 0, sprite.size.width > 0 else { return output }
        let k = sprite.size.width * scale / extent.width

        let aspect = Double(layout.contentSize.width / max(layout.contentSize.height, 1))
        func placed(at contentPoint: CGPoint, cameraState: CameraState, at t: Double) -> CIImage {
            let o = outputPoint(contentPoint, layout: layout, camera: cameraState)
            let x0 = o.x - sprite.hotspot.x * scale
            let yTop = o.y - sprite.hotspot.y * scale
            let y0 = H - yTop - sprite.size.height * scale
            var transform = CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: x0, y: y0))
            let tilt = CursorSway.angle(at: t, track: cursor.track, amount: style.sway, aspect: aspect)
            if tilt != 0 {
                // Rotate about the hotspot so the tip stays on target.
                let pivot = CGPoint(x: o.x, y: H - o.y)
                transform = transform.concatenating(CGAffineTransform(translationX: -pivot.x, y: -pivot.y))
                    .concatenating(CGAffineTransform(rotationAngle: CGFloat(tilt)))
                    .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
            }
            return sprite.image.transformed(by: transform)
        }

        let current = placed(at: p, cameraState: camera, at: time)
        let shutter = maxShutter * Double(style.motionBlur)
        if shutter > 0, let earlier = cursor.position(at: time - shutter) {
            let previousCamera = scene.camera.state(at: time - shutter)
            let a = outputPoint(p, layout: layout, camera: camera)
            let b = outputPoint(earlier, layout: layout, camera: previousCamera)
            let distance = hypot(a.x - b.x, a.y - b.y)
            if distance > 4 * max(1, scale / 2) {
                let samples = min(12, max(3, Int(distance / 6)))
                var accumulated: CIImage?
                for n in 0..<samples {
                    let f = Double(n) / Double(samples - 1)
                    let t = time - shutter * (1 - f)
                    guard let q = cursor.position(at: t) else { continue }
                    let sample = scaled(placed(at: q, cameraState: scene.camera.state(at: t), at: t), 1 / CGFloat(samples))
                    accumulated = accumulated.map {
                        sample.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0])
                    } ?? sample
                }
                if let accumulated {
                    return withOpacity(accumulated, alpha).composited(over: output)
                }
            }
        }
        return withOpacity(current, alpha).composited(over: output)
    }

    private static func drawClickEffect(_ effect: VideoCursorStyle.ClickEffect, progress: Double, center: CGPoint,
                                        pointScale: CGFloat, color: VideoRGBA, cursor: VideoCursorLayer,
                                        on image: CIImage, canvas: CGSize) -> CIImage {
        let eased = 1 - pow(1 - progress, 3)
        switch effect {
        case .none:
            return image
        case .ripple:
            let diameter = (14 + 46 * CGFloat(eased)) * pointScale
            let opacity = CGFloat(pow(1 - progress, 1.6)) * 0.85
            return placedSprite(cursor.rippleSprite, center: center, diameter: diameter,
                                color: color, opacity: opacity).composited(over: image)
        case .ring:
            let diameter = (52 - 30 * CGFloat(eased)) * pointScale
            let opacity = CGFloat(sin(progress * .pi)) * 0.95
            return placedSprite(cursor.ringSprite, center: center, diameter: diameter,
                                color: color, opacity: opacity).composited(over: image)
        case .spotlight:
            let strength = CGFloat(sin(min(1, progress * 1.3) * .pi)) * 0.42
            guard strength > 0.005 else { return image }
            let radius = 60 * pointScale
            let gradient = CIFilter.radialGradient()
            gradient.center = center
            gradient.radius0 = Float(radius)
            gradient.radius1 = Float(radius * 1.9)
            gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: strength)
            guard let shade = gradient.outputImage?.cropped(to: CGRect(origin: .zero, size: canvas)) else { return image }
            return shade.composited(over: image)
        }
    }

    private static func placedSprite(_ sprite: CIImage, center: CGPoint, diameter: CGFloat,
                                     color: VideoRGBA, opacity: CGFloat) -> CIImage {
        let extent = sprite.extent
        guard extent.width > 0, diameter > 0 else { return CIImage.empty() }
        let k = diameter / extent.width
        let transform = CGAffineTransform(scaleX: k, y: k)
            .concatenating(CGAffineTransform(translationX: center.x - diameter / 2, y: center.y - diameter / 2))
        return tinted(sprite.transformed(by: transform), color, opacity: opacity)
    }

    // MARK: Webcam

    /// Bubble rect in canvas pixels (bottom-left origin) at source `time`.
    static func webcamRect(style: VideoCameraStyle, placement: CameraPlacementTrack?,
                           layout: VideoSceneLayout, zoom: CGFloat, time: Double) -> CGRect {
        let W = layout.canvasSize.width, H = layout.canvasSize.height
        let short = min(W, H)
        let aspect: CGFloat
        switch style.shape {
        case .circle, .roundedSquare: aspect = 1
        case .roundedRect: aspect = 16.0 / 9.0
        case .vertical: aspect = 3.0 / 4.0
        }
        let shrink: CGFloat = style.shrinkOnZoom && zoom > 1.001 ? 1 - 0.35 * min(1, (zoom - 1) / 0.8) : 1

        if style.followsRecording, let sample = placement?.sample(at: time) {
            // Recorded placement is relative to the recording, so it lands
            // where the bubble was over the same content. Screen-fixed: it
            // does not follow the zoom.
            let contentShort = min(layout.contentSize.width, layout.contentSize.height) * layout.contentScale
            let size = min(CGFloat(sample.size) * contentShort * shrink, short)
            let bw = min(size * aspect, W), bh = size
            let c = layout.canvasPoint(forContent: CGPoint(x: sample.centerX, y: sample.centerY))
            let x = min(max(c.x - bw / 2, 0), W - bw)
            let yTop = min(max(c.y - bh / 2, 0), H - bh)
            return CGRect(x: x, y: H - yTop - bh, width: bw, height: bh)
        }

        let size = CGFloat(style.size) * short * shrink
        let bw = size * aspect, bh = size
        let margin = short * 0.035
        let anchor = style.position.anchor
        let x = margin + (W - bw - 2 * margin) * anchor.x
        let yTop = margin + (H - bh - 2 * margin) * anchor.y
        return CGRect(x: x, y: H - yTop - bh, width: bw, height: bh)
    }

    private static func drawWebcam(_ frame: CIImage, on image: CIImage, layer: VideoWebcamLayer,
                                   layout: VideoSceneLayout, camera: CameraState, time: Double) -> CIImage {
        let style = layer.style
        let short = min(layout.canvasSize.width, layout.canvasSize.height)
        let rect = webcamRect(style: style, placement: layer.placement, layout: layout, zoom: camera.zoom, time: time)
        guard rect.width > 1, rect.height > 1 else { return image }

        // Aspect-fill the camera image into the bubble.
        var cam = frame
        let fe = cam.extent
        guard fe.width > 0, fe.height > 0 else { return image }
        if style.mirror {
            cam = cam.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: fe.maxX + fe.minX, ty: 0))
        }
        let fill = max(rect.width / fe.width, rect.height / fe.height)
        let tw = fe.width * fill, th = fe.height * fill
        cam = cam.transformed(by: CGAffineTransform(translationX: -fe.minX, y: -fe.minY)
            .concatenating(CGAffineTransform(scaleX: fill, y: fill))
            .concatenating(CGAffineTransform(translationX: rect.midX - tw / 2, y: rect.midY - th / 2)))
            .cropped(to: rect)
        let radius: CGFloat = style.shape == .circle ? min(rect.width, rect.height) / 2 : min(rect.width, rect.height) * 0.16
        let mask = CIFilter.roundedRectangleGenerator()
        mask.extent = rect
        mask.radius = Float(radius)
        mask.color = CIColor.white
        guard let maskImage = mask.outputImage else { return image }
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = cam
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = maskImage
        guard var bubble = blend.outputImage else { return image }
        var output = image
        if style.shadow {
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).cropped(to: rect)
            let shadowMask = CIFilter.blendWithAlphaMask()
            shadowMask.inputImage = shadow
            shadowMask.backgroundImage = CIImage.empty()
            shadowMask.maskImage = maskImage
            if let s = shadowMask.outputImage {
                let blurred = s.transformed(by: CGAffineTransform(translationX: 0, y: -short * 0.006))
                    .applyingGaussianBlur(sigma: Double(short) * 0.012)
                output = blurred.composited(over: output)
            }
        }
        // Thin light rim keeps the bubble readable on dark content.
        let rim = CIFilter.roundedRectangleGenerator()
        rim.extent = rect.insetBy(dx: -max(1, short * 0.002), dy: -max(1, short * 0.002))
        rim.radius = Float(radius + max(1, short * 0.002))
        rim.color = CIColor(red: 1, green: 1, blue: 1, alpha: 0.35)
        if let rimImage = rim.outputImage { output = rimImage.composited(over: output) }
        bubble = bubble.composited(over: output)
        return bubble
    }

    // MARK: Keystrokes and captions

    private static func drawKeystroke(_ text: String, opacity: CGFloat, on image: CIImage,
                                      scene: VideoSceneSnapshot) -> CIImage {
        let layout = scene.layout
        let short = min(layout.canvasSize.width, layout.canvasSize.height)
        let fontSize = short / 1080 * 34 * CGFloat(scene.keystrokeStyle.size)
        let light = scene.keystrokeStyle.lightAppearance
        guard let label = scene.textCache.pill(text: text, fontSize: fontSize, maxWidth: layout.canvasSize.width * 0.8,
                                               light: light, weight: .semibold) else { return image }
        return place(label, opacity: opacity, position: scene.keystrokeStyle.position, on: image, layout: layout)
    }

    private static func drawCaption(_ text: String, opacity: CGFloat, on image: CIImage,
                                    scene: VideoSceneSnapshot) -> CIImage {
        let layout = scene.layout
        let short = min(layout.canvasSize.width, layout.canvasSize.height)
        let fontSize = short / 1080 * CGFloat(scene.captionStyle.fontSize)
        guard let label = scene.textCache.caption(text: text, fontSize: fontSize,
                                                  maxWidth: layout.canvasSize.width * 0.82,
                                                  background: scene.captionStyle.background) else { return image }
        return place(label, opacity: opacity, position: scene.captionStyle.position, on: image, layout: layout)
    }

    private static func place(_ label: CIImage, opacity: CGFloat, position: VideoOverlayPosition,
                              on image: CIImage, layout: VideoSceneLayout) -> CIImage {
        let W = layout.canvasSize.width, H = layout.canvasSize.height
        let margin = min(W, H) * 0.05
        let e = label.extent
        let anchor = position.anchor
        let x = margin + (W - e.width - 2 * margin) * anchor.x
        let yTop = margin + (H - e.height - 2 * margin) * anchor.y
        let placed = label.transformed(by: CGAffineTransform(translationX: x - e.minX, y: H - yTop - e.height - e.minY))
        return withOpacity(placed, opacity).composited(over: image)
    }
}

// MARK: - Censor

nonisolated enum VideoCensorRenderer {
    /// Obscures `rect` (bottom-left coordinates inside `bounds`).
    static func apply(style: VideoCensorSegment.Style, opacity: CGFloat, rect: CGRect,
                      to image: CIImage, bounds: CGRect) -> CIImage {
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return image }
        let overlay: CIImage
        switch style {
        case .solid:
            overlay = CIImage(color: CIColor.black).cropped(to: clipped)
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = image.clampedToExtent().cropped(to: clipped)
            filter.center = CGPoint(x: clipped.midX, y: clipped.midY)
            filter.scale = Float(VideoCensorSegment.Style.pixelateBlockSize)
            overlay = (filter.outputImage ?? CIImage(color: .black)).cropped(to: clipped)
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image.clampedToExtent()
            filter.radius = Float(VideoCensorSegment.Style.blurRadius)
            overlay = (filter.outputImage ?? image).cropped(to: clipped)
        }
        return VideoSceneRenderer.withOpacity(overlay, opacity).cropped(to: clipped).composited(over: image)
    }
}

// MARK: - Text for keystrokes and captions

/// Rasterizes short labels with Core Text (thread-safe) and caches them, so
/// playback draws each distinct label once.
nonisolated final class OverlayTextCache: @unchecked Sendable {
    enum Weight { case regular, semibold, bold }
    private let cache = NSCache<NSString, CIImage>()

    init() { cache.countLimit = 64 }

    func pill(text: String, fontSize: CGFloat, maxWidth: CGFloat, light: Bool, weight: Weight) -> CIImage? {
        let key = "pill|\(light)|\(Int(fontSize * 10))|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let fg: CGColor = light ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
        let bg: CGColor = light ? CGColor(gray: 1, alpha: 0.92) : CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 0.82)
        let image = OverlayTextCache.render(text: text, fontSize: fontSize, weight: weight, color: fg,
                                            background: bg, padding: CGSize(width: fontSize * 0.7, height: fontSize * 0.42),
                                            radius: fontSize * 0.55, maxWidth: maxWidth, border: !light)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    func caption(text: String, fontSize: CGFloat, maxWidth: CGFloat, background: Bool) -> CIImage? {
        let key = "caption|\(background)|\(Int(fontSize * 10))|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = OverlayTextCache.render(text: text, fontSize: fontSize, weight: .semibold,
                                            color: CGColor(gray: 1, alpha: 1),
                                            background: background ? CGColor(gray: 0, alpha: 0.62) : nil,
                                            padding: CGSize(width: fontSize * 0.55, height: fontSize * 0.3),
                                            radius: fontSize * 0.35, maxWidth: maxWidth, border: false,
                                            shadow: !background)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    static func render(text: String, fontSize: CGFloat, weight: Weight, color: CGColor, background: CGColor?,
                       padding: CGSize, radius: CGFloat, maxWidth: CGFloat, border: Bool,
                       shadow: Bool = false) -> CIImage? {
        guard fontSize > 1, maxWidth > 20, !text.isEmpty else { return nil }
        var font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        if weight != .regular {
            let traits: [CFString: Any] = [kCTFontWeightTrait: weight == .bold ? 0.4 : 0.3]
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font),
                [kCTFontTraitsAttribute: traits] as CFDictionary)
            font = CTFontCreateWithFontDescriptor(descriptor, fontSize, nil)
        }
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafeBytes(of: &alignment) { bytes -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size,
                                                  value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color,
                                           kCTParagraphStyleAttributeName: paragraph]
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return nil }
        let setter = CTFramesetterCreateWithAttributedString(string)
        let textMax = maxWidth - padding.width * 2
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: textMax, height: .greatestFiniteMagnitude), nil)
        let textSize = CGSize(width: ceil(min(textMax, fitted.width)) + 1, height: ceil(fitted.height))
        let width = Int(textSize.width + padding.width * 2), height = Int(textSize.height + padding.height * 2)
        guard width > 0, height > 0, width < 16384, height < 16384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            let path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: min(radius, bounds.height / 2),
                              cornerHeight: min(radius, bounds.height / 2), transform: nil)
            context.addPath(path)
            context.setFillColor(background)
            context.fillPath()
            if border {
                context.addPath(path)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
                context.setLineWidth(max(1, fontSize * 0.04))
                context.strokePath()
            }
        }
        if shadow {
            context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05), blur: fontSize * 0.25,
                              color: CGColor(gray: 0, alpha: 0.85))
        }
        let frameRect = CGRect(x: padding.width, y: padding.height, width: textSize.width, height: textSize.height)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
        CTFrameDraw(frame, context)
        guard let cg = context.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
