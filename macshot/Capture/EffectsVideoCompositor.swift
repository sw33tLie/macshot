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

    /// One contiguous mapping from composition-clock time back to source-asset
    /// time. The compositor picks the entry covering the current frame's
    /// `compositionTime` and computes
    ///     `sourceTime = sourceStart + (compTime - compStart) * factor`.
    ///
    /// For a simple composition with no cuts/speed this is a single entry
    /// spanning the whole composition with `factor == 1`. Cuts produce one
    /// entry per kept range (still factor 1, but `sourceStart != compStart`).
    /// Speed segments split a kept range into multiple entries with
    /// `factor != 1` for the sped-up pieces.
    struct TimeMapEntry: Sendable {
        /// Start of this piece on the composition clock (seconds).
        let compStart: Double
        /// End of this piece on the composition clock (seconds).
        let compEnd: Double
        /// Source-asset time corresponding to `compStart`.
        let sourceStart: Double
        /// Ratio `sourceDuration / compDuration` for the piece. 1.0 is
        /// pass-through. 2.0 means the range plays at 2× (2s of source
        /// in 1s of composition); 0.5 means half speed.
        let factor: Double

        /// Convenience for call sites that still think in terms of a
        /// scalar offset (used for pure cuts where factor == 1).
        var sourceOffset: Double { sourceStart - compStart }
    }

    // MARK: Protocol requirements
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    var requiredSourceTrackIDs: [NSValue]? {
        if let webcamTrackID = scene?.webcam?.trackID {
            return [NSNumber(value: videoTrackID), NSNumber(value: webcamTrackID)]
        }
        return [NSNumber(value: videoTrackID)]
    }
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    // MARK: Our payload
    let videoTrackID: CMPersistentTrackID
    let naturalSize: CGSize
    let renderSize: CGSize
    let baseTransform: CGAffineTransform
    let timeMap: [TimeMapEntry]
    let zoomSegments: [VideoZoomSnapshot]
    let censorSegments: [VideoCensorSnapshot]
    /// Text segments paired with their pre-rasterized images. Keeping the
    /// CIImage inside the snapshot means per-frame rendering does no font
    /// shaping or NSAttributedString work — we just composite the cached
    /// image. Built on the main actor at snapshot time and never mutated.
    let textSnapshots: [TextSnapshot]
    /// Framed scene (background, camera, cursor…). When present `renderSize`
    /// is the canvas size and `baseTransform` yields the upright source at
    /// its natural size.
    let scene: VideoSceneSnapshot?

    /// Pre-rasterized text overlay paired with timing/positioning.
    /// `image` extent is in pixels; the compositor scales it to the segment's
    /// rect in render-space at draw time.
    struct TextSnapshot: Sendable {
        let id: UUID
        let startTime: Double
        let endTime: Double
        let rect: CGRect
        /// Same opacity curve as the segment — captured here so the compositor
        /// doesn't depend on `VideoTextSegment` directly (which is main-actor
        /// state we shouldn't share with background queues).
        let fadeIn: Double
        let fadeOut: Double
        let image: CIImage

        nonisolated func opacity(at t: Double) -> CGFloat {
            VideoEffectTiming.opacity(at: t, start: startTime, end: endTime,
                                      fadeIn: fadeIn, fadeOut: fadeOut)
        }
    }

    init(timeRange: CMTimeRange,
         videoTrackID: CMPersistentTrackID,
         naturalSize: CGSize,
         renderSize: CGSize,
         baseTransform: CGAffineTransform,
         timeMap: [TimeMapEntry],
         zoomSegments: [VideoZoomSnapshot],
         censorSegments: [VideoCensorSnapshot],
         textSnapshots: [TextSnapshot] = [],
         scene: VideoSceneSnapshot? = nil) {
        self.timeRange = timeRange
        self.videoTrackID = videoTrackID
        self.naturalSize = naturalSize
        self.renderSize = renderSize
        self.baseTransform = baseTransform
        self.timeMap = timeMap
        self.zoomSegments = zoomSegments
        self.censorSegments = censorSegments
        self.textSnapshots = textSnapshots
        self.scene = scene
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
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    /// What we produce. Must be compatible with the render context.
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    // MARK: - Rendering context

    private let renderQueue = CancellableRenderQueue()
    private lazy var ciContext: CIContext = {
        // Blur/pixelate filters do per-pixel math and must happen in a linear
        // color space to avoid gamma shifts (sRGB working space "washes out"
        // the whole frame because filters convert to and from the working
        // space even for untouched pixels in the composite).
        //
        // We leave the output color space unset so CIImage metadata from the
        // source pixel buffer passes through unchanged on the untouched parts
        // of the frame. The explicit render(colorSpace:) below picks the
        // final tag used when writing into the output CVPixelBuffer.
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB) as Any,
            .cacheIntermediates: true,
        ]
        return CIContext(options: options)
    }()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Each request supplies its own context; no global pool to replace.
    }

    // MARK: - Request handling

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.submit(work: { [weak self] in
            guard let self else { request.finishCancelledRequest(); return }
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? EffectsCompositionInstruction else {
                    request.finish(with: CompositorError.missingInstruction)
                    return
                }
                guard let sourceBuffer = request.sourceFrame(byTrackID: instruction.videoTrackID) else {
                    request.finish(with: CompositorError.missingSource)
                    return
                }
                // A request owns the context for its particular render size.
                // A newer renderContextChanged notification must not change a
                // previously queued request's output pool.
                guard let outBuf = request.renderContext.newPixelBuffer() else {
                    request.finish(with: CompositorError.noOutputBuffer)
                    return
                }
                self.render(request: request, instruction: instruction,
                            sourceBuffer: sourceBuffer, outBuf: outBuf)
            }
        }, onCancel: {
            request.finishCancelledRequest()
        })
    }

    func cancelAllPendingVideoCompositionRequests() {
        renderQueue.cancelAll()
    }

    // MARK: - Core render

    private func render(request: AVAsynchronousVideoCompositionRequest,
                         instruction: EffectsCompositionInstruction,
                         sourceBuffer: CVPixelBuffer,
                         outBuf: CVPixelBuffer) {
        let compTime = CMTimeGetSeconds(request.compositionTime)
        // Map composition time → source-asset time via the segmented time map.
        // `sourceTime = entry.sourceStart + (compTime - entry.compStart) * factor`.
        // Falls back to `compTime` unchanged if no entry matches (shouldn't
        // happen in practice, but keeps rendering sensible instead of black).
        let assetTime: Double = {
            for entry in instruction.timeMap where compTime >= entry.compStart && compTime < entry.compEnd {
                return entry.sourceStart + (compTime - entry.compStart) * entry.factor
            }
            // Clamp to last entry if we're past its end by a tiny epsilon so
            // zoom/censor ramps at the tail don't suddenly snap back to 0.
            if let last = instruction.timeMap.last, compTime >= last.compEnd {
                return last.sourceStart + (last.compEnd - last.compStart) * last.factor
            }
            return compTime
        }()
        if let scene = instruction.scene {
            renderScene(request: request, instruction: instruction, scene: scene, sourceBuffer: sourceBuffer,
                        outBuf: outBuf, assetTime: assetTime)
            return
        }
        let renderSize = instruction.renderSize
        let naturalSize = instruction.naturalSize

        // Source → CIImage (top-left origin; `CIImage` uses bottom-left, so we
        // flip via transforms when we need image-space coordinates).
        var image = CIImage(cvPixelBuffer: sourceBuffer)

        // 1. Apply base orientation + scale so `image` lives in render-space.
        image = image.transformed(by: instruction.baseTransform)

        // 2. Apply active zoom transform (there's at most one active zoom —
        //    the UI prevents overlap within a single segment type).
        //
        //    `zoomTranslation` is computed in image-space (y-down, 0 = top
        //    edge) to match the normalized rect the user drew. CIImage
        //    transforms work in math-space (y-up, 0 = bottom edge), so we
        //    negate the y component before feeding it into the concatenated
        //    transform. Without this, zooming into a point near the top of
        //    the video ends up showing content from the bottom.
        let (zoomLevel, zoomTranslation) = activeZoom(at: assetTime, segments: instruction.zoomSegments, naturalSize: naturalSize)
        if zoomLevel > 1.0001 {
            let t = VideoRenderGeometry.zoomTransform(zoom: zoomLevel, translation: zoomTranslation,
                                                       naturalSize: naturalSize, renderSize: renderSize)
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

        // 4b. Apply text overlays. Each text image is pre-rasterized at the
        //     pixel size of its rect in render-space, so the per-frame work
        //     is just a transform + composite. Text follows the same zoom
        //     transform as censor (positionally tied to the source content).
        for text in instruction.textSnapshots {
            let opacity = text.opacity(at: assetTime)
            guard opacity > 0.001 else { continue }
            let outRect = censorOutputRect(
                normalizedRect: text.rect,
                renderSize: renderSize,
                naturalSize: naturalSize,
                zoomLevel: zoomLevel,
                zoomTranslation: zoomTranslation
            )
            guard outRect.width > 1, outRect.height > 1 else { continue }
            // Scale the cached image (in source pixels) into the output rect.
            let imgExtent = text.image.extent
            guard imgExtent.width > 0, imgExtent.height > 0 else { continue }
            let sx = outRect.width / imgExtent.width
            let sy = outRect.height / imgExtent.height
            var t = CGAffineTransform(scaleX: sx, y: sy)
            t = t.concatenating(CGAffineTransform(translationX: outRect.minX,
                                                   y: outRect.minY))
            var overlay = text.image.transformed(by: t).cropped(to: renderRect)
            if opacity < 0.999 {
                let cm = CIFilter.colorMatrix()
                cm.inputImage = overlay
                cm.aVector = CIVector(x: 0, y: 0, z: 0, w: opacity)
                if let out = cm.outputImage {
                    overlay = out.cropped(to: outRect.intersection(renderRect))
                }
            }
            image = overlay.composited(over: image)
        }

        // 5. Render into the output pixel buffer. Tag with the SOURCE buffer's
        // color space when available so untouched pixels round-trip to the
        // same bytes they came in as — preventing the "washed out" look that
        // happens when blur causes Core Image to pipe everything through a
        // working space then re-tag the output differently.
        let sourceColorSpace = CVImageBufferGetColorSpace(sourceBuffer)?.takeUnretainedValue()
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(image, to: outBuf, bounds: renderRect, colorSpace: sourceColorSpace)
        request.finish(withComposedVideoFrame: outBuf)
    }

    /// Framed-scene rendering. Output buffers may be smaller than the canvas
    /// (preview render scale); the whole scene is scaled to fit.
    private func renderScene(request: AVAsynchronousVideoCompositionRequest,
                             instruction: EffectsCompositionInstruction, scene: VideoSceneSnapshot,
                             sourceBuffer: CVPixelBuffer, outBuf: CVPixelBuffer, assetTime: Double) {
        let content = CIImage(cvPixelBuffer: sourceBuffer).transformed(by: instruction.baseTransform)
        var webcamFrame: CIImage?
        if let webcam = scene.webcam, let buffer = request.sourceFrame(byTrackID: webcam.trackID) {
            webcamFrame = CIImage(cvPixelBuffer: buffer).transformed(by: webcam.uprightTransform)
        }
        var image = VideoSceneRenderer.render(content: content, time: assetTime, scene: scene,
                                              censors: instruction.censorSegments, texts: instruction.textSnapshots,
                                              webcamFrame: webcamFrame)
        let canvas = scene.layout.canvasSize
        let outW = CGFloat(CVPixelBufferGetWidth(outBuf)), outH = CGFloat(CVPixelBufferGetHeight(outBuf))
        if abs(outW - canvas.width) > 0.5 || abs(outH - canvas.height) > 0.5, canvas.width > 0, canvas.height > 0 {
            image = image.transformed(by: CGAffineTransform(scaleX: outW / canvas.width, y: outH / canvas.height))
        }
        let bounds = CGRect(x: 0, y: 0, width: outW, height: outH)
        let colorSpace = CVImageBufferGetColorSpace(sourceBuffer)?.takeUnretainedValue()
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(image.cropped(to: bounds), to: outBuf, bounds: bounds, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: outBuf)
    }

    // MARK: - Helpers

    /// Pick the single active zoom segment for `assetTime` (segments don't
    /// overlap, so at most one wins) and return the interpolated zoom level
    /// plus translation vector.
    private func activeZoom(at t: Double, segments: [VideoZoomSnapshot], naturalSize: CGSize) -> (CGFloat, CGPoint) {
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
        VideoRenderGeometry.overlayRect(normalizedRect, naturalSize: naturalSize, renderSize: renderSize,
                                         zoom: zoomLevel, translation: zoomTranslation)
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
