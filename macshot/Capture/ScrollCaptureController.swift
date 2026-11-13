import Cocoa
import OSLog
import ScreenCaptureKit

// MARK: - ScrollCaptureController

/// Scroll capture engine:
///
/// - **`CGWindowListCreateImage`** for on-demand frame capture — each grab is a
///   complete, compositor-finished snapshot. No stream management, no stale frames.
/// - **Pixel buffer comparison** between compositor refreshes, without encoding screenshots.
/// - **Bounded frame settlement** before matching, with a fallback for animated pages.
/// - **Incremental stitching** — `ScrollStitcher` appends only the new rows of
///   each frame, keeping memory bounded (no storing all raw strips).
/// - **Row matching that ignores what doesn't scroll** — `ScrollFrameMatcher`
///   aligns only the columns that move, cancels fixed backgrounds and leaves out
///   navbars (opaque or translucent) and pinned banners.
/// - **Separate end detection and alignment failure** for automatic scrolling.
/// - **Programmatic scrolling** via `CGEventCreateScrollWheelEvent2`.
/// - **Sticky content appears once** — new rows are taken from just above a
///   pinned bottom banner, so headers stay at the top and banners at the end;
///   fixed sidebars beside the scrolling column are cropped away.
/// - **Continuous grabs while scrolling** — frames are taken every 50 ms during
///   a scroll, so a mouse wheel's large silent jumps can't outrun the overlap.
/// - **Max height: 30,000 pixels** (configurable via UserDefaults).
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive: Bool = false
    private var isCancelled: Bool = false

    /// Current estimated total height of the final image (points).
    var estimatedTotalHeight: CGFloat {
        guard let merged = stitcher?.image else { return 0 }
        return CGFloat(merged.height) / backingScale
    }

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?
    var onAutoScrollStarted: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []
    var captureAnchorWindowID: CGWindowID = kCGNullWindowID

    // MARK: - Settings

    private var autoScrollEnabled: Bool = false
    private var autoScrollSpeed: Int = 3
    private var maxScrollHeight: Int = 30000
    private var frozenDetectionEnabled: Bool = true

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let backingScale: CGFloat

    // Read captured pixel buffers off the main thread.
    private let captureQueue = DispatchQueue(label: "macshot.scrollcapture", qos: .userInitiated)

    private var stitcher: ScrollStitcher?
    private static let log = Logger(subsystem: "com.sw33tlie.macshot", category: "ScrollCapture")

    // Scroll monitors (for manual scroll)
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Auto-scroll
    private(set) var autoScrollActive: Bool = false
    private var autoScrollTask: Task<Void, Never>?

    // Manual scroll throttle
    private let manualCaptureInterval: TimeInterval = 0.05
    private var lastScrollEventTime: TimeInterval = 0
    private var burstTimer: Timer?
    /// Keep grabbing this long after the last scroll event: a mouse wheel's
    /// smooth-scroll animation keeps moving the page without further events.
    private let burstTail: TimeInterval = 0.6
    private var pendingCaptureTask: Task<Void, Never>?
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.25

    // Guard: only one capture at a time
    private var isCapturing: Bool = false

    // Target app for scroll events
    private var targetAppPID: pid_t = 0

    // CGWindowList capture config
    private var targetWindowID: CGWindowID = kCGNullWindowID
    private var captureRectCG: CGRect = .zero  // CG coordinates (top-left origin)

    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    func startSession() async {
        guard !isActive, !isCancelled else { return }

        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? 30000
        frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        // Convert AppKit coords to CG coords (top-left origin) for CGWindowListCreateImage
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        captureRectCG = CGRect(
            x: captureRect.origin.x,
            y: primaryScreenH - captureRect.maxY,
            width: captureRect.width,
            height: captureRect.height
        )

        // Find the target window under the capture region
        resolveTargetWindow()
        resolveTargetApp()

        // Capture first settled frame
        guard let firstFrame = await captureSettledFrame()?.image else {
            if !isCancelled { onSessionDone?(nil) }
            return
        }
        guard !isCancelled else { return }

        isActive = true
        stitcher = ScrollStitcher(firstFrame: firstFrame, handlesPinnedContent: frozenDetectionEnabled)
        stripCount = 1

        stitchedImage = firstFrame
        stitchedPixelSize = CGSize(width: CGFloat(firstFrame.width), height: CGFloat(firstFrame.height))
        emitPreview()
        onStripAdded?(stripCount)

        if autoScrollEnabled {
            startAutoScroll()
        } else {
            startManualScrollMonitors()
        }
    }

    private var didDeliver = false

    func stopSession() {
        finishSession(at: nil)
    }

    private func finishSession(at settledEnd: CGImage?) {
        // The HUD (and its Stop button) is on screen before `isActive` becomes
        // true — startSession first awaits a settled frame, which can take a
        // couple of seconds on a page with a blinking caret or a clock. A stop
        // in that window used to do nothing at all, and the session then
        // installed its scroll monitors anyway.
        // Delivers at most once: Stop, Return and ⌘C can all arrive for the
        // same session, and a second stop must not report an empty result.
        guard !didDeliver, isActive || !isCancelled else { return }
        didDeliver = true
        guard isActive else {
            isCancelled = true
            onSessionDone?(nil)
            return
        }
        isActive = false

        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        burstTimer?.invalidate(); burstTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false

        // Deliver final image
        let finalImage: NSImage?
        if let cg = stitcher?.finish(at: settledEnd) {
            let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                                height: CGFloat(cg.height) / backingScale)
            finalImage = NSImage(cgImage: cg, size: ptSize)
        } else {
            finalImage = nil
        }
        onSessionDone?(finalImage)
    }

    func cancelSession() {
        // Cancellation is also valid while the initial settled frame is being
        // captured, before `isActive` becomes true. The cancelled flag keeps
        // that asynchronous startup from installing monitors after the UI has
        // already been dismissed.
        isCancelled = true
        isActive = false

        autoScrollTask?.cancel(); autoScrollTask = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        burstTimer?.invalidate(); burstTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false
    }

    // MARK: - Target window/app management

    /// Finds the window ID under the capture region center for targeted capture.
    private func resolveTargetWindow() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetWindowID = CGWindowID(winID)
                return
            }
        }
    }

    private func resolveTargetApp() {
        let centerX = captureRectCG.midX
        let centerY = captureRectCG.midY

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let excluded = Set(excludedWindowIDs)
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  !excluded.contains(CGWindowID(winID))
            else { continue }

            let x = boundsDict["X"] ?? 0
            let y = boundsDict["Y"] ?? 0
            let w = boundsDict["Width"] ?? 0
            let h = boundsDict["Height"] ?? 0
            let cgRect = CGRect(x: x, y: y, width: w, height: h)

            if cgRect.contains(CGPoint(x: centerX, y: centerY)) {
                targetAppPID = pid
                return
            }
        }
    }

    private func activateTargetApp() {
        guard targetAppPID != 0 else { return }
        NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
    }

    // MARK: - Frame capture via CGWindowListCreateImage

    /// Captures the screen region using CGWindowListCreateImage.
    /// Returns a complete, compositor-finished snapshot — no stream management needed.
    private func captureFrame() -> CGImage? {
        let listOption: CGWindowListOption = [.optionOnScreenBelowWindow]

        let imageOption: CGWindowImageOption = [.boundsIgnoreFraming]

        guard let image = CGWindowListCreateImage(
            captureRectCG, listOption, captureAnchorWindowID, imageOption
        ) else { return nil }

        return image
    }

    private struct CapturedFrame {
        let image: CGImage
        let pixels: Data?

        func matches(_ other: CapturedFrame) -> Bool {
            guard let pixels, let otherPixels = other.pixels else { return false }
            return image.width == other.image.width && image.height == other.image.height
                && image.bytesPerRow == other.image.bytesPerRow
                && image.bitsPerComponent == other.image.bitsPerComponent
                && image.bitsPerPixel == other.image.bitsPerPixel
                && image.bitmapInfo == other.image.bitmapInfo && pixels == otherPixels
        }
    }

    /// Prefer a settled frame, but retain the latest usable frame for pages that keep rendering.
    private func captureSettledFrame(attempts: Int = 30) async -> CapturedFrame? {
        var previous: CapturedFrame?
        var waitNs: UInt64 = 24_000_000

        for attempt in 0..<attempts {
            guard !isCancelled, !Task.isCancelled else { return nil }
            if let image = captureFrame() {
                let pixels: Data? = await withCheckedContinuation { continuation in
                    captureQueue.async {
                        continuation.resume(returning: image.dataProvider?.data.map { $0 as Data })
                    }
                }
                guard !isCancelled, !Task.isCancelled else { return nil }
                let frame = CapturedFrame(image: image, pixels: pixels)
                if let previous, frame.matches(previous) { return frame }
                previous = frame
            }

            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: waitNs)
                waitNs = min(waitNs * 3 / 2, 80_000_000)
            }
        }

        return previous
    }

    // MARK: - Auto-scroll

    private func startAutoScroll() {
        autoScrollActive = true
        onAutoScrollStarted?()

        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cursorX = captureRect.midX
        let cursorY = primaryScreenH - captureRect.midY
        CGWarpMouseCursorPosition(CGPoint(x: cursorX, y: cursorY))

        activateTargetApp()

        // Keep most of the previous viewport available for matching at every speed.
        let fraction: CGFloat
        switch autoScrollSpeed {
        case 1: fraction = 0.10
        case 2: fraction = 0.18
        case 4: fraction = 0.40
        default: fraction = 0.28
        }
        let step = Int32(max(1, (captureRect.height * fraction).rounded(.down)))

        autoScrollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self = self, self.isActive, self.autoScrollActive else { return }
            await self.autoScrollLoop(step: step)
        }
    }

    private func autoScrollLoop(step: Int32) async {
        var previousFrame: CapturedFrame?
        var previousOutcome: ScrollStitcher.Outcome?
        var stationaryCycles = 0
        var pendingCycles = 0
        var failedCycles = 0
        var cyclesWithoutGrowth = 0
        var forwardStep = step
        let startedAt = ProcessInfo.processInfo.systemUptime
        Self.log.info("Auto-scroll started: \(step) point steps")

        while isActive && autoScrollActive && !Task.isCancelled {
            // Wait before posting wheel events so an in-flight manual capture
            // cannot leave us scrolling several times without taking a frame.
            if isCapturing {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            isCapturing = true
            let probingForward = failedCycles == 0
            if probingForward {
                postScroll(delta: -forwardStep)
            } else if failedCycles.isMultiple(of: 2), forwardStep > 1 {
                // Retry in place first. Then undo progressively smaller parts
                // of the last step to regain overlap with the accepted frame.
                forwardStep /= 2
                postScroll(delta: forwardStep)
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
            let frame = await captureSettledFrame(attempts: 8)
            isCapturing = false
            guard isActive, autoScrollActive, !Task.isCancelled else { return }

            cyclesWithoutGrowth += 1
            if let frame {
                let unchanged = previousFrame.map { frame.matches($0) } ?? false
                previousFrame = frame
                // A stable tail can still be offset from the last stitched frame.
                // Try to append even a few final rows before counting a stop.
                let previousHeight = stitcher?.image.height ?? 0
                let outcome: ScrollStitcher.Outcome
                if unchanged, previousOutcome == .noMovement {
                    outcome = .noMovement
                } else {
                    outcome = process(frame.image, includeSmallShift: unchanged || pendingCycles >= 5,
                                      allowReanchoring: false)
                }
                previousOutcome = outcome
                if (stitcher?.image.height ?? 0) > previousHeight { cyclesWithoutGrowth = 0 }
                stationaryCycles = probingForward && unchanged && outcome == .noMovement ? stationaryCycles + 1 : 0
                pendingCycles = outcome == .pending ? pendingCycles + 1 : 0
                failedCycles = outcome == .noMatch ? failedCycles + 1 : 0
            } else {
                stationaryCycles = 0
                pendingCycles = 0
                previousFrame = nil
                previousOutcome = nil
                failedCycles += 1
            }

            let reason: String
            if failedCycles >= 8 {
                reason = "alignment or frame capture failed"
            } else if stationaryCycles >= 6, failedCycles == 0 {
                reason = "page stopped moving"
            } else if pendingCycles >= 12 || cyclesWithoutGrowth >= 20 {
                reason = "no new rows could be appended"
            } else if maxScrollHeight > 0, let image = stitcher?.image, image.height >= maxScrollHeight {
                reason = "height limit reached"
            } else {
                try? await Task.sleep(nanoseconds: 10_000_000)
                continue
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let height = stitcher?.image.height ?? 0
            Self.log.info("Auto-scroll ended: \(reason, privacy: .public), \(height) px, \(elapsed, format: .fixed(precision: 2)) s")
            finishSession(at: stationaryCycles >= 6 ? previousFrame?.image : nil)
            return
        }
    }

    private func postScroll(delta: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: delta, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    // MARK: - Stitching

    /// Feeds a frame to the stitcher and reports new strips.
    /// The mouse pointer's area in a captured frame (pixels, top-left origin),
    /// generous enough for the large accessibility pointer sizes.
    private func pointerRect(in frame: CGImage) -> CGRect? {
        let mouse = NSEvent.mouseLocation
        guard captureRect.insetBy(dx: -40, dy: -40).contains(mouse) else { return nil }
        let scale = CGFloat(frame.width) / max(1, captureRect.width)
        let x = (mouse.x - captureRect.minX) * scale, y = (captureRect.maxY - mouse.y) * scale
        // The hotspot is the arrow's tip: the pointer extends down and right.
        return CGRect(x: x - 8 * scale, y: y - 8 * scale, width: 48 * scale, height: 56 * scale)
    }

    private func process(_ frame: CGImage, includeSmallShift: Bool = false,
                         allowReanchoring: Bool = true) -> ScrollStitcher.Outcome {
        guard let stitcher else { return .noMatch }
        let outcome = stitcher.add(frame, pointer: pointerRect(in: frame), includeSmallShift: includeSmallShift,
                                   allowReanchoring: allowReanchoring)
        if outcome == .appended {
            stripCount += 1
            stitchedImage = stitcher.image
            stitchedPixelSize = CGSize(width: CGFloat(stitcher.image.width), height: CGFloat(stitcher.image.height))
            emitPreview()
            onStripAdded?(stripCount)
        }
        return outcome
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTask?.cancel(); autoScrollTask = nil
    }

    func toggleAutoScroll() {
        guard isActive else { return }
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors()
        } else {
            if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
            if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
            settlementTimer?.invalidate(); settlementTimer = nil
            burstTimer?.invalidate(); burstTimer = nil
            pendingCaptureTask?.cancel(); pendingCaptureTask = nil
            startAutoScroll()
        }
    }

    // MARK: - Manual scroll

    private func startManualScrollMonitors() {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.onManualScrollEvent()
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent()
            return event
        }
    }

    /// A trackpad sends a stream of scroll events, but a mouse wheel sends one
    /// per notch and then animates the page silently. Grabbing only on events
    /// let a fast wheel move the page past the overlap between grabs (#484), so
    /// keep grabbing on a timer until the page has been still for a moment.
    private func onManualScrollEvent() {
        guard isActive, !autoScrollActive else { return }
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        lastScrollEventTime = ProcessInfo.processInfo.systemUptime
        settlementTimer?.invalidate(); settlementTimer = nil
        guard burstTimer == nil else { return }
        grabAndProcess()
        burstTimer = Timer.scheduledTimer(withTimeInterval: manualCaptureInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { timer.invalidate(); return }
                if ProcessInfo.processInfo.systemUptime - self.lastScrollEventTime > self.burstTail {
                    timer.invalidate()
                    self.burstTimer = nil
                    // After scrolling stops, a final settled capture.
                    self.settlementTimer = Timer.scheduledTimer(withTimeInterval: self.settlementInterval,
                                                                repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.isActive, !self.autoScrollActive else { return }
                            self.pendingCaptureTask = Task { @MainActor [weak self] in
                                await self?.settledCapture()
                                if !Task.isCancelled { self?.pendingCaptureTask = nil }
                            }
                        }
                    }
                    return
                }
                self.grabAndProcess()
            }
        }
    }

    /// Immediate frame grab + process during active scrolling.
    private func grabAndProcess() {
        guard isActive, !autoScrollActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        guard let currentFrame = captureFrame() else { return }
        _ = process(currentFrame)
    }

    /// Final settled capture after scrolling stops.
    private func settledCapture() async {
        guard isActive, !autoScrollActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let frame = await captureSettledFrame(), isActive, !autoScrollActive,
              !Task.isCancelled else { return }
        _ = process(frame.image)
    }

    // MARK: - Preview

    private func emitPreview() {
        guard let cg = stitcher?.image, let callback = onPreviewUpdated else { return }
        let ptSize = CGSize(width: CGFloat(cg.width) / backingScale,
                            height: CGFloat(cg.height) / backingScale)
        callback(NSImage(cgImage: cg, size: ptSize))
    }
}
