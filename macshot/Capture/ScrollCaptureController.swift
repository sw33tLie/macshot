import Cocoa
import ScreenCaptureKit
import Vision

// MARK: - ScrollCaptureController

/// Manages a scroll-capture session with:
/// - **Auto-scroll** via synthetic CGEvent scroll wheel events (controlled pace, consistent frames)
/// - **Frozen region detection** — identifies fixed/sticky headers that don't move between frames
///   and excludes them from the stitched output (only keeps one copy at the top)
/// - **Multi-tier shift detection** — Vision `VNTranslationalImageRegistrationRequest` as primary,
///   pixel-row SAD (Sum of Absolute Differences) as fallback when Vision fails
/// - **Batch stitching** — stores all frames + computed offsets, combines in a single pass at the end
///   for pixel-perfect accuracy (no error accumulation from incremental compositing)
/// - **Configurable** max scroll height, scroll speed, frozen header detection toggle
@MainActor
final class ScrollCaptureController {

    // MARK: - Public state

    private(set) var stripCount: Int = 0
    private(set) var stitchedImage: CGImage?
    private(set) var stitchedPixelSize: CGSize = .zero
    private(set) var isActive: Bool = false
    private(set) var frozenTopHeight: CGFloat = 0  // detected frozen header height in points

    /// Current estimated total height of the final image (points).
    var estimatedTotalHeight: CGFloat {
        guard !capturedStrips.isEmpty else { return 0 }
        let stripH = capturedStrips[0].pointSize.height
        let scrolledContentPx = stripOffsetsPx.reduce(0, +)
        let scrolledContentPt = CGFloat(scrolledContentPx) / backingScale
        return frozenTopHeight + (stripH - frozenTopHeight) + scrolledContentPt
    }

    // MARK: - Callbacks

    var onStripAdded:  ((Int) -> Void)?
    var onSessionDone: ((NSImage?) -> Void)?
    var onAutoScrollStarted: (() -> Void)?
    var onPreviewUpdated: ((NSImage) -> Void)?

    // MARK: - Config

    var excludedWindowIDs: [CGWindowID] = []

    // MARK: - Settings (read from UserDefaults at session start)

    private var autoScrollEnabled: Bool = false
    private var autoScrollSpeed: Int = 3         // 1=slow, 2=medium, 3=fast, 4=very fast
    private var maxScrollHeight: Int = 20000     // max pixel height (0 = unlimited)
    private var frozenDetectionEnabled: Bool = true

    // MARK: - Private

    private let captureRect: NSRect
    private let screen: NSScreen
    private let backingScale: CGFloat

    private var scDisplay: SCDisplay?
    private var excludedSCWindows: [SCWindow] = []
    private var scSourceRect: CGRect = .zero

    // Scroll monitors (for manual scroll fallback)
    private var scrollMonitorGlobal: Any?
    private var scrollMonitorLocal:  Any?

    // Auto-scroll
    private var autoScrollTimer: Timer?
    private(set) var autoScrollActive: Bool = false

    // Capture timer (fires at controlled intervals during auto-scroll)
    private var captureTimer: Timer?
    private let captureInterval: TimeInterval = 0.04  // ~25 fps for fast scroll tracking

    // Manual scroll: throttle + settlement (kept as fallback when auto-scroll is off)
    private let manualCaptureInterval: TimeInterval = 0.15
    private var lastCaptureTime: TimeInterval = 0
    private var pendingCaptureTask: Task<Void, Never>?
    private var settlementTimer: Timer?
    private let settlementInterval: TimeInterval = 0.20

    // Guard: only one capture at a time
    private var isCapturing: Bool = false

    // Direction: auto-detected on first stitch, then locked
    enum ScrollDirection { case unknown, vertical, horizontal }
    private(set) var scrollDirection: ScrollDirection = .unknown

    // Batch stitching: store all frames + their offsets
    private struct CapturedStrip {
        let image: CGImage
        let pointSize: CGSize  // size in points
    }
    private var capturedStrips: [CapturedStrip] = []
    private var stripOffsetsPx: [Int] = []     // offset[i] = new content pixels in strip i vs strip i-1
    private var previousStripCG: CGImage?      // last CAPTURED strip (for live comparison)
    private var lastStoredStripCG: CGImage?     // last STORED strip (for offset calculation)

    // Frozen region detection
    private var frozenTopPixels: Int = 0       // frozen region height in pixels
    private var frozenDetectionDone: Bool = false
    private var frozenDetectionSamples: Int = 0

    // Stop detection for auto-scroll
    private var consecutiveZeroShifts: Int = 0
    private let maxZeroShiftsBeforeStop: Int = 6  // stop after 6 frames with no detected movement
    private var hasScrolledOnce: Bool = false      // don't count zero-shifts until first real shift seen

    // Target app for scroll events
    private var targetAppPID: pid_t = 0

    // Persistent capture stream — kept running throughout the session for instant, fresh frames
    private var persistentStream: PersistentFrameStream?


    // MARK: - Init

    init(captureRect: NSRect, screen: NSScreen) {
        self.captureRect = captureRect
        self.screen      = screen
        self.backingScale = screen.backingScaleFactor
    }

    // MARK: - Session

    func startSession() async {
        guard !isActive else { return }

        // Read settings
        let ud = UserDefaults.standard
        autoScrollEnabled = ud.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        autoScrollSpeed = ud.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        maxScrollHeight = ud.object(forKey: "scrollMaxHeight") as? Int ?? 20000
        frozenDetectionEnabled = ud.object(forKey: "scrollFrozenDetection") as? Bool ?? true

        // Discover display + excluded windows
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

        // Find the target app under the capture region for re-activation during auto-scroll
        resolveTargetApp()

        // Start persistent capture stream for the entire session — avoids stale first-frame
        // artifacts (black lines) from spinning up a new SCStream for each capture
        let persistent = PersistentFrameStream()
        self.persistentStream = persistent
        let streamStarted = await persistent.start(
            display: scDisplay!, excludedWindows: excludedSCWindows,
            sourceRect: scSourceRect, captureSize: CGSize(
                width: captureRect.width * backingScale,
                height: captureRect.height * backingScale),
            backingScale: backingScale)
        guard streamStarted else { onSessionDone?(nil); return }

        // Wait briefly for the stream to deliver its first few frames (discard initial stale frames)
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Capture first strip from the running stream
        guard let firstCG = await captureStrip() else {
            await persistent.stop()
            onSessionDone?(nil)
            return
        }
        let firstPtSize = CGSize(width: CGFloat(firstCG.width) / backingScale,
                                 height: CGFloat(firstCG.height) / backingScale)

        isActive = true
        scrollDirection = .unknown
        frozenTopHeight = 0
        frozenTopPixels = 0
        frozenDetectionDone = false
        frozenDetectionSamples = 0
        consecutiveZeroShifts = 0
        hasScrolledOnce = false

        capturedStrips = [CapturedStrip(image: firstCG, pointSize: firstPtSize)]
        stripOffsetsPx = []
        previousStripCG = firstCG
        lastStoredStripCG = firstCG
        stripCount = 1
        updateLivePreview()
        onStripAdded?(stripCount)

        if autoScrollEnabled {
            startAutoScroll()
        } else {
            startManualScrollMonitors()
        }
    }

    func stopSession() {
        guard isActive else { return }
        isActive = false

        // Stop timers & monitors
        autoScrollTimer?.invalidate(); autoScrollTimer = nil
        captureTimer?.invalidate(); captureTimer = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false

        // Stop persistent stream
        Task { await persistentStream?.stop() }
        persistentStream = nil

        // Batch stitch and deliver
        let finalImage = batchStitch()
        onSessionDone?(finalImage)
    }

    /// Cancels the session without delivering a result.
    func cancelSession() {
        guard isActive else { return }
        isActive = false

        autoScrollTimer?.invalidate(); autoScrollTimer = nil
        captureTimer?.invalidate(); captureTimer = nil
        settlementTimer?.invalidate(); settlementTimer = nil
        pendingCaptureTask?.cancel(); pendingCaptureTask = nil
        if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
        if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
        autoScrollActive = false

        Task { await persistentStream?.stop() }
        persistentStream = nil
    }

    // MARK: - Target app management

    /// Finds the PID of the app window under the capture region center.
    private func resolveTargetApp() {
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // Convert AppKit global coords to CG (top-left origin)
        let cgCenterX = captureRect.midX
        let cgCenterY = primaryScreenH - captureRect.midY

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

            if cgRect.contains(CGPoint(x: cgCenterX, y: cgCenterY)) {
                targetAppPID = pid
                return
            }
        }
    }

    /// Activates the target app so scroll events reach the right window.
    private func activateTargetApp() {
        guard targetAppPID != 0 else { return }
        NSRunningApplication(processIdentifier: targetAppPID)?.activate(options: [])
    }

    // MARK: - Auto-scroll

    private func startAutoScroll() {
        autoScrollActive = true
        onAutoScrollStarted?()

        // Scroll speed: lines per event (line units work reliably across apps including Chrome)
        let linesPerTick: Int32
        switch autoScrollSpeed {
        case 1: linesPerTick = 1
        case 2: linesPerTick = 1
        case 4: linesPerTick = 2
        default: linesPerTick = 1  // default (speed 3)
        }

        // Position cursor in the center of the capture region so scroll events target the right window.
        // CGWarpMouseCursorPosition uses CG (Quartz) global coordinates: top-left origin on primary display.
        let primaryScreenH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cursorX = captureRect.midX
        let cursorY = primaryScreenH - captureRect.midY
        CGWarpMouseCursorPosition(CGPoint(x: cursorX, y: cursorY))

        // Re-activate the target app so scroll events reach the right window
        activateTargetApp()

        // Small delay to let the cursor warp and app activation take effect, then start scroll cycle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.isActive else { return }
            self.runScrollCaptureCycle(linesPerTick: linesPerTick, scrollBursts: 3)
        }
    }

    /// Scroll → settle → capture cycle. Posts a burst of scroll events, waits for the
    /// content to settle, captures a frame, then repeats.
    private func runScrollCaptureCycle(linesPerTick: Int32, scrollBursts: Int) {
        guard isActive, autoScrollActive else { return }

        // Post a burst of scroll events
        for _ in 0..<scrollBursts {
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                   wheel1: -linesPerTick, wheel2: 0, wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }
        }

        // Wait briefly for content to render after scroll, then capture
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self = self, self.isActive, self.autoScrollActive else { return }
            Task { @MainActor in
                await self.captureAndProcess()
                // Schedule next cycle immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.runScrollCaptureCycle(linesPerTick: linesPerTick, scrollBursts: scrollBursts)
                }
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollActive = false
        autoScrollTimer?.invalidate(); autoScrollTimer = nil
        captureTimer?.invalidate(); captureTimer = nil
    }

    func toggleAutoScroll() {
        if autoScrollActive {
            stopAutoScroll()
            startManualScrollMonitors()
        } else {
            // Stop manual monitors
            if let m = scrollMonitorGlobal { NSEvent.removeMonitor(m); scrollMonitorGlobal = nil }
            if let m = scrollMonitorLocal  { NSEvent.removeMonitor(m); scrollMonitorLocal  = nil }
            settlementTimer?.invalidate(); settlementTimer = nil
            startAutoScroll()
        }
    }

    // MARK: - Manual scroll (fallback)

    private func startManualScrollMonitors() {
        scrollMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.onManualScrollEvent()
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.onManualScrollEvent()
            return event
        }
    }

    private func onManualScrollEvent() {
        guard isActive else { return }

        settlementTimer?.invalidate()
        settlementTimer = Timer.scheduledTimer(withTimeInterval: settlementInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in await self.captureAndProcess() }
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCaptureTime >= manualCaptureInterval else { return }
        lastCaptureTime = now

        pendingCaptureTask?.cancel()
        pendingCaptureTask = Task { [weak self] in
            await self?.captureAndProcess()
        }
    }

    // MARK: - Core capture & process

    private func captureAndProcess() async {
        guard isActive, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let cgStrip = await captureStrip() else { return }
        // Compare against the last STORED strip (not last captured), so small shifts
        // accumulate until there's enough new content to store a frame.
        guard let refCG = lastStoredStripCG else { return }

        let ptSize = CGSize(width: CGFloat(cgStrip.width) / backingScale,
                            height: CGFloat(cgStrip.height) / backingScale)

        // Detect shift vs last stored strip
        guard let offset = detectShift(current: cgStrip, previous: refCG) else {
            // No shift detected — only count toward stop AFTER we've seen real movement,
            // and only if the cursor is inside the capture region (not hovering over the HUD).
            if hasScrolledOnce && autoScrollActive {
                let mouse = NSEvent.mouseLocation  // AppKit global coords
                if captureRect.contains(mouse) {
                    consecutiveZeroShifts += 1
                    if consecutiveZeroShifts >= maxZeroShiftsBeforeStop {
                        stopSession()
                    }
                }
            }
            return
        }

        let offsetPx = Int(round(offset))
        let stripHeightPx = cgStrip.height

        // Minimum shift to store a strip: at least 10% of strip height in pixels.
        // Below this, skip — the shift accumulates as we keep comparing against the last stored strip.
        let minShiftPx = stripHeightPx / 10

        // For direction detection, even small shifts count
        if scrollDirection == .unknown {
            if abs(offsetPx) > 2 {
                scrollDirection = .vertical
                hasScrolledOnce = true
                consecutiveZeroShifts = 0
            }
            if abs(offsetPx) < minShiftPx { return }
        }

        // Skip backward scrolling
        guard offsetPx > 0 else { return }

        // Not enough new content yet — wait for more scrolling
        if offsetPx < minShiftPx { return }

        consecutiveZeroShifts = 0
        hasScrolledOnce = true

        // Frozen region detection (first few frames after first stored strip)
        if frozenDetectionEnabled && !frozenDetectionDone && capturedStrips.count >= 1 {
            detectFrozenRegion(current: cgStrip, previous: refCG, shiftPixels: offset)
        }

        // Store strip + pixel-exact offset
        capturedStrips.append(CapturedStrip(image: cgStrip, pointSize: ptSize))
        stripOffsetsPx.append(offsetPx)
        lastStoredStripCG = cgStrip
        previousStripCG = cgStrip
        stripCount = capturedStrips.count
        updateLivePreview()
        onStripAdded?(stripCount)

        // Check max height limit
        if maxScrollHeight > 0 {
            let currentHeightPx = estimatedTotalHeight * backingScale
            if currentHeightPx >= CGFloat(maxScrollHeight) {
                stopSession()
                return
            }
        }
    }

    // MARK: - Shift detection (multi-tier)

    /// Returns the vertical shift in **pixels** (positive = scrolled down), or nil if no shift detected.
    /// Uses Vision for coarse estimate, then refines at pixel level to eliminate stitch seams.
    private func detectShift(current: CGImage, previous: CGImage) -> CGFloat? {
        // Tier 1: Vision-based translational registration (coarse)
        if let visionShift = visionTranslationShift(current: current, previous: previous) {
            let absShift = abs(visionShift)
            if absShift > 2 && absShift < CGFloat(current.height) * 0.95 {
                // Refine at pixel level: search ±4px around Vision's estimate
                let coarse = Int(round(visionShift))
                if let refined = refineShift(current: current, previous: previous, estimate: coarse, searchRadius: 4) {
                    return CGFloat(refined)
                }
                return CGFloat(coarse)
            }
        }

        // Tier 2: Pixel-row SAD fallback (already pixel-accurate)
        if let sadShift = pixelRowSADShift(current: current, previous: previous) {
            let absShift = abs(sadShift)
            if absShift > 2 && absShift < CGFloat(current.height) * 0.95 {
                return sadShift
            }
        }

        return nil
    }

    /// Robust row-matching for stitch-time refinement. Takes a wide reference band from the
    /// middle of `previous` and finds the exact position in `current` where it matches best.
    /// Uses every pixel for maximum accuracy. Returns nil if no good match found.
    private func exactRowMatch(current: CGImage, previous: CGImage, estimate: Int) -> Int? {
        guard current.width == previous.width, current.height == previous.height else { return nil }
        let w = current.width
        let h = current.height
        guard estimate > 10 && estimate < h - 10 else { return nil }
        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return nil }

        let bytesPerRow = w * 4

        // Take a reference band of 16 rows from the middle of the overlap region in `previous`.
        // The overlap region is the bottom `estimate` rows of previous = top `h - estimate` rows of current.
        // Middle of that overlap: row (h - estimate/2) in previous coords.
        let bandRows = 16
        let refCenter = h - estimate / 2
        let refStart = max(0, refCenter - bandRows / 2)
        guard refStart + bandRows < h else { return nil }

        // Search ±12 pixels around the coarse estimate
        let searchRadius = 12
        var bestShift = estimate
        var bestSAD: UInt64 = .max

        for candidate in max(1, estimate - searchRadius)...min(h - bandRows - 1, estimate + searchRadius) {
            var sad: UInt64 = 0
            var samples: Int = 0
            for b in 0..<bandRows {
                let prevRow = refStart + b
                let curRow = prevRow - candidate
                guard curRow >= 0 && curRow < h else { continue }

                let prevOff = prevRow * bytesPerRow
                let curOff = curRow * bytesPerRow

                // Compare every pixel
                for col in stride(from: 0, to: w * 4, by: 4) {
                    sad += UInt64(abs(Int(prevData[prevOff + col]) - Int(curData[curOff + col]))
                               + abs(Int(prevData[prevOff + col + 1]) - Int(curData[curOff + col + 1]))
                               + abs(Int(prevData[prevOff + col + 2]) - Int(curData[curOff + col + 2])))
                    samples += 1
                }
            }
            guard samples > 0 else { continue }
            let normalizedSAD = sad / UInt64(samples)
            if normalizedSAD < bestSAD {
                bestSAD = normalizedSAD
                bestShift = candidate
            }
        }

        // Only accept if the match is very good (< 5 average difference per channel per pixel)
        guard bestSAD < 5 else { return nil }
        return bestShift
    }

    /// Pixel-level refinement: given a coarse shift estimate, compare a wide band of rows
    /// in the middle of the overlap region for each candidate in [estimate - radius ... estimate + radius].
    /// Returns the shift with the lowest SAD (best pixel match).
    private func refineShift(current: CGImage, previous: CGImage, estimate: Int, searchRadius: Int) -> Int? {
        guard current.width == previous.width, current.height == previous.height else { return nil }
        let w = current.width
        let h = current.height
        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return nil }

        let bytesPerRow = w * 4
        // Use a wide band (20 rows) from the middle of the overlap for robust matching.
        // Avoid the very edge rows which may have sub-frame rendering artifacts.
        let bandRows = min(20, max(estimate / 2, 8))
        let edgeMargin = 4  // skip bottom 4 rows of previous to avoid edge artifacts

        var bestShift = estimate
        var bestSAD: UInt64 = .max

        let lo = max(1, estimate - searchRadius)
        let hi = min(h - bandRows - edgeMargin - 1, estimate + searchRadius)
        guard lo <= hi else { return nil }

        for candidate in lo...hi {
            // Compare rows from the middle of the overlap, not the very edge.
            // prev rows [h - candidate - edgeMargin - bandRows ..< h - candidate - edgeMargin]
            // should match curr rows [h - candidate - edgeMargin - bandRows - candidate ..< ...]
            // Simpler: prev row R should match curr row (R - candidate).
            var sad: UInt64 = 0
            var samples: Int = 0
            let bandStart = h - candidate - edgeMargin - bandRows
            for b in 0..<bandRows {
                let prevRow = bandStart + b
                let curRow = prevRow - candidate
                guard prevRow >= 0 && prevRow < h && curRow >= 0 && curRow < h else { continue }

                let prevOff = prevRow * bytesPerRow
                let curOff = curRow * bytesPerRow

                // Compare every pixel for accuracy
                for col in stride(from: 0, to: w * 4, by: 4) {
                    let pR = Int(prevData[prevOff + col])
                    let pG = Int(prevData[prevOff + col + 1])
                    let pB = Int(prevData[prevOff + col + 2])
                    let cR = Int(curData[curOff + col])
                    let cG = Int(curData[curOff + col + 1])
                    let cB = Int(curData[curOff + col + 2])
                    sad += UInt64(abs(pR - cR) + abs(pG - cG) + abs(pB - cB))
                    samples += 1
                }
            }
            guard samples > 0 else { continue }
            let normalizedSAD = sad / UInt64(samples)
            if normalizedSAD < bestSAD {
                bestSAD = normalizedSAD
                bestShift = candidate
            }
        }

        return bestShift
    }

    /// Vision framework translational image registration.
    /// When a frozen header is known, crops both images to the scrolling region for more accurate results.
    private func visionTranslationShift(current: CGImage, previous: CGImage) -> CGFloat? {
        var curImg = current
        var prevImg = previous
        // If frozen header detected, crop it out so Vision only sees the scrolling region
        if frozenDetectionDone && frozenTopPixels > 0 {
            let scrollH = current.height - frozenTopPixels
            guard scrollH > 20 else { return nil }
            let cropRect = CGRect(x: 0, y: frozenTopPixels, width: current.width, height: scrollH)
            guard let cc = current.cropping(to: cropRect),
                  let pc = previous.cropping(to: cropRect) else { return nil }
            curImg = cc
            prevImg = pc
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: prevImg)
        let handler = VNImageRequestHandler(cgImage: curImg, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        return obs.alignmentTransform.ty
    }

    /// Pixel-row SAD (Sum of Absolute Differences) fallback.
    /// Takes a template from the bottom of `previous` and slides it through `current` to find overlap.
    /// Returns shift in pixels matching Vision semantics (positive = scrolled down).
    /// When frozen header is known, only compares the scrolling region below it.
    private func pixelRowSADShift(current: CGImage, previous: CGImage) -> CGFloat? {
        guard current.width == previous.width, current.height == previous.height else { return nil }
        let w = current.width
        let h = current.height
        // Skip frozen header rows — only compare the scrolling region
        let startRow = (frozenDetectionDone && frozenTopPixels > 0) ? frozenTopPixels : 0
        let effectiveH = h - startRow
        guard effectiveH > 40 else { return nil }

        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return nil }

        let bytesPerRow = w * 4
        let templateRows = max(20, effectiveH / 5)  // bottom 20% of scrolling region as template
        let templateStartRow = h - templateRows  // absolute row in image
        let searchRange = startRow + effectiveH - templateRows  // search within scrolling region

        var bestMatch = -1
        var bestSAD: UInt64 = .max

        let rowStep = 4
        let colStep = 8

        for candidateRow in stride(from: startRow, to: searchRange, by: 2) {
            var sad: UInt64 = 0
            var samples: Int = 0
            for tRow in stride(from: 0, to: templateRows, by: rowStep) {
                let prevRow = templateStartRow + tRow
                let curRow = candidateRow + tRow
                guard curRow < h else { break }

                let prevOff = prevRow * bytesPerRow
                let curOff = curRow * bytesPerRow

                for col in stride(from: 0, to: w * 4, by: colStep * 4) {
                    let pR = Int(prevData[prevOff + col])
                    let pG = Int(prevData[prevOff + col + 1])
                    let pB = Int(prevData[prevOff + col + 2])
                    let cR = Int(curData[curOff + col])
                    let cG = Int(curData[curOff + col + 1])
                    let cB = Int(curData[curOff + col + 2])
                    sad += UInt64(abs(pR - cR) + abs(pG - cG) + abs(pB - cB))
                    samples += 1
                }
            }
            guard samples > 0 else { continue }
            let normalizedSAD = sad / UInt64(samples)
            if normalizedSAD < bestSAD {
                bestSAD = normalizedSAD
                bestMatch = candidateRow
            }
        }

        guard bestMatch >= 0, bestSAD < 30 else { return nil }

        // Template at prev rows [h-T ..< h] matched at current rows [bestMatch ..< bestMatch+T].
        // Scroll distance = (h - T) - bestMatch (how far scrolling content shifted down).
        let scrollDistance = templateStartRow - bestMatch
        guard scrollDistance > 0 else { return nil }
        return CGFloat(scrollDistance)
    }

    /// Extract raw BGRA pixel data from a CGImage.
    private func pixelData(for image: CGImage) -> UnsafePointer<UInt8>? {
        // For CPU-backed images created by copyToCPUBacked, we can access data directly
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data else { return nil }
        return CFDataGetBytePtr(data)
    }

    // MARK: - Frozen region detection

    /// Compares the top rows of two consecutive frames. If the top N rows are identical (within threshold),
    /// those rows are a frozen/sticky header. We detect this over the first few frame pairs to be confident.
    private func detectFrozenRegion(current: CGImage, previous: CGImage, shiftPixels: CGFloat) {
        guard current.width == previous.width, current.height == previous.height else { return }
        guard shiftPixels > 5 else { return }  // need meaningful scroll to detect

        let w = current.width
        let h = current.height

        guard let curData = pixelData(for: current),
              let prevData = pixelData(for: previous) else { return }

        let bytesPerRow = w * 4
        let colStep = 4  // sample every 4th pixel for speed

        // Scan from top, row by row, find where content starts to differ
        var frozenRows = 0
        for row in 0..<h {
            var rowSAD: UInt64 = 0
            var samples: Int = 0
            let offset = row * bytesPerRow
            for col in stride(from: 0, to: w * 4, by: colStep * 4) {
                let cR = Int(curData[offset + col])
                let cG = Int(curData[offset + col + 1])
                let cB = Int(curData[offset + col + 2])
                let pR = Int(prevData[offset + col])
                let pG = Int(prevData[offset + col + 1])
                let pB = Int(prevData[offset + col + 2])
                rowSAD += UInt64(abs(cR - pR) + abs(cG - pG) + abs(cB - pB))
                samples += 1
            }
            let avg = samples > 0 ? rowSAD / UInt64(samples) : 999
            if avg > 8 {
                // This row differs — content has scrolled here
                frozenRows = row
                break
            }
            if row == h - 1 {
                // Entire image is identical — no scroll, shouldn't happen if shift > 0
                return
            }
        }

        // Minimum frozen region: at least 10 pixels, at most 60% of frame
        if frozenRows >= 10 && frozenRows < (h * 6 / 10) {
            frozenDetectionSamples += 1

            if frozenDetectionSamples == 1 {
                // First detection — store candidate
                frozenTopPixels = frozenRows
            } else {
                // Subsequent detections — must agree within 5 pixels
                if abs(frozenRows - frozenTopPixels) <= 5 {
                    // Confirmed — take the minimum to be safe
                    frozenTopPixels = min(frozenTopPixels, frozenRows)
                } else {
                    // Disagreement — no reliable frozen region
                    frozenTopPixels = 0
                    frozenDetectionDone = true
                    return
                }
            }

            // After 2 consistent detections, we're confident
            if frozenDetectionSamples >= 2 {
                frozenTopHeight = CGFloat(frozenTopPixels) / backingScale
                frozenDetectionDone = true
            }
        } else if frozenRows < 10 {
            // No frozen region found — mark as done
            frozenDetectionDone = true
        }
    }

    // MARK: - Batch stitching

    /// Combines all captured strips into one final image, respecting frozen regions.
    /// If a frozen header was detected, it's included once at the top and stripped from subsequent frames.
    /// Re-computes pixel-exact shifts between consecutive strips at stitch time for seam-free results.
    private func batchStitch() -> NSImage? {
        guard !capturedStrips.isEmpty else { return nil }

        if capturedStrips.count == 1 {
            let strip = capturedStrips[0]
            return NSImage(cgImage: strip.image, size: strip.pointSize)
        }

        let stripW = capturedStrips[0].image.width
        let stripH = capturedStrips[0].image.height

        // Re-compute shifts between consecutive strips at pixel level.
        // Uses a robust row-matching approach: find the row in `current` that best matches
        // a reference row from `previous`, checking every pixel.
        // Each offset is biased by -1px so strips overlap 1 extra row. Since later strips
        // are drawn on top, this ensures no gap even with ±1px detection error — the worst
        // case is 1 row of duplicated (newer) content, which is invisible.
        var refinedOffsets: [Int] = []
        for i in 1..<capturedStrips.count {
            let prev = capturedStrips[i - 1].image
            let curr = capturedStrips[i].image
            let coarse = i - 1 < stripOffsetsPx.count ? stripOffsetsPx[i - 1] : 0
            let raw: Int
            if let exact = exactRowMatch(current: curr, previous: prev, estimate: coarse) {
                raw = exact
            } else if let refined = refineShift(current: curr, previous: prev,
                                                estimate: coarse, searchRadius: 8) {
                raw = refined
            } else {
                raw = i - 1 < stripOffsetsPx.count ? stripOffsetsPx[i - 1] : 0
            }
            refinedOffsets.append(max(0, min(raw, stripH)))
        }

        var totalPixelH: Int = stripH
        for offPx in refinedOffsets {
            totalPixelH += offPx
        }

        // Create output bitmap
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: stripW, height: totalPixelH,
                                  bitsPerComponent: 8, bytesPerRow: stripW * 4,
                                  space: cs, bitmapInfo: bitmapInfo) else { return nil }

        // Draw each full strip overlapping the previous one. Drawing full strips instead of
        // cropping to exact new-content rows eliminates 1px black line gaps from rounding errors
        // in offset calculation. Each strip's overlapping region naturally covers the previous one.
        // CGContext has bottom-left origin, so "top of image" = highest y.
        var yOffset = totalPixelH - stripH
        ctx.draw(capturedStrips[0].image, in: CGRect(x: 0, y: yOffset, width: stripW, height: stripH))

        for i in 0..<refinedOffsets.count {
            let offPx = refinedOffsets[i]
            guard offPx > 0, i + 1 < capturedStrips.count else { continue }

            yOffset -= offPx
            // Draw the full strip — the top portion overlaps (and overwrites) the previous strip's bottom.
            ctx.draw(capturedStrips[i + 1].image, in: CGRect(x: 0, y: yOffset, width: stripW, height: stripH))
        }

        guard let finalCG = ctx.makeImage() else { return nil }

        let ptSize = CGSize(width: CGFloat(finalCG.width) / backingScale,
                            height: CGFloat(finalCG.height) / backingScale)
        stitchedImage = finalCG
        stitchedPixelSize = CGSize(width: CGFloat(finalCG.width), height: CGFloat(finalCG.height))
        return NSImage(cgImage: finalCG, size: ptSize)
    }

    // MARK: - Live preview (lightweight incremental for HUD)

    /// Updates the stitchedImage/stitchedPixelSize for HUD display during capture.
    /// This is a fast incremental composite — the final batch stitch at the end is more accurate.
    private func updateLivePreview() {
        guard let first = capturedStrips.first else { return }

        if capturedStrips.count == 1 {
            stitchedImage = first.image
            stitchedPixelSize = CGSize(width: CGFloat(first.image.width),
                                       height: CGFloat(first.image.height))
            if let callback = onPreviewUpdated {
                let ptSize = CGSize(width: CGFloat(first.image.width) / backingScale,
                                    height: CGFloat(first.image.height) / backingScale)
                callback(NSImage(cgImage: first.image, size: ptSize))
            }
            return
        }

        // Estimate total height from offsets
        let stripPxH = CGFloat(first.image.height)
        let totalNewPx = CGFloat(stripOffsetsPx.reduce(0, +))
        let totalH = stripPxH + totalNewPx
        stitchedPixelSize = CGSize(width: CGFloat(first.image.width), height: totalH)

        // Generate a live preview image by compositing all strips
        if let callback = onPreviewUpdated {
            let stripW = first.image.width
            let totalPixelH = Int(totalH)
            guard totalPixelH > 0 else { return }

            let cs = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: nil, width: stripW, height: totalPixelH,
                                      bitsPerComponent: 8, bytesPerRow: stripW * 4,
                                      space: cs, bitmapInfo: bitmapInfo) else { return }

            // Draw first strip at top
            var yOffset = totalPixelH - first.image.height
            ctx.draw(first.image, in: CGRect(x: 0, y: yOffset, width: stripW, height: first.image.height))

            // Draw subsequent strips overlapping (same approach as batchStitch)
            for i in 0..<stripOffsetsPx.count {
                let offPx = stripOffsetsPx[i]
                guard offPx > 0, i + 1 < capturedStrips.count else { continue }
                yOffset -= offPx
                let strip = capturedStrips[i + 1]
                ctx.draw(strip.image, in: CGRect(x: 0, y: yOffset, width: stripW, height: strip.image.height))
            }

            if let previewCG = ctx.makeImage() {
                let ptSize = CGSize(width: CGFloat(previewCG.width) / backingScale,
                                    height: CGFloat(previewCG.height) / backingScale)
                callback(NSImage(cgImage: previewCG, size: ptSize))
            }
        }
    }

    // MARK: - Strip capture

    /// Capture a stable frame: grab frames, convert to CPU-backed, compare consecutive
    /// pairs until two match (content has settled). Exponential backoff between attempts.
    private func captureStrip() async -> CGImage? {
        guard let stream = persistentStream else { return nil }

        var previousCPU: CGImage?
        var waitNs: UInt64 = 10_000_000  // start at 10ms

        for _ in 0..<8 {
            guard let raw = stream.latestFrame,
                  let cpu = copyToCPUBacked(raw) else {
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }

            if let prev = previousCPU, framesMatch(prev, cpu) {
                // Two consecutive CPU-backed frames match — content has settled
                return cpu
            }

            previousCPU = cpu
            try? await Task.sleep(nanoseconds: waitNs)
            waitNs = min(waitNs * 3 / 2, 80_000_000)  // backoff: 10→15→22→33→50→75→80ms
        }

        // Fallback: return last captured frame
        return previousCPU
    }

    /// Quick comparison of two frames by sampling a few rows. Returns true if they're nearly identical.
    private func framesMatch(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let dataA = pixelData(for: a), let dataB = pixelData(for: b) else { return false }
        let w = a.width
        let h = a.height
        let bytesPerRow = w * 4

        // Sample 5 rows spread across the image
        let maxIdx = h * bytesPerRow
        var totalDiff: UInt64 = 0
        var samples: Int = 0
        for rowIdx in [h / 6, h / 3, h / 2, h * 2 / 3, h * 5 / 6] {
            let off = rowIdx * bytesPerRow
            // Sample every 8th pixel for speed
            for col in stride(from: 0, to: w * 4, by: 32) {
                let idx = off + col
                guard idx + 2 < maxIdx else { continue }
                totalDiff += UInt64(abs(Int(dataA[idx]) - Int(dataB[idx]))
                                  + abs(Int(dataA[idx+1]) - Int(dataB[idx+1]))
                                  + abs(Int(dataA[idx+2]) - Int(dataB[idx+2])))
                samples += 1
            }
        }
        guard samples > 0 else { return false }
        let avgDiff = totalDiff / UInt64(samples)
        return avgDiff < 3  // nearly identical
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
}

// MARK: - Persistent capture stream

/// Keeps an SCStream running for the duration of the scroll capture session.
/// Continuously updates `latestFrame` with the most recent fully-rendered frame.
/// This eliminates stale/partial first-frame artifacts (black lines) that occur when
/// starting a new SCStream per capture.
private final class PersistentFrameStream: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private let lock = NSLock()
    private var _latestFrame: CGImage?
    private let ciContext = CIContext()

    /// The most recently captured frame. Always a complete, compositor-finished frame.
    var latestFrame: CGImage? {
        lock.lock()
        let frame = _latestFrame
        lock.unlock()
        return frame
    }

    /// Start the persistent stream. Returns true on success.
    func start(display: SCDisplay, excludedWindows: [SCWindow],
               sourceRect: CGRect, captureSize: CGSize,
               backingScale: CGFloat) async -> Bool {
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width  = Int(captureSize.width)
        config.height = Int(captureSize.height)
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)  // 120fps for freshest possible frames
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        guard let scStream = try? SCStream(filter: filter, configuration: config, delegate: nil) else { return false }
        self.stream = scStream
        do {
            try scStream.addStreamOutput(self, type: .screen,
                                          sampleHandlerQueue: DispatchQueue(label: "macshot.scrollstream"))
            try await scStream.startCapture()
            return true
        } catch {
            self.stream = nil
            return false
        }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // SCStreamOutput — continuously update latest frame
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        lock.lock()
        _latestFrame = cgImage
        lock.unlock()
    }
}
