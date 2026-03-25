import Cocoa
import ScreenCaptureKit
import Vision

// MARK: - ScrollCaptureController

/// Manages a scroll-capture session: captures strips whenever scroll activity is detected,
/// stitches them together using SAD template matching to find the exact pixel overlap.
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive: Bool = false

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen

    private var scDisplay: SCDisplay?
    private var excludedSCWindows: [SCWindow] = []
    private var scSourceRect: CGRect = .zero

    // Scroll monitors
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Throttle: capture at most once every `captureInterval` seconds while scrolling
    private let captureInterval: TimeInterval = 0.25
    private var lastCaptureTime: TimeInterval = 0
    private var pendingCaptureTask: Task<Void, Never>? = nil
    // End-of-scroll: capture one final frame after scroll momentum dies
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.40
    // Guard: only one captureAndStitch at a time
    private var isCapturing: Bool = false

    // Scroll direction: auto-detected on first stitch, then locked
    private enum ScrollDirection { case unknown, vertical, horizontal }
    private var scrollDirection: ScrollDirection = .unknown

    // Stitching state — all in points (not pixels), Vision works in normalised/point space
    private var previousStrip: NSImage?       // last captured strip (for registration)
    private var runningStitched: NSImage?     // growing stitched canvas in points

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
    }

    // MARK: - Session

    func startSession() async {
        guard !isActive else { return }

        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            scDisplay = content.displays.first(where: { d in
                screenID != nil && d.displayID == screenID!
            }) ?? content.displays.first
            excludedSCWindows = content.windows.filter { excludedWindowIDs.contains(CGWindowID($0.windowID)) }
        }
        guard scDisplay != nil else { onSessionDone?(nil); return }

        // AppKit → SCKit coordinate conversion (bottom-left → top-left origin)
        let df = screen.frame
        scSourceRect = CGRect(
            x: captureRect.minX - df.minX,
            y: (df.maxY - captureRect.maxY) - df.minY,
            width:  captureRect.width,
            height: captureRect.height
        )

        guard let firstCG = await captureStrip() else { onSessionDone?(nil); return }
        let scale = screen.backingScaleFactor
        let firstImg = NSImage(cgImage: firstCG,
                               size: CGSize(width:  CGFloat(firstCG.width)  / scale,
                                            height: CGFloat(firstCG.height) / scale))
        isActive        = true
        scrollDirection = .unknown
        previousStrip   = firstImg
        runningStitched = firstImg
        stitchedImage   = firstCG
        stitchedPixelSize = CGSize(width: CGFloat(firstCG.width), height: CGFloat(firstCG.height))
        stripCount      = 1
        onStripAdded?(stripCount)

        // Monitor both global (events to other apps) and local (events falling through overlay)
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.onScrollEvent()
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onScrollEvent()
            return event
        }
    }

    func stopSession() {
        isActive = false
        settlementTimer?.invalidate(); settlementTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        deliverResult()
    }

    // MARK: - Scroll handling

    private func onScrollEvent() {
        guard isActive else { return }

        // Reset settlement timer on every scroll event
        settlementTimer?.invalidate()
        settlementTimer = Timer.scheduledTimer(withTimeInterval: settlementInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in await self.captureAndStitch() }
        }

        // Throttle: don't capture more often than captureInterval
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaptureTime >= captureInterval else { return }
        lastCaptureTime = now

        pendingCaptureTask?.cancel()
        pendingCaptureTask = Task { [weak self] in
            await self?.captureAndStitch()
        }
    }

    private func captureAndStitch() async {
        guard isActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let cgStrip = await captureStrip() else { return }
        let scale = screen.backingScaleFactor
        let newStrip = NSImage(cgImage: cgStrip,
                               size: CGSize(width:  CGFloat(cgStrip.width)  / scale,
                                            height: CGFloat(cgStrip.height) / scale))

        guard let prev = previousStrip else { return }

        guard let t = translationOffset(from: newStrip, to: prev) else {
            previousStrip = newStrip
            return
        }

        // Auto-detect scroll direction on first real movement
        if scrollDirection == .unknown {
            if abs(t.tx) > abs(t.ty) && abs(t.tx) > 2 {
                scrollDirection = .horizontal
            } else if abs(t.ty) > 2 {
                scrollDirection = .vertical
            } else {
                return  // too small to determine
            }
        }

        let base = runningStitched ?? prev

        if scrollDirection == .vertical {
            let offset = t.ty
            if offset > 0 {
                guard let composed = compositeVertical(base: base, new: newStrip, offset: offset, append: true) else { return }
                updateStitched(composed, newStrip: newStrip, scale: scale)
            } else if offset < 0 {
                if let trimmed = cropEdge(of: base, by: abs(offset), direction: .bottom) {
                    updateStitched(trimmed, newStrip: newStrip, scale: scale, countStrip: false)
                } else { previousStrip = newStrip }
            }
        } else {
            let offset = t.tx
            if offset > 0 {
                guard let composed = compositeHorizontal(base: base, new: newStrip, offset: offset, append: true) else { return }
                updateStitched(composed, newStrip: newStrip, scale: scale)
            } else if offset < 0 {
                guard let composed = compositeHorizontal(base: base, new: newStrip, offset: abs(offset), append: false) else { return }
                updateStitched(composed, newStrip: newStrip, scale: scale)
            }
        }
    }

    private func updateStitched(_ image: NSImage, newStrip: NSImage, scale: CGFloat, countStrip: Bool = true) {
        runningStitched = image
        stitchedImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        stitchedPixelSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        previousStrip = newStrip
        if countStrip {
            stripCount += 1
            onStripAdded?(stripCount)
        }
    }

    // MARK: - Strip capture

    private func captureStrip() async -> CGImage? {
        guard let display = scDisplay else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: excludedSCWindows)
        let config = SCStreamConfiguration()
        config.sourceRect        = scSourceRect
        config.width             = Int(captureRect.width  * screen.backingScaleFactor)
        config.height            = Int(captureRect.height * screen.backingScaleFactor)
        config.showsCursor       = false
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }
        // Use SCStream single-frame capture (works on macOS 12.3+)
        let handler = ScrollStripFrameHandler()
        guard let stream = try? SCStream(filter: filter, configuration: config, delegate: nil) else { return nil }
        do {
            try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: DispatchQueue(label: "macshot.scrollstrip"))
            try await stream.startCapture()
            let image = await handler.waitForFrame()
            try? await stream.stopCapture()
            guard let raw = image else { return nil }
            return copyToCPUBacked(raw) ?? raw
        } catch {
            return nil
        }
    }

    // MARK: - Vision-based offset detection

    /// Returns the (tx, ty) translation (in points) needed to align `current` onto `reference`.
    /// ty positive = current is below reference (downward scroll).
    /// tx positive = current is right of reference (rightward scroll).
    /// nil = registration failed.
    private func translationOffset(from current: NSImage, to reference: NSImage) -> (tx: CGFloat, ty: CGFloat)? {
        guard let curCG = current.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let refCG = reference.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: refCG)
        let handler = VNImageRequestHandler(cgImage: curCG, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }

        let t = obs.alignmentTransform
        guard current.size.height > 0, current.size.width > 0 else { return nil }
        let pixelScaleY = CGFloat(curCG.height) / current.size.height
        let pixelScaleX = CGFloat(curCG.width) / current.size.width
        let ty = t.ty / (pixelScaleY > 0 ? pixelScaleY : 1)
        let tx = t.tx / (pixelScaleX > 0 ? pixelScaleX : 1)
        return (tx, ty)
    }

    // MARK: - Stitching helpers

    /// Composite `new` below/above `base` with `offset` points of new content.
    /// `append` = true: new content at bottom (downward scroll).
    private func compositeVertical(base: NSImage, new: NSImage, offset: CGFloat, append: Bool) -> NSImage? {
        let totalH = base.size.height + offset
        let size = NSSize(width: base.size.width, height: totalH)
        let result = NSImage(size: size, flipped: false) { _ in
            if append {
                base.draw(in: CGRect(x: 0, y: totalH - base.size.height, width: base.size.width, height: base.size.height))
                new.draw(in: CGRect(x: 0, y: 0, width: new.size.width, height: new.size.height))
            } else {
                base.draw(in: CGRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
                new.draw(in: CGRect(x: 0, y: totalH - new.size.height, width: new.size.width, height: new.size.height))
            }
            return true
        }
        return result
    }

    /// Composite `new` to the right/left of `base` with `offset` points of new content.
    /// `append` = true: new content on the right (rightward scroll).
    private func compositeHorizontal(base: NSImage, new: NSImage, offset: CGFloat, append: Bool) -> NSImage? {
        let totalW = base.size.width + offset
        let size = NSSize(width: totalW, height: base.size.height)
        let result = NSImage(size: size, flipped: false) { _ in
            if append {
                base.draw(in: CGRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
                new.draw(in: CGRect(x: totalW - new.size.width, y: 0, width: new.size.width, height: new.size.height))
            } else {
                base.draw(in: CGRect(x: totalW - base.size.width, y: 0, width: base.size.width, height: base.size.height))
                new.draw(in: CGRect(x: 0, y: 0, width: new.size.width, height: new.size.height))
            }
            return true
        }
        return result
    }

    private enum Edge { case bottom, right }

    /// Remove `amount` points from the specified edge.
    private func cropEdge(of image: NSImage, by amount: CGFloat, direction: Edge) -> NSImage? {
        switch direction {
        case .bottom:
            let newH = image.size.height - amount
            guard newH > 0 else { return image }
            let size = NSSize(width: image.size.width, height: newH)
            let result = NSImage(size: size, flipped: false) { _ in
                image.draw(in: NSRect(origin: .zero, size: size),
                           from: NSRect(x: 0, y: amount, width: image.size.width, height: newH),
                           operation: .copy, fraction: 1)
                return true
            }
            return result
        case .right:
            let newW = image.size.width - amount
            guard newW > 0 else { return image }
            let size = NSSize(width: newW, height: image.size.height)
            let result = NSImage(size: size, flipped: false) { _ in
                image.draw(in: NSRect(origin: .zero, size: size),
                           from: NSRect(x: 0, y: 0, width: newW, height: image.size.height),
                           operation: .copy, fraction: 1)
                return true
            }
            return result
        }
    }

    private func copyToCPUBacked(_ src: CGImage) -> CGImage? {
        let w = src.width, h = src.height
        let cs         = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: bitmapInfo) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Deliver result

    private func deliverResult() {
        guard let img = runningStitched else { onSessionDone?(nil); return }
        onSessionDone?(img)
    }
}

// MARK: - Single-frame handler for scroll capture strips

private final class ScrollStripFrameHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var capturedImage: CGImage?
    private var delivered = false
    private let lock = NSLock()

    func waitForFrame() async -> CGImage? {
        await withCheckedContinuation { cont in
            lock.lock()
            if delivered {
                let image = capturedImage
                lock.unlock()
                cont.resume(returning: image)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // Skip frames without valid image data (blank, idle, suspended)
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let cgImage = context.createCGImage(ciImage, from: ciImage.extent)

        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        capturedImage = cgImage
        let cont = continuation
        continuation = nil
        lock.unlock()

        cont?.resume(returning: cgImage)
    }
}
