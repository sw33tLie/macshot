import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

// MARK: - Instruction

/// Custom instruction conforming directly to the protocol. Earlier we
/// subclassed `AVMutableVideoCompositionInstruction`, but AVFoundation strips
/// the mutable subclass internally and delivers a plain
/// `AVVideoCompositionInstruction` to `startRequest` — dropping all our
/// payload fields. Conforming to the protocol directly avoids that round-trip.
final class EffectsCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {

    // MARK: Protocol requirements
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    // MARK: Our payload
    let videoTrackID: CMPersistentTrackID
    let naturalSize: CGSize
    let renderSize: CGSize
    let baseTransform: CGAffineTransform
    let timeShift: Double
    let zoomSegments: [VideoZoomSegment]
    let censorSegments: [VideoCensorSegment]

    init(timeRange: CMTimeRange,
         videoTrackID: CMPersistentTrackID,
         naturalSize: CGSize,
         renderSize: CGSize,
         baseTransform: CGAffineTransform,
         timeShift: Double,
         zoomSegments: [VideoZoomSegment],
         censorSegments: [VideoCensorSegment]) {
        self.timeRange = timeRange
        self.videoTrackID = videoTrackID
        self.naturalSize = naturalSize
        self.renderSize = renderSize
        self.baseTransform = baseTransform
        self.timeShift = timeShift
        self.zoomSegments = zoomSegments
        self.censorSegments = censorSegments
        self.requiredSourceTrackIDs = [NSNumber(value: Int(videoTrackID))]
        super.init()
    }
}

// MARK: - Compositor

/// `AVVideoCompositing` implementation that renders zoom + censor effects per
/// frame via Core Image. This replaces a chain of `setTransformRamp` calls —
/// we evaluate transforms directly from the segment curves so the motion is
/// smooth (no stepped approximation) and blur/pixelate effects can coexist
/// with zoom in a single render pass.
///
/// Threading: AVFoundation invokes `startRequest(_:)` on its own queues. This
/// class carries no main-actor state and is safe to use from any queue.
final class EffectsVideoCompositor: NSObject, AVVideoCompositing {


    // MARK: Required attributes

    /// What we can accept from the asset reader.
    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    /// What we produce. Must be compatible with the render context.
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    // MARK: - Rendering context

    /// Guarded by `contextQueue`.
    private var renderContext: AVVideoCompositionRenderContext?
    private let contextQueue = DispatchQueue(label: "macshot.effects.context")
    private let renderQueue = DispatchQueue(label: "macshot.effects.render", qos: .userInitiated)
    private lazy var ciContext: CIContext = {
        // Use the default Metal device; CIContext picks GPU automatically.
        // We pass a working color space so blurred/pixelated regions don't
        // shift hue vs the untouched source.
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .cacheIntermediates: true,
        ]
        return CIContext(options: options)
    }()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        contextQueue.sync {
            self.renderContext = newRenderContext
        }
    }

    // MARK: - Request handling

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? EffectsCompositionInstruction else {
            request.finish(with: CompositorError.missingInstruction)
            return
        }
        guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.videoTrackID) else {
            request.finish(with: CompositorError.missingSource)
            return
        }
        let outputBuffer: CVPixelBuffer? = contextQueue.sync { renderContext?.newPixelBuffer() }
        guard let outBuf = outputBuffer else {
            request.finish(with: CompositorError.noOutputBuffer)
            return
        }

        renderQueue.async { [weak self] in
            guard let self = self else {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                self.render(request: request,
                             instruction: instruction,
                             sourceBuffer: sourceBuffer,
                             outBuf: outBuf)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Nothing queued ourselves — each request completes independently and
        // honors cancellation via finishCancelledRequest elsewhere if needed.
    }

    // MARK: - Core render

    private func render(request: AVAsynchronousVideoCompositionRequest,
                         instruction: EffectsCompositionInstruction,
                         sourceBuffer: CVPixelBuffer,
                         outBuf: CVPixelBuffer) {
        let compTime = CMTimeGetSeconds(request.compositionTime)
        let assetTime = compTime + instruction.timeShift
        let renderSize = instruction.renderSize
        let naturalSize = instruction.naturalSize

        // Source → CIImage (top-left origin; `CIImage` uses bottom-left, so we
        // flip via transforms when we need image-space coordinates).
        var image = CIImage(cvPixelBuffer: sourceBuffer)

        // 1. Apply base orientation + scale so `image` lives in render-space.
        image = image.transformed(by: instruction.baseTransform)

        // 2. Apply active zoom transform (there's at most one active zoom —
        //    the UI prevents overlap within a single segment type).
        let (zoomLevel, zoomTranslation) = activeZoom(at: assetTime, segments: instruction.zoomSegments, naturalSize: naturalSize)
        if zoomLevel > 1.0001 {
            let renderCx = renderSize.width / 2
            let renderCy = renderSize.height / 2
            let scaleX = renderSize.width / naturalSize.width
            let scaleY = renderSize.height / naturalSize.height
            var t = CGAffineTransform(translationX: -renderCx, y: -renderCy)
            t = t.concatenating(CGAffineTransform(scaleX: zoomLevel, y: zoomLevel))
            t = t.concatenating(CGAffineTransform(translationX: renderCx + zoomTranslation.x * scaleX * zoomLevel,
                                                   y: renderCy + zoomTranslation.y * scaleY * zoomLevel))
            image = image.transformed(by: t)
        }

        // 3. Crop / extend to the render rect so CI doesn't try to render the
        //    virtually-infinite transformed image; also fills off-frame areas
        //    that would otherwise be transparent with black.
        let renderRect = CGRect(origin: .zero, size: renderSize)
        let blackBg = CIImage(color: CIColor.black).cropped(to: renderRect)
        image = image.cropped(to: renderRect).composited(over: blackBg)

        // 4. Apply censors in the composited (post-zoom) image. Censor rects
        //    are in natural-image coordinates; when a zoom is active we apply
        //    the same zoom transform to the rect so the censor follows the
        //    content it was drawn over.
        for censor in instruction.censorSegments {
            let opacity = censor.opacity(at: assetTime)
            guard opacity > 0.001 else { continue }
            let censorRect = censorOutputRect(
                normalizedRect: censor.rect,
                renderSize: renderSize,
                naturalSize: naturalSize,
                zoomLevel: zoomLevel,
                zoomTranslation: zoomTranslation
            )
            guard censorRect.width > 1, censorRect.height > 1 else { continue }
            image = applyCensor(style: censor.style,
                                opacity: opacity,
                                rectInRenderSpace: censorRect,
                                to: image,
                                fullRenderRect: renderRect)
        }

        // 5. Render into the output pixel buffer.
        let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(image, to: outBuf, bounds: renderRect, colorSpace: outputColorSpace)
        request.finish(withComposedVideoFrame: outBuf)
    }

    // MARK: - Helpers

    /// Pick the single active zoom segment for `assetTime` (segments don't
    /// overlap, so at most one wins) and return the interpolated zoom level
    /// plus translation vector.
    private func activeZoom(at t: Double, segments: [VideoZoomSegment], naturalSize: CGSize) -> (CGFloat, CGPoint) {
        for seg in segments where t >= seg.startTime && t <= seg.endTime {
            let z = seg.zoomLevel(at: t)
            let tr = seg.translation(zoom: z, videoSize: naturalSize)
            return (z, tr)
        }
        return (1.0, .zero)
    }

    /// Map a normalized censor rect (natural-image, y-top) into render-space
    /// (y-bottom, CIImage convention), accounting for any active zoom.
    private func censorOutputRect(normalizedRect: CGRect,
                                   renderSize: CGSize,
                                   naturalSize: CGSize,
                                   zoomLevel: CGFloat,
                                   zoomTranslation: CGPoint) -> CGRect {
        // Rect in natural-image pixel coords, y-top origin
        let x = normalizedRect.origin.x * naturalSize.width
        let yTop = normalizedRect.origin.y * naturalSize.height
        let w = normalizedRect.size.width * naturalSize.width
        let h = normalizedRect.size.height * naturalSize.height

        // Convert to render-space by applying the same scale as the base
        // orientation/render-size transform (renderSize / naturalSize), then
        // flipping y since CIImage is y-bottom.
        let scaleX = renderSize.width / naturalSize.width
        let scaleY = renderSize.height / naturalSize.height
        var renderX = x * scaleX
        var renderY = renderSize.height - (yTop + h) * scaleY  // flip y
        var renderW = w * scaleX
        var renderH = h * scaleY

        // Apply zoom transform if active (same formula as the image transform,
        // evaluated on the rect's origin + size).
        if zoomLevel > 1.0001 {
            let cx = renderSize.width / 2
            let cy = renderSize.height / 2
            // Translate rect origin about render center, scale, translate back
            let rectLeft = renderX
            let rectRight = renderX + renderW
            let rectBottom = renderY
            let rectTop = renderY + renderH

            func transformPoint(_ px: CGFloat, _ py: CGFloat) -> (CGFloat, CGFloat) {
                let dx = px - cx
                let dy = py - cy
                let sx = dx * zoomLevel
                let sy = dy * zoomLevel
                return (cx + sx + zoomTranslation.x * scaleX * zoomLevel,
                        cy + sy + zoomTranslation.y * scaleY * zoomLevel)
            }
            let (lx, ly) = transformPoint(rectLeft, rectBottom)
            let (rx, ry) = transformPoint(rectRight, rectTop)
            renderX = min(lx, rx)
            renderY = min(ly, ry)
            renderW = abs(rx - lx)
            renderH = abs(ry - ly)
        }

        return CGRect(x: renderX, y: renderY, width: renderW, height: renderH)
    }

    /// Create a censor overlay (solid / pixelate / blur) inside `rectInRenderSpace`
    /// and composite it over `image`. `opacity` drives a cross-fade for short fades.
    private func applyCensor(style: VideoCensorSegment.Style,
                              opacity: CGFloat,
                              rectInRenderSpace: CGRect,
                              to image: CIImage,
                              fullRenderRect: CGRect) -> CIImage {
        // Clip the target rect to the visible output so we don't process
        // pixels off-screen.
        let clipped = rectInRenderSpace.intersection(fullRenderRect)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return image }

        let overlay: CIImage
        switch style {
        case .solid:
            overlay = CIImage(color: CIColor.black).cropped(to: clipped)

        case .pixelate:
            // Pixelate the region of the base image, not a solid color, so the
            // redacted area retains its general color/shape without revealing
            // detail.
            let pixelFilter = CIFilter.pixellate()
            pixelFilter.inputImage = image.cropped(to: clipped)
            pixelFilter.center = CGPoint(x: clipped.midX, y: clipped.midY)
            pixelFilter.scale = Float(VideoCensorSegment.Style.pixelateBlockSize)
            overlay = (pixelFilter.outputImage ?? CIImage(color: .black))
                .cropped(to: clipped)

        case .blur:
            // Clamp-to-extent prevents the gaussian kernel from sampling
            // off-image (black edges). We blur the whole frame clamped, then
            // crop to the target rect.
            let clamped = image.clampedToExtent()
            let blurFilter = CIFilter.gaussianBlur()
            blurFilter.inputImage = clamped
            blurFilter.radius = Float(VideoCensorSegment.Style.blurRadius)
            overlay = (blurFilter.outputImage ?? image).cropped(to: clipped)
        }

        // Opacity cross-fade for short segments — mix overlay with base.
        let finalOverlay: CIImage
        if opacity < 0.999 {
            let colorMatrix = CIFilter.colorMatrix()
            colorMatrix.inputImage = overlay
            colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
            finalOverlay = (colorMatrix.outputImage ?? overlay).cropped(to: clipped)
        } else {
            finalOverlay = overlay
        }

        return finalOverlay.composited(over: image)
    }

    // MARK: - Errors

    private enum CompositorError: Error {
        case missingInstruction
        case missingSource
        case noOutputBuffer
    }
}
