import AppKit
import CoreImage
import ImageIO

/// Resolves the stable gradient IDs stored in projects to beautify styles.
enum VideoGradientCatalog {
    static var meshCount: Int { BeautifyRenderer.styles.filter { $0.meshDef != nil }.count }

    static func styleIndex(for id: String) -> Int {
        let parts = id.split(separator: "-")
        let mesh = meshCount
        guard parts.count == 2, let n = Int(parts[1]), n >= 0 else { return mesh }
        if parts[0] == "mesh", n < mesh { return n }
        if parts[0] == "linear", mesh + n < BeautifyRenderer.styles.count { return mesh + n }
        return mesh < BeautifyRenderer.styles.count ? mesh : 0
    }

    static func id(forStyleIndex index: Int) -> String {
        let mesh = meshCount
        return index < mesh ? "mesh-\(index)" : "linear-\(max(0, index - mesh))"
    }

    /// First-run background for new projects: a mesh gradient where the OS
    /// supports them, otherwise a rich linear gradient.
    static var defaultID: String { meshCount > 0 ? "mesh-0" : "linear-3" }
}

/// Static artwork for a layout: background + shadow, and an optional border.
/// Expensive (full-canvas CG drawing), so results are cached by input.
final class VideoSceneArtCache {
    private struct Key: Equatable {
        var layout: VideoSceneLayout
        var frame: VideoFrameStyle
        var directory: URL?
    }
    private var key: Key?
    private var value: (background: CIImage?, foreground: CIImage?)?
    private var imageCache: (path: String, maxPixel: Int, image: CGImage)?

    func art(layout: VideoSceneLayout, frame: VideoFrameStyle, directory: URL?) -> (background: CIImage?, foreground: CIImage?) {
        let newKey = Key(layout: layout, frame: frame, directory: directory)
        if newKey == key, let value { return value }
        let rendered = render(layout: layout, frame: frame, directory: directory)
        key = newKey
        value = rendered
        return rendered
    }

    private func render(layout: VideoSceneLayout, frame: VideoFrameStyle, directory: URL?) -> (background: CIImage?, foreground: CIImage?) {
        guard layout.drawsBackground else { return (nil, nil) }
        let W = Int(layout.canvasSize.width), H = Int(layout.canvasSize.height)
        guard W > 0, H > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, nil) }
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        let short = CGFloat(min(W, H))
        drawBackground(frame.background, in: bounds, context: ctx, directory: directory)
        if frame.background.blur > 0.001, let plain = ctx.makeImage() {
            let radius = frame.background.blur * Double(short) * 0.045
            let blurred = CIImage(cgImage: plain).clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: bounds)
            if let cg = CIContext(options: [.cacheIntermediates: false]).createCGImage(blurred, from: bounds) {
                ctx.clear(bounds)
                ctx.draw(cg, in: bounds)
            }
        }
        // Shadow cast by the recording's rounded rect. The caster itself sits
        // under the (opaque) video, so its color is irrelevant.
        let video = CGRect(x: layout.videoRect.minX, y: CGFloat(H) - layout.videoRect.maxY,
                           width: layout.videoRect.width, height: layout.videoRect.height)
        let radius = layout.cornerRadius
        let path = CGPath(roundedRect: video, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if frame.enabled, frame.shadow > 0.001 {
            let unit = short / 1080
            let strength = CGFloat(frame.shadow)
            let ambient = 18 + 70 * strength
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -unit * (4 + 18 * strength)), blur: unit * ambient,
                          color: CGColor(gray: 0, alpha: 0.28 + 0.4 * strength))
            ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -unit * 3), blur: unit * (6 + 8 * strength),
                          color: CGColor(gray: 0, alpha: 0.18 + 0.2 * strength))
            ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
            ctx.restoreGState()
        }
        let background = ctx.makeImage().map { CIImage(cgImage: $0) }

        var foreground: CIImage?
        if frame.enabled, frame.border,
           let fg = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let width = max(1, short / 1080 * 1.5)
            let inset = video.insetBy(dx: width / 2, dy: width / 2)
            fg.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, radius - width / 2),
                              cornerHeight: max(0, radius - width / 2), transform: nil))
            fg.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
            fg.setLineWidth(width)
            fg.strokePath()
            foreground = fg.makeImage().map { CIImage(cgImage: $0) }
        }
        return (background, foreground)
    }

    private func drawBackground(_ style: VideoBackgroundStyle, in bounds: CGRect, context: CGContext, directory: URL?) {
        switch style.kind {
        case .color:
            context.setFillColor(CGColor(srgbRed: style.color.r, green: style.color.g, blue: style.color.b, alpha: 1))
            context.fill(bounds)
        case .image, .wallpaper:
            if let url = VideoSceneArtCache.imageURL(for: style, directory: directory),
               let image = loadImage(url, maxPixel: Int(max(bounds.width, bounds.height))) {
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                let fill = max(bounds.width / iw, bounds.height / ih)
                let w = iw * fill, h = ih * fill
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h))
            } else {
                drawGradient("linear-0", in: bounds, context: context)
            }
        case .gradient:
            drawGradient(style.gradientID, in: bounds, context: context)
        }
    }

    private func drawGradient(_ id: String, in bounds: CGRect, context: CGContext) {
        var config = BeautifyConfig()
        config.styleIndex = VideoGradientCatalog.styleIndex(for: id)
        let mesh = BeautifyRenderer.prerenderBackground(config: config, width: Int(bounds.width), height: Int(bounds.height))
        BeautifyRenderer.drawGradientBackground(in: bounds, config: config, context: context, prerenderedMesh: mesh)
    }

    static func imageURL(for style: VideoBackgroundStyle, directory: URL?) -> URL? {
        guard let name = style.imageName, !name.isEmpty else { return nil }
        if style.kind == .wallpaper || name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        return directory?.appendingPathComponent(name)
    }

    private func loadImage(_ url: URL, maxPixel: Int) -> CGImage? {
        if let cached = imageCache, cached.path == url.path, cached.maxPixel >= maxPixel { return cached.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        imageCache = (url.path, maxPixel, image)
        return image
    }
}

/// Builds the immutable render snapshot for a project on the main actor.
enum VideoSceneBuilder {
    struct Assets {
        var sprites: [UInt32: CursorSprite] = [:]
        var systemArrow: CursorSprite?
        var dot: CursorSprite?
        var ring: CursorSprite?
        var ripple: CIImage?
        var ringPulse: CIImage?
    }

    /// Decodes recorded cursor images and generates effect sprites once.
    static func makeAssets(recording: CursorRecording?) -> Assets {
        var assets = Assets()
        if let recording {
            for (id, shape) in recording.shapes {
                guard let source = CGImageSourceCreateWithData(shape.png as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                assets.sprites[id] = CursorSprite(image: CIImage(cgImage: cg), hotspot: shape.hotspot, size: shape.size)
            }
        }
        assets.systemArrow = systemArrowSprite()
        assets.dot = generatedSprite(ring: false)
        assets.ring = generatedSprite(ring: true)
        assets.ripple = circleSprite(fillAlpha: 0.32, strokeAlpha: 0.95, strokeWidth: 10)
        assets.ringPulse = circleSprite(fillAlpha: 0, strokeAlpha: 1, strokeWidth: 16)
        return assets
    }

    static func snapshot(project: VideoProject, layout: VideoSceneLayout, recording: CursorRecording?,
                         track: CursorTrack?, assets: Assets, art: VideoSceneArtCache, directory: URL?,
                         drawsCursor: Bool, rendersOverlays: Bool, suspendCamera: Bool,
                         webcam: VideoWebcamLayer?) -> VideoSceneSnapshot {
        let look = project.look
        let (background, foreground) = art.art(layout: layout, frame: look.frame, directory: directory)
        let camera: CameraPath
        if suspendCamera {
            camera = .empty
        } else {
            let zooms = project.zooms.map { zoom in
                CameraPathBuilder.Zoom(start: zoom.startTime, end: zoom.endTime, level: zoom.zoomLevel,
                                       center: zoom.center, follows: zoom.followsCursor && track != nil,
                                       rampIn: zoom.fadeIn, rampOut: zoom.fadeOut)
            }
            camera = CameraPathBuilder.build(zooms: zooms, layout: layout, cursor: track,
                                             connect: look.zoom.connectZooms, deadZone: look.zoom.followDeadZone)
        }

        var cursorLayer: VideoCursorLayer?
        if drawsCursor, let recording, let track, !track.isEmpty,
           let fallback = look.cursor.appearance == .dot ? assets.dot
                : look.cursor.appearance == .ring ? assets.ring : assets.systemArrow,
           let ripple = assets.ripple, let ringPulse = assets.ringPulse {
            let loop = look.cursor.loopToStart ? project.trimStart...project.trimEnd : nil
            let clicks = recording.clicks.filter { $0.button != .other }
            cursorLayer = VideoCursorLayer(track: track, shapeTimes: recording.shapeTimes, shapeIDs: recording.shapeIDs,
                                           sprites: assets.sprites, fallback: fallback, style: look.cursor,
                                           pixelsPerPoint: recording.pixelsPerPoint, clicks: clicks,
                                           keyTimes: recording.keys.map(\.time), rippleSprite: ripple,
                                           ringSprite: ringPulse, loopRange: loop)
        }
        let keystrokes = rendersOverlays && recording != nil
            ? KeystrokeTimeline.labels(from: recording?.keys ?? [], shortcutsOnly: look.keystrokes.shortcutsOnly) : []
        return VideoSceneSnapshot(layout: layout, background: background, foreground: foreground, camera: camera,
                                  cameraMotionBlur: CGFloat(look.zoom.motionBlur), cursor: cursorLayer,
                                  keystrokes: keystrokes, keystrokeStyle: look.keystrokes,
                                  captions: project.captions.sorted { $0.startTime < $1.startTime },
                                  captionStyle: look.captions, webcam: webcam)
    }

    // MARK: Sprites

    private static func systemArrowSprite() -> CursorSprite? {
        let cursor = NSCursor.arrow
        let image = cursor.image
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let best = reps.max(by: { $0.pixelsWide < $1.pixelsWide }), let cg = best.cgImage {
            return CursorSprite(image: CIImage(cgImage: cg), hotspot: cursor.hotSpot, size: image.size)
        }
        var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * 8, height: image.size.height * 8))
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return CursorSprite(image: CIImage(cgImage: cg), hotspot: cursor.hotSpot, size: image.size)
    }

    /// A touch-style dot (or hollow ring) pointer, 20 pt, drawn at 8×.
    private static func generatedSprite(ring: Bool) -> CursorSprite? {
        let points: CGFloat = 20, scale: CGFloat = 8
        let px = Int(points * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: px, height: px).insetBy(dx: 3 * scale, dy: 3 * scale)
        ctx.setShadow(offset: CGSize(width: 0, height: -scale), blur: 2.5 * scale, color: CGColor(gray: 0, alpha: 0.45))
        if ring {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(2.6 * scale)
            ctx.strokeEllipse(in: rect.insetBy(dx: 1.3 * scale, dy: 1.3 * scale))
        } else {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: rect)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.92))
            ctx.fillEllipse(in: rect.insetBy(dx: 2 * scale, dy: 2 * scale))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CursorSprite(image: CIImage(cgImage: cg), hotspot: CGPoint(x: points / 2, y: points / 2),
                            size: CGSize(width: points, height: points))
    }

    /// White circle used for click effects; tinted per project at render time.
    private static func circleSprite(fillAlpha: CGFloat, strokeAlpha: CGFloat, strokeWidth: CGFloat) -> CIImage? {
        let px = 256
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: px, height: px).insetBy(dx: strokeWidth, dy: strokeWidth)
        if fillAlpha > 0 {
            ctx.setFillColor(CGColor(gray: 1, alpha: fillAlpha))
            ctx.fillEllipse(in: rect)
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: strokeAlpha))
        ctx.setLineWidth(strokeWidth)
        ctx.strokeEllipse(in: rect)
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}
