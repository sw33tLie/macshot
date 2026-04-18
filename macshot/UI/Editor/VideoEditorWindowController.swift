import Cocoa
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Standalone video editor window for trimming and exporting recorded videos.
final class VideoEditorWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var editorView: VideoEditorView?
    private static var activeControllers: [VideoEditorWindowController] = []

    /// Open a video in the editor.
    /// - Parameters:
    ///   - url: File URL to the video.
    ///   - deleteOnClose: If true (default) the editor deletes the file when
    ///     the window closes — appropriate for temporary recordings. Pass
    ///     `false` when opening a user-owned file so we don't delete their
    ///     source.
    static func open(url: URL, deleteOnClose: Bool = true) {
        let controller = VideoEditorWindowController()
        controller.show(url: url, deleteOnClose: deleteOnClose)
        activeControllers.append(controller)
        if activeControllers.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func show(url: URL, deleteOnClose: Bool = true) {
        guard let screen = NSScreen.main else { return }

        // Size window to fit content, capped at 60% of screen
        let controlsH: CGFloat = 172
        let maxW = screen.frame.width * 0.6
        let maxH = screen.frame.height * 0.6
        var contentW: CGFloat = 800
        var contentH: CGFloat = 450

        // Get content dimensions — MP4 uses AVAsset track info
        if url.pathExtension.lowercased() != "gif" {
            let asset = AVAsset(url: url)
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                let backingScale = screen.backingScaleFactor
                contentW = abs(size.width) / backingScale
                contentH = abs(size.height) / backingScale
            }
        }
        // GIF: keep defaults — AVFoundation can't read GIF dimensions reliably

        // Scale down to fit screen, maintaining aspect ratio
        let scale = min(1.0, min(maxW / contentW, (maxH - controlsH) / contentH))
        let winW = max(880, contentW * scale)
        let winH = max(400, contentH * scale + controlsH)
        let winX = screen.frame.midX - winW / 2
        let winY = screen.frame.midY - winH / 2

        let win = NSWindow(
            contentRect: NSRect(x: winX, y: winY, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        // Prefix with the source filename so multiple editor windows are
        // distinguishable in the Dock menu and Window menu.
        win.title = "\(url.deletingPathExtension().lastPathComponent) — \(L("macshot Video Editor"))"
        win.minSize = NSSize(width: 880, height: 400)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.backgroundColor = ToolbarLayout.bgColor

        let view = VideoEditorView(frame: NSRect(x: 0, y: 0, width: winW, height: winH),
                                    videoURL: url,
                                    deleteOnClose: deleteOnClose)
        win.contentView = view

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        self.editorView = view
    }

    func windowWillClose(_ notification: Notification) {
        editorView?.cleanup()
        editorView = nil
        let closingWindow = window
        window = nil
        Self.activeControllers.removeAll { $0 === self }
        if Self.activeControllers.isEmpty {
            (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
        }
    }
}

// MARK: - VideoEditorView

private final class VideoEditorView: NSView {

    private let videoURL: URL
    /// If true, the underlying file is deleted on close (recording tmp path).
    /// Set to false when opening a user-owned source file via "Open Video...".
    private let deleteOnClose: Bool
    private let isGIF: Bool
    private var player: AVPlayer?
    private var playerView: AVPlayerView?
    private var effectsOverlay: EffectsPreviewOverlayView?
    private var gifImageView: NSImageView?
    private var asset: AVAsset?
    private var duration: Double = 0

    // Timeline state
    private var trimStart: Double = 0
    private var trimEnd: Double = 0
    private var timelineRect: NSRect = .zero
    private var isDraggingStart: Bool = false
    private var isDraggingEnd: Bool = false
    private var isDraggingScrubber: Bool = false
    private var timeObserver: Any?
    private var gifPlaybackTimer: Timer?
    private var gifPlaybackTime: Double = 0
    private var gifIsPlaying: Bool = false

    // Timeline thumbnails
    private var thumbnailImages: [NSImage] = []
    private var thumbnailsGenerating: Bool = false
    private var lastThumbnailWidth: CGFloat = 0

    // Format toggle (MP4 vs GIF export)
    private var exportAsGIF: Bool = false
    private var formatToggleRect: NSRect = .zero
    private var formatMP4Rect: NSRect = .zero
    private var formatGIFRect: NSRect = .zero

    // Export dimensions
    private var originalWidth: Int = 0
    private var originalHeight: Int = 0
    private var exportScale: CGFloat = 1.0  // 1.0 = original, 0.5 = 50%, etc.
    private var dimensionsBtnRect: NSRect = .zero

    // Export quality (controls bitrate when re-encoding for MP4 export)
    private var exportQuality: VideoQuality = .high
    private var qualityBtnRect: NSRect = .zero

    // Effects band (zoom + censor segments) lives in its own NSView, hosted
    // inside an NSScrollView so it can overflow vertically when many segments
    // stack onto separate rows. The parent editor observes mutations via the
    // band's delegate and rebuilds the video composition / preview overlay.
    private var effectsBand: EffectsBandView?
    private var effectsScrollView: NSScrollView?
    private var effectsBandHeightConstraint: NSLayoutConstraint?
    private var playerBottomConstraint: NSLayoutConstraint?

    // Convenience accessors so call sites don't have to guard the optional.
    private var zoomSegments: [VideoZoomSegment] { effectsBand?.zoomSegments ?? [] }
    private var censorSegments: [VideoCensorSegment] { effectsBand?.censorSegments ?? [] }
    private var cutSegments: [VideoCutSegment] { effectsBand?.cutSegments ?? [] }
    private var selectedSegmentID: UUID? { effectsBand?.selectedSegmentID }

    // Button rects
    private var playBtnRect: NSRect = .zero
    private var saveBtnRect: NSRect = .zero
    private var saveArrowRect: NSRect = .zero
    private var uploadBtnRect: NSRect = .zero
    private var copyBtnRect: NSRect = .zero
    private var copyArrowRect: NSRect = .zero
    private var muteBtnRect: NSRect = .zero
    private var finderBtnRect: NSRect = .zero
    private var isMuted: Bool = false
    private var savedURL: URL?
    private var statusMessage: String?
    private var statusIsError: Bool = false
    private var statusTimer: Timer?

    // Layout
    private let timelinePad: CGFloat = 20
    /// Row height inside the effects band, kept in sync with EffectsBandView.
    /// Also serves as a layout primitive for the scroll view's visible height.
    private let effectsRowStride: CGFloat = 22 + 2
    /// Number of rows visible without scrolling inside the effects scroll view.
    /// Beyond this the scroll view scrolls vertically.
    private let effectsVisibleRowCount: Int = 4

    // Vertical layout of the controls band (bottom-up):
    //   [buttons 12→40]          fixed 48pt
    //   [effects scroll view]    variable (rowCount × rowStride - 2, capped)
    //   [gap 8pt]                8
    //   [time labels]            18
    //   [trim timeline]          36
    //   [top pad]                12
    private let buttonsAreaH: CGFloat = 48
    private let labelsRowH: CGFloat = 18
    private let trimBarH: CGFloat = 36
    private let topPadH: CGFloat = 12
    private let scrollToLabelsGap: CGFloat = 8

    /// Total height of the controls band at the bottom of the editor,
    /// dynamic because the effects scroll view grows with row count.
    private var controlsH: CGFloat {
        return buttonsAreaH
             + effectsScrollViewHeight(forRowCount: currentEffectRowCount)
             + scrollToLabelsGap
             + labelsRowH
             + trimBarH
             + topPadH
    }

    /// Live row count; the delegate callback updates it and triggers layout.
    private var currentEffectRowCount: Int = 1

    init(frame: NSRect, videoURL: URL, deleteOnClose: Bool = true) {
        self.videoURL = videoURL
        self.deleteOnClose = deleteOnClose
        self.isGIF = videoURL.pathExtension.lowercased() == "gif"
        super.init(frame: frame)

        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)

        setupPlayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupPlayer() {
        if isGIF {
            setupGIFView()
            return
        }

        let asset = AVAsset(url: videoURL)
        self.asset = asset

        // Store original pixel dimensions
        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            originalWidth = Int(abs(size.width))
            originalHeight = Int(abs(size.height))
        }

        Task {
            // Use video track duration (asset duration can be wrong when audio track is present)
            let seconds: Double
            if let videoTrack = asset.tracks(withMediaType: .video).first {
                seconds = CMTimeGetSeconds(videoTrack.timeRange.duration)
            } else if let dur = try? await asset.load(.duration) {
                seconds = CMTimeGetSeconds(dur)
            } else {
                seconds = 0
            }
            await MainActor.run {
                self.duration = max(seconds, 0.1)
                self.trimEnd = self.duration
                self.buildPlayerView()
                self.effectsBand?.duration = self.duration
            }
        }
    }

    private func setupGIFView() {
        guard let gifImage = NSImage(contentsOf: videoURL) else { return }
        // Estimate duration from GIF frame count and delay
        if let src = CGImageSourceCreateWithURL(videoURL as CFURL, nil) {
            let count = CGImageSourceGetCount(src)
            var totalDelay: Double = 0
            for i in 0..<count {
                if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any],
                   let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                   let delay = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ?? gifProps[kCGImagePropertyGIFDelayTime as String] as? Double {
                    totalDelay += delay
                }
            }
            duration = max(totalDelay, 0.1)
        } else {
            duration = 1.0
        }
        trimEnd = duration

        // Store original GIF dimensions
        if let src = CGImageSourceCreateWithURL(videoURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            originalWidth = img.width
            originalHeight = img.height
        }

        let iv = NSImageView()
        iv.image = gifImage
        iv.animates = true
        iv.imageScaling = .scaleProportionallyDown
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)

        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: topAnchor),
            iv.leadingAnchor.constraint(equalTo: leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: trailingAnchor),
            iv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -controlsH),
        ])
        gifImageView = iv
        gifIsPlaying = true
        gifPlaybackTime = trimStart
        gifPlaybackTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.gifIsPlaying else { return }
            self.gifPlaybackTime += 1.0/30.0
            if self.gifPlaybackTime >= self.trimEnd {
                self.gifPlaybackTime = self.trimStart
            }
            self.needsDisplay = true
        }
        needsDisplay = true
    }

    private func buildPlayerView() {
        // Use the same AVAsset instance the rest of the editor uses so that
        // track IDs our composition references line up with what AVPlayer is
        // decoding.
        let playerAsset = asset ?? AVAsset(url: videoURL)
        let item = AVPlayerItem(asset: playerAsset)
        let player = AVPlayer(playerItem: item)
        self.player = player

        let pv = AVPlayerView()
        pv.player = player
        pv.controlsStyle = .none
        pv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pv)

        let playerBottomC = pv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -controlsH)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: topAnchor),
            pv.leadingAnchor.constraint(equalTo: leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerBottomC,
        ])
        playerView = pv
        self.playerBottomConstraint = playerBottomC

        // Overlay for interactive effect editing — sits on top of the player
        // view and pins to the same edges so it tracks window resizes.
        let overlay = EffectsPreviewOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Video natural size (orientation-applied). Needed so the overlay can
        // compute the letterboxed video rect inside its bounds.
        if let track = playerAsset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            overlay.videoSize = CGSize(width: abs(size.width), height: abs(size.height))
        }
        overlay.onChange = { [weak self] newRect in
            self?.overlayRectChanged(newRect)
        }
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: pv.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: pv.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: pv.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: pv.bottomAnchor),
        ])
        effectsOverlay = overlay

        // Effects band — inside a scroll view so many stacked rows don't push
        // the timeline off-screen. Height grows up to
        // `effectsVisibleRowCount` rows, beyond which the scroll view
        // scrolls.
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .none
        let band = EffectsBandView()
        band.translatesAutoresizingMaskIntoConstraints = false
        band.delegate = self
        scrollView.documentView = band
        addSubview(scrollView)

        let scrollHeight = effectsScrollViewHeight(forRowCount: 1)
        let heightC = scrollView.heightAnchor.constraint(equalToConstant: scrollHeight)
        heightC.priority = .required
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: timelinePad),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -timelinePad),
            // Scroll view sits directly above the buttons row (y=48 from parent bottom).
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -buttonsAreaH),
            heightC,
            // Document view (band) width matches the scroll view's visible
            // width; height is driven by intrinsicContentSize.
            band.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        self.effectsScrollView = scrollView
        self.effectsBand = band
        self.effectsBandHeightConstraint = heightC

        // Observe playback position
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self = self, !self.isDraggingScrubber else { return }
            // The player's clock may be the cut-stripped composition clock;
            // map it back to the source asset clock before comparing with
            // trim markers (which are in source time).
            let t = self.mapPreviewClockToSourceTime(CMTimeGetSeconds(time))
            if t >= self.trimEnd {
                self.player?.pause()
                let target = self.mapSourceTimeToPreviewClock(self.trimStart)
                self.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            self.needsDisplay = true
        }

        generateThumbnails()
        needsDisplay = true
    }

    private func generateThumbnails() {
        guard let asset = asset, !thumbnailsGenerating else { return }
        let tlW = bounds.width - timelinePad * 2
        guard tlW > 0 else { return }
        lastThumbnailWidth = tlW
        thumbnailsGenerating = true

        let thumbH: CGFloat = 30
        let thumbW: CGFloat = thumbH * 16 / 9
        let count = max(1, Int(ceil(tlW / thumbW)))
        let dur = duration

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbW * 2, height: thumbH * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var times: [NSValue] = []
        for i in 0..<count {
            let t = dur * Double(i) / Double(count)
            times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 600)))
        }

        var images: [NSImage] = Array(repeating: NSImage(), count: count)
        var idx = 0
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] _, cgImage, _, _, _ in
            if let cg = cgImage {
                let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
                images[idx] = img
            }
            idx += 1
            if idx >= count {
                DispatchQueue.main.async {
                    self?.thumbnailImages = images
                    self?.thumbnailsGenerating = false
                    self?.needsDisplay = true
                }
            }
        }
    }

    func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        player?.pause()
        player = nil
        playerView?.player = nil
        gifPlaybackTimer?.invalidate()
        gifPlaybackTimer = nil
        // Delete only if the file was a temporary recording we own. User-
        // opened files must never be deleted — that would be data loss.
        if deleteOnClose {
            try? FileManager.default.removeItem(at: videoURL)
        }
    }

    private var currentPlaybackTime: Double {
        if isGIF {
            return gifPlaybackTime
        } else {
            // Always report in source-asset time so the playhead, thumbnails
            // and trim UI agree regardless of whether the preview is
            // composition-backed (cuts present) or not.
            return mapPreviewClockToSourceTime(CMTimeGetSeconds(player?.currentTime() ?? .zero))
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Controls background
        let controlsBg = NSRect(x: 0, y: 0, width: bounds.width, height: controlsH)
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(rect: controlsBg).fill()

        // Separator
        ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: controlsH, width: bounds.width, height: 0.5)).fill()

        guard duration > 0 else { return }

        drawTimeline()
        drawButtons()
        drawTimeLabels()
        if let msg = statusMessage { drawStatus(msg) }
    }


    private func drawTimeline() {
        let tlX = timelinePad
        let tlW = bounds.width - timelinePad * 2
        // Trim timeline bottom sits above the time-labels row, which sits
        // above the effects scroll view. All three adjust upward as the
        // scroll view grows to show more rows.
        let tlH: CGFloat = trimBarH
        let scrollH = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        let tlY: CGFloat = buttonsAreaH + scrollH + scrollToLabelsGap + labelsRowH
        timelineRect = NSRect(x: tlX, y: tlY, width: tlW, height: tlH)

        // Regenerate thumbnails if width changed significantly
        if abs(tlW - lastThumbnailWidth) > 40 && !thumbnailsGenerating && asset != nil {
            generateThumbnails()
        }

        // Track background with rounded clip
        let trackPath = NSBezierPath(roundedRect: timelineRect, xRadius: 5, yRadius: 5)
        ToolbarLayout.iconColor.withAlphaComponent(0.06).setFill()
        trackPath.fill()

        // Draw thumbnails — use floor/ceil to avoid sub-pixel gaps between tiles
        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        if !thumbnailImages.isEmpty {
            let count = thumbnailImages.count
            for (i, img) in thumbnailImages.enumerated() {
                let x0 = floor(tlX + CGFloat(i) * tlW / CGFloat(count))
                let x1 = ceil(tlX + CGFloat(i + 1) * tlW / CGFloat(count))
                let r = NSRect(x: x0, y: tlY, width: x1 - x0, height: tlH)
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.5)
            }
        }

        // Dim untrimmed regions
        let startX = tlX + CGFloat(trimStart / duration) * tlW
        let endX = tlX + CGFloat(trimEnd / duration) * tlW
        NSColor.black.withAlphaComponent(0.6).setFill()
        if startX > tlX {
            NSRect(x: tlX, y: tlY, width: startX - tlX, height: tlH).fill()
        }
        if endX < tlX + tlW {
            NSRect(x: endX, y: tlY, width: tlX + tlW - endX, height: tlH).fill()
        }

        // Draw striped cut overlays inside the trim region — they signal
        // ranges that will be removed on export. Clipped by the track path so
        // overlays never leak past the rounded edges.
        for cut in cutSegments where cut.endTime > cut.startTime {
            let cx0 = tlX + CGFloat(max(0, min(duration, cut.startTime)) / duration) * tlW
            let cx1 = tlX + CGFloat(max(0, min(duration, cut.endTime)) / duration) * tlW
            let cutRect = NSRect(x: cx0, y: tlY, width: max(1, cx1 - cx0), height: tlH)
            // Dark-red tint over the thumbnails.
            NSColor(calibratedRed: 0.50, green: 0.05, blue: 0.08, alpha: 0.55).setFill()
            cutRect.fill()
            // Diagonal hatching.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: cutRect).addClip()
            NSColor.white.withAlphaComponent(0.22).setStroke()
            let stripes = NSBezierPath()
            stripes.lineWidth = 1
            let step: CGFloat = 6
            var x = cutRect.minX - cutRect.height
            while x < cutRect.maxX + cutRect.height {
                stripes.move(to: NSPoint(x: x, y: cutRect.minY))
                stripes.line(to: NSPoint(x: x + cutRect.height, y: cutRect.maxY))
                x += step
            }
            stripes.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Trim border highlight
        let trimRect = NSRect(x: startX, y: tlY, width: endX - startX, height: tlH)
        let trimBorder = NSBezierPath(roundedRect: trimRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        trimBorder.lineWidth = 1.5
        ToolbarLayout.accentColor.withAlphaComponent(0.8).setStroke()
        trimBorder.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Trim handles
        let handleW: CGFloat = 10
        let handleH: CGFloat = tlH + 8

        let startHandleRect = NSRect(x: startX - handleW / 2, y: tlY - 4, width: handleW, height: handleH)
        ToolbarLayout.accentColor.setFill()
        NSBezierPath(roundedRect: startHandleRect, xRadius: 3, yRadius: 3).fill()
        drawHandleGrip(in: startHandleRect)

        let endHandleRect = NSRect(x: endX - handleW / 2, y: tlY - 4, width: handleW, height: handleH)
        ToolbarLayout.accentColor.setFill()
        NSBezierPath(roundedRect: endHandleRect, xRadius: 3, yRadius: 3).fill()
        drawHandleGrip(in: endHandleRect)

        // Playhead — line spans the full trim timeline, circle sits above it
        // in the gap between the timeline top and the time labels.
        if player != nil || isGIF {
            let currentTime = currentPlaybackTime
            let playheadX = max(tlX, min(tlX + tlW, tlX + CGFloat(currentTime / duration) * tlW))

            ToolbarLayout.iconColor.withAlphaComponent(0.9).setFill()
            let playheadRect = NSRect(x: playheadX - 1, y: tlY - 2,
                                       width: 2, height: tlH + 4)
            NSBezierPath(roundedRect: playheadRect, xRadius: 1, yRadius: 1).fill()

            let circleR: CGFloat = 4
            // Share the same x as the line so the two are always visually
            // joined — even at t=0 the circle overhangs past the track edge
            // rather than snapping a few px inward and breaking alignment.
            let circleX = playheadX
            let circleY = tlY + tlH + 2  // just above the trim top edge
            ToolbarLayout.iconColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: circleX - circleR,
                                          y: circleY,
                                          width: circleR * 2,
                                          height: circleR * 2)).fill()
        }
    }

    private func drawHandleGrip(in rect: NSRect) {
        ToolbarLayout.iconColor.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let midY = rect.midY
        for dy in stride(from: -3 as CGFloat, through: 3, by: 3) {
            path.move(to: NSPoint(x: rect.midX - 2, y: midY + dy))
            path.line(to: NSPoint(x: rect.midX + 2, y: midY + dy))
        }
        path.stroke()
    }

    private func drawButtons() {
        let btnH: CGFloat = 28
        let btnY: CGFloat = 12
        let gap: CGFloat = 8
        let iconBtnW: CGFloat = 34
        let labelBtnW: CGFloat = 100

        // Pre-compute right group width so left content knows where to stop
        let copyArrowW: CGFloat = 20
        let saveArrowW: CGFloat = 20
        let rightGroupW = (labelBtnW + copyArrowW) + gap + iconBtnW + gap + labelBtnW + gap + (labelBtnW + saveArrowW)
        let maxLeftX = bounds.width - timelinePad - rightGroupW - 12  // 12pt breathing room

        // Left group: play, mute
        var x: CGFloat = timelinePad

        let isPlaying = isGIF ? gifIsPlaying : (player?.rate ?? 0 > 0)
        playBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: playBtnRect, symbol: isPlaying ? "pause.fill" : "play.fill", accent: true)
        x += iconBtnW + gap

        muteBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: muteBtnRect, symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accent: false, active: isMuted)
        x += iconBtnW + gap

        // Format toggle + file info
        if !isGIF {
            // MP4 | GIF segmented toggle
            let segW: CGFloat = 88
            let segH: CGFloat = 22
            let segY = btnY + (btnH - segH) / 2
            formatToggleRect = NSRect(x: x + 4, y: segY, width: segW, height: segH)
            let halfW = segW / 2
            formatMP4Rect = NSRect(x: formatToggleRect.minX, y: segY, width: halfW, height: segH)
            formatGIFRect = NSRect(x: formatToggleRect.minX + halfW, y: segY, width: halfW, height: segH)

            // Background
            ToolbarLayout.iconColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: formatToggleRect, xRadius: 5, yRadius: 5).fill()

            // Selected segment highlight
            let selRect = exportAsGIF ? formatGIFRect : formatMP4Rect
            ToolbarLayout.accentColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: selRect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()

            // Labels
            let selAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ToolbarLayout.iconColor,
            ]
            let unselAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.5),
            ]
            let mp4Str = "MP4" as NSString
            let gifStr = "GIF" as NSString
            let mp4Size = mp4Str.size(withAttributes: selAttrs)
            let gifSize = gifStr.size(withAttributes: selAttrs)
            mp4Str.draw(at: NSPoint(x: formatMP4Rect.midX - mp4Size.width / 2, y: formatMP4Rect.midY - mp4Size.height / 2),
                        withAttributes: exportAsGIF ? unselAttrs : selAttrs)
            gifStr.draw(at: NSPoint(x: formatGIFRect.midX - gifSize.width / 2, y: formatGIFRect.midY - gifSize.height / 2),
                        withAttributes: exportAsGIF ? selAttrs : unselAttrs)
            x += segW + 12
        }

        do {
            let infoAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.4),
            ]
            let sourceFileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(sourceFileSize), countStyle: .file)
            let fpsValue = asset?.tracks(withMediaType: .video).first?.nominalFrameRate ?? 0
            let fpsStr = fpsValue > 0 ? "\(Int(fpsValue.rounded()))fps" : ""
            let infoStr = "\(sizeStr)  ·  \(fpsStr)" as NSString
            let infoSize = infoStr.size(withAttributes: infoAttrs)
            if x + infoSize.width < maxLeftX {
                infoStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - infoSize.height) / 2), withAttributes: infoAttrs)
                x += infoSize.width + 12
            }

            // Dimensions dropdown button
            dimensionsBtnRect = .zero
            if originalWidth > 0 && x < maxLeftX {
                let exportW = Int(CGFloat(originalWidth) * exportScale)
                let exportH = Int(CGFloat(originalHeight) * exportScale)
                let dimLabel: String
                if exportScale >= 0.999 {
                    dimLabel = "\(originalWidth)×\(originalHeight)"
                } else {
                    let pct = Int((exportScale * 100).rounded())
                    dimLabel = "\(exportW)×\(exportH) (\(pct)%)"
                }
                let dimAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(exportScale < 0.999 ? 0.7 : 0.4),
                ]
                let dimStr = "  ·  \(dimLabel) ▼" as NSString
                let dimSize = dimStr.size(withAttributes: dimAttrs)
                let dimBtnW = dimSize.width + 8
                if x + dimBtnW < maxLeftX {
                    dimensionsBtnRect = NSRect(x: x, y: btnY, width: dimBtnW, height: btnH)
                    dimStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - dimSize.height) / 2), withAttributes: dimAttrs)
                    x += dimBtnW
                }
            }

            // Quality dropdown (only meaningful when exporting as MP4)
            qualityBtnRect = .zero
            if !exportAsGIF && x < maxLeftX {
                let qualAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(exportQuality != .high ? 0.7 : 0.4),
                ]
                let qualStr = "  ·  \(exportQuality.displayName) ▼" as NSString
                let qualSize = qualStr.size(withAttributes: qualAttrs)
                let qualBtnW = qualSize.width + 8
                if x + qualBtnW < maxLeftX {
                    qualityBtnRect = NSRect(x: x, y: btnY, width: qualBtnW, height: btnH)
                    qualStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - qualSize.height) / 2), withAttributes: qualAttrs)
                    x += qualBtnW
                }
            }

            // Estimated export size — show when trim, scale, quality, or format change would affect output
            let trimRatio = duration > 0 ? (trimEnd - trimStart) / duration : 1.0
            let scaleRatio = exportScale * exportScale  // pixels scale quadratically
            // Quality multiplier on output bitrate (low ~0.33, medium ~0.62, high ~1.0)
            let qualityRatio: Double = {
                switch exportQuality {
                case .low:    return 0.33
                case .medium: return 0.62
                case .high:   return 1.0
                }
            }()
            let willChange = trimRatio < 0.99 || scaleRatio < 0.99 || qualityRatio < 0.99 || exportAsGIF
            if willChange && sourceFileSize > 0 && x < maxLeftX {
                let estimated: Int64
                if exportAsGIF {
                    let gifFPSRatio = min(15.0, fpsValue) / max(fpsValue, 1.0)
                    estimated = Int64(Double(sourceFileSize) * trimRatio * scaleRatio * 3.0 * Double(gifFPSRatio))
                } else {
                    estimated = Int64(Double(sourceFileSize) * trimRatio * scaleRatio * qualityRatio)
                }
                let estStr = "  ·  ~\(ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file))" as NSString
                let estAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.35),
                ]
                let estSize = estStr.size(withAttributes: estAttrs)
                if x + estSize.width + 8 < maxLeftX {
                    estStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - estSize.height) / 2), withAttributes: estAttrs)
                }
            }
        }

        // Right group: save, upload, finder, copy
        x = bounds.width - timelinePad
        let fullCopyW = labelBtnW + copyArrowW
        x -= fullCopyW
        let fullCopyRect = NSRect(x: x, y: btnY, width: fullCopyW, height: btnH)
        copyBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        copyArrowRect = NSRect(x: x + labelBtnW, y: btnY, width: copyArrowW, height: btnH)

        // Draw combined background
        ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: fullCopyRect, xRadius: 6, yRadius: 6).fill()

        do {
            let iconSize: CGFloat = 12
            let copyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.85),
            ]
            let copyLabel = L("Copy") as NSString
            let copyLabelSize = copyLabel.size(withAttributes: copyAttrs)
            let totalCopyW = iconSize + 4 + copyLabelSize.width
            let copyStartX = copyBtnRect.midX - totalCopyW / 2
            if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    ToolbarLayout.iconColor.withAlphaComponent(0.85).setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: copyStartX, y: copyBtnRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            copyLabel.draw(at: NSPoint(x: copyStartX + iconSize + 4, y: copyBtnRect.midY - copyLabelSize.height / 2), withAttributes: copyAttrs)
        }

        // Separator line
        ToolbarLayout.iconColor.withAlphaComponent(0.2).setStroke()
        let copySep = NSBezierPath()
        copySep.move(to: NSPoint(x: copyArrowRect.minX, y: copyArrowRect.minY + 4))
        copySep.line(to: NSPoint(x: copyArrowRect.minX, y: copyArrowRect.maxY - 4))
        copySep.lineWidth = 1
        copySep.stroke()

        // Chevron
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { r in
                chevron.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(0.6).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: copyArrowRect.midX - chevron.size.width / 2, y: copyArrowRect.midY - chevron.size.height / 2,
                                    width: chevron.size.width, height: chevron.size.height))
        }

        x -= gap + iconBtnW
        finderBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: finderBtnRect, symbol: "folder", accent: false, dimmed: savedURL == nil)
        x -= gap + labelBtnW
        let uploadProvider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        let canUpload = (uploadProvider == "gdrive" && GoogleDriveUploader.shared.isSignedIn) || (uploadProvider == "s3" && S3Uploader.shared.isConfigured)
        uploadBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        drawLabelButton(rect: uploadBtnRect, symbol: "icloud.and.arrow.up", label: L("Upload"), dimmed: !canUpload)
        let arrowW: CGFloat = 20
        x -= gap + labelBtnW + arrowW
        let fullSaveW = labelBtnW + arrowW
        let fullSaveRect = NSRect(x: x, y: btnY, width: fullSaveW, height: btnH)
        saveBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        saveArrowRect = NSRect(x: x + labelBtnW, y: btnY, width: arrowW, height: btnH)

        // Draw combined background
        ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: fullSaveRect, xRadius: 6, yRadius: 6).fill()

        // Draw save icon + label
        do {
            let iconSize: CGFloat = 12
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.85),
            ]
            let saveLabel = L("Save") as NSString
            let labelSize = saveLabel.size(withAttributes: attrs)
            let totalW = iconSize + 4 + labelSize.width
            let startX = saveBtnRect.midX - totalW / 2
            if let img = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    ToolbarLayout.iconColor.withAlphaComponent(0.85).setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: startX, y: saveBtnRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            saveLabel.draw(at: NSPoint(x: startX + iconSize + 4, y: saveBtnRect.midY - labelSize.height / 2), withAttributes: attrs)
        }

        // Draw separator line
        ToolbarLayout.iconColor.withAlphaComponent(0.2).setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: saveArrowRect.minX, y: saveArrowRect.minY + 4))
        sep.line(to: NSPoint(x: saveArrowRect.minX, y: saveArrowRect.maxY - 4))
        sep.lineWidth = 1
        sep.stroke()

        // Draw chevron in arrow portion
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { r in
                chevron.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(0.6).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: saveArrowRect.midX - chevron.size.width / 2, y: saveArrowRect.midY - chevron.size.height / 2,
                                    width: chevron.size.width, height: chevron.size.height))
        }
    }

    private func drawIconButton(rect: NSRect, symbol: String, accent: Bool, active: Bool = false, dimmed: Bool = false) {
        let bg = accent ? ToolbarLayout.accentColor : (active ? ToolbarLayout.accentColor.withAlphaComponent(0.4) : ToolbarLayout.iconColor.withAlphaComponent(dimmed ? 0.04 : 0.1))
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.25 : 1.0
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(alpha).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            let imgRect = NSRect(x: rect.midX - img.size.width / 2, y: rect.midY - img.size.height / 2,
                                  width: img.size.width, height: img.size.height)
            tinted.draw(in: imgRect)
        }
    }

    private func drawLabelButton(rect: NSRect, symbol: String, label: String, dimmed: Bool = false) {
        let bg = ToolbarLayout.iconColor.withAlphaComponent(dimmed ? 0.04 : 0.1)
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.25 : 0.85
        let iconSize: CGFloat = 12
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(alpha),
        ]
        let str = label as NSString
        let textSize = str.size(withAttributes: attrs)
        let iconGap: CGFloat = 8
        let totalW = iconSize + iconGap + textSize.width
        let startX = rect.midX - totalW / 2

        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(alpha).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: startX, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        str.draw(at: NSPoint(x: startX + iconSize + iconGap, y: rect.midY - textSize.height / 2), withAttributes: attrs)
    }

    /// Time labels sit BELOW the trim bar (AppKit y=down), in the labelsRowH
    /// gap between the trim bar and the effects scroll view.
    private var timeLabelY: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        ]
        let sampleHeight = ("0" as NSString).size(withAttributes: attrs).height
        // Center within labelsRowH (18pt) between the scroll view top and trim bottom.
        let scrollH = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        let labelsRowBottom = buttonsAreaH + scrollH + scrollToLabelsGap
        return labelsRowBottom + (labelsRowH - sampleHeight) / 2
    }

    private func drawTimeLabels() {
        let currentTime = currentPlaybackTime
        let trimDuration = trimEnd - trimStart

        let leftStr = formatTime(currentTime) as NSString
        let rightStr = String(format: L("%@ selected"), formatTime(trimDuration)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.5),
        ]

        leftStr.draw(at: NSPoint(x: timelinePad, y: timeLabelY), withAttributes: attrs)

        let rightSize = rightStr.size(withAttributes: attrs)
        rightStr.draw(at: NSPoint(x: bounds.width - timelinePad - rightSize.width, y: timeLabelY), withAttributes: attrs)
    }

    private func drawStatus(_ message: String) {
        let color: NSColor = statusIsError ? NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1.0) : .systemGreen
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let str = message as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: timeLabelY), withAttributes: attrs)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - floor(seconds)) * 10)
        return String(format: "%d:%02d.%d", m, s, ms)
    }

    // MARK: - Mouse

    // MARK: - Effects preview overlay

    /// Full sync: update the overlay's selection AND seek the preview to a
    /// time that makes editing intuitive. Call only when selection changes,
    /// not during a drag (seeking mid-drag stutters the decoder).
    private func updateEffectsOverlay() {
        refreshOverlaySelection()
        // Seek only on selection change, based on the newly-selected segment.
        if let id = selectedSegmentID {
            if let seg = zoomSegments.first(where: { $0.id == id }) {
                seekPreview(to: max(0, seg.startTime - 0.05))
            } else if let seg = censorSegments.first(where: { $0.id == id }) {
                seekPreview(to: (seg.startTime + seg.endTime) / 2)
            }
        }
    }

    /// Light sync: update the overlay's displayed rect + kind without seeking.
    /// Safe to call during an active drag or when a segment's properties
    /// change without the selection itself moving.
    private func refreshOverlaySelection() {
        guard let overlay = effectsOverlay else { return }
        if let id = selectedSegmentID {
            if let seg = zoomSegments.first(where: { $0.id == id }) {
                overlay.selection = .init(kind: .zoom, rect: rectForZoom(seg))
                return
            }
            if let seg = censorSegments.first(where: { $0.id == id }) {
                overlay.selection = .init(kind: .censor(seg.style), rect: seg.rect)
                return
            }
        }
        overlay.selection = nil
    }

    private func seekPreview(to t: Double) {
        guard let player = player else { return }
        if player.rate > 0 { player.pause() }
        let target = mapSourceTimeToPreviewClock(t)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Translate a source-asset time to the current player item's clock.
    /// When preview is composition-backed (cuts present) this collapses the
    /// cut ranges; otherwise it's a pass-through.
    fileprivate func mapSourceTimeToPreviewClock(_ sourceTime: Double) -> Double {
        guard previewUsesComposition else { return sourceTime }
        return previewSourceTimeToComp(sourceTime, against: player?.currentItem?.asset ?? asset ?? AVAsset(url: videoURL))
    }

    /// Inverse of `mapSourceTimeToPreviewClock`. Callers that read the
    /// current player time but want it in source-asset terms (e.g. to draw
    /// the playhead) should go through this.
    fileprivate func mapPreviewClockToSourceTime(_ previewTime: Double) -> Double {
        guard previewUsesComposition else { return previewTime }
        return previewCompTimeToSource(previewTime)
    }

    /// Representation of a zoom segment as a normalized rect. Shape is always
    /// a square of side 1/zoomLevel, centered on segment.center. Used only
    /// for display in the overlay — the underlying model still uses
    /// (center, zoomLevel) as its source of truth.
    private func rectForZoom(_ seg: VideoZoomSegment) -> CGRect {
        let side = 1.0 / max(seg.zoomLevel, 0.0001)
        let x = seg.center.x - side / 2
        let y = seg.center.y - side / 2
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Called when the overlay view reports a new normalized rect.
    /// Dispatches based on the currently-selected segment type.
    private func overlayRectChanged(_ rect: CGRect) {
        guard let id = selectedSegmentID else { return }
        savedURL = nil
        if let seg = zoomSegments.first(where: { $0.id == id }) {
            // Derive zoom level from rect size, clamp to model's range. Use
            // the longer side so the entire rect fits inside the zoom window.
            let side = max(rect.width, rect.height, 0.0001)
            let desiredZoom = 1.0 / side
            seg.zoomLevel = max(VideoZoomSegment.minZoom,
                                 min(VideoZoomSegment.maxZoom, desiredZoom))
            // Center on the rect midpoint
            seg.center = CGPoint(x: rect.midX, y: rect.midY)
        } else if let seg = censorSegments.first(where: { $0.id == id }) {
            seg.rect = VideoCensorSegment.clampedRect(rect)
        }
        applyZoomTransformForCurrentTime()
        effectsBand?.refreshAfterParentEdit()
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }


    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Trim handles (higher priority than zoom segments)
        let handleHitW: CGFloat = 16
        let startX = timelineRect.minX + CGFloat(trimStart / duration) * timelineRect.width
        let endX = timelineRect.minX + CGFloat(trimEnd / duration) * timelineRect.width

        if abs(point.x - startX) < handleHitW && abs(point.y - timelineRect.midY) < 25 {
            isDraggingStart = true; return
        }
        if abs(point.x - endX) < handleHitW && abs(point.y - timelineRect.midY) < 25 {
            isDraggingEnd = true; return
        }

        // Scrub timeline
        if timelineRect.insetBy(dx: 0, dy: -10).contains(point) {
            // Clicking the trim bar deselects any effect segment
            effectsBand?.clearSelection()
            isDraggingScrubber = true
            scrubTo(point: point)
            return
        }

        // Clicking outside the timeline also deselects
        effectsBand?.clearSelection()

        // Format toggle
        if formatMP4Rect.contains(point) && exportAsGIF {
            exportAsGIF = false; savedURL = nil; needsDisplay = true; return
        }
        if formatGIFRect.contains(point) && !exportAsGIF {
            exportAsGIF = true; savedURL = nil; needsDisplay = true; return
        }

        // Dimensions dropdown
        if dimensionsBtnRect.contains(point) && originalWidth > 0 {
            showDimensionsMenu(); return
        }

        // Quality dropdown
        if qualityBtnRect.contains(point) {
            showQualityMenu(); return
        }

        // Buttons
        if playBtnRect.contains(point) { togglePlayPause(); return }
        if muteBtnRect.contains(point) { toggleMute(); return }
        if saveArrowRect.contains(point) { showSaveMenu(); return }
        if saveBtnRect.contains(point) { saveVideo(); return }
        if uploadBtnRect.contains(point) { uploadVideo(); return }
        if finderBtnRect.contains(point) {
            if let url = savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return
        }
        if copyArrowRect.contains(point) { showCopyMenu(); return }
        if copyBtnRect.contains(point) { copyToClipboard(); return }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDraggingStart {
            let t = max(0, min(duration, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
            trimStart = min(t, trimEnd - 0.1)
            let target = mapSourceTimeToPreviewClock(trimStart)
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            needsDisplay = true
        } else if isDraggingEnd {
            let t = max(0, min(duration, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
            trimEnd = max(t, trimStart + 0.1)
            let target = mapSourceTimeToPreviewClock(trimEnd)
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            needsDisplay = true
        } else if isDraggingScrubber {
            scrubTo(point: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingStart = false
        isDraggingEnd = false
        isDraggingScrubber = false
    }

    private func scrubTo(point: NSPoint) {
        let t = max(trimStart, min(trimEnd, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
        let target = mapSourceTimeToPreviewClock(t)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }

    // MARK: - Actions

    private func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
        needsDisplay = true
    }

    private func togglePlayPause() {
        if isGIF {
            gifIsPlaying.toggle()
            gifImageView?.animates = gifIsPlaying
            if gifIsPlaying {
                gifPlaybackTime = trimStart
            }
            needsDisplay = true
            return
        }
        guard let player = player else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            let current = mapPreviewClockToSourceTime(CMTimeGetSeconds(player.currentTime()))
            if current < trimStart || current >= trimEnd - 0.1 {
                let target = mapSourceTimeToPreviewClock(trimStart)
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            }
            player.play()
        }
        needsDisplay = true
    }

    private func showStatus(_ msg: String, isError: Bool = false, persist: Bool = false) {
        statusMessage = msg
        statusIsError = isError
        statusTimer?.invalidate()
        if !persist {
            statusTimer = Timer.scheduledTimer(withTimeInterval: isError ? 6 : 3, repeats: false) { [weak self] _ in
                self?.statusMessage = nil
                self?.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    private func copyToClipboard() {
        // If GIF mode is selected but no GIF has been saved yet, convert to a temp GIF first
        if exportAsGIF && !isGIF && !(savedURL?.pathExtension.lowercased() == "gif") {
            showStatus(L("Converting to GIF…"))
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
            convertToGIF(destURL: tmpURL) { [weak self] success in
                guard let self = self, success else { return }
                self.copyGIFData(from: tmpURL)
            }
            return
        }

        let url = savedURL ?? videoURL
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if isGIF || url.pathExtension.lowercased() == "gif" {
            copyGIFData(from: url)
        } else {
            pasteboard.writeObjects([url as NSURL])
            showStatus(L("Copied to clipboard!"))
        }
    }

    private func copyGIFData(from url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let data = try? Data(contentsOf: url) {
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            item.setString(url.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        }
        showStatus(L("Copied to clipboard!"))
    }

    private func showCopyMenu() {
        let menu = NSMenu()
        let pathItem = NSMenuItem(title: L("Copy Path"), action: #selector(copyPathAction), keyEquivalent: "")
        pathItem.target = self
        menu.addItem(pathItem)
        let pos = NSPoint(x: copyArrowRect.minX, y: copyArrowRect.maxY)
        menu.popUp(positioning: nil, at: pos, in: self)
    }

    @objc private func copyPathAction() {
        let url = savedURL ?? videoURL
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showStatus(L("Path copied!"))
    }

    private func exportSession(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) -> AVAssetExportSession? {
        let needsScale = exportScale < 0.999
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty

        let composition = AVMutableComposition()
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }

        // Insert the kept source ranges (trim minus cuts) sequentially. Audio
        // tracks mirror the video inserts so audio and video stay in sync
        // across cuts.
        let keptRanges = VideoCuts.keptRanges(
            trimStart: CMTimeGetSeconds(timeRange.start),
            trimEnd: CMTimeGetSeconds(timeRange.end),
            cuts: cutSegments
        )
        let audioTracks = asset.tracks(withMediaType: .audio)
        var audioCompTracks: [AVMutableCompositionTrack] = []
        if !isMuted {
            for _ in audioTracks {
                if let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    audioCompTracks.append(compAudio)
                }
            }
        }
        var cursor = CMTime.zero
        for (srcStart, srcEnd) in keptRanges {
            let range = CMTimeRange(
                start: CMTime(seconds: srcStart, preferredTimescale: 600),
                end: CMTime(seconds: srcEnd, preferredTimescale: 600)
            )
            try? compositionVideoTrack.insertTimeRange(range, of: videoTrack, at: cursor)
            for (audioSrc, audioDst) in zip(audioTracks, audioCompTracks) {
                try? audioDst.insertTimeRange(range, of: audioSrc, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        session.outputURL = outputURL
        session.outputFileType = .mp4

        if needsScale || hasEffects {
            let naturalSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
            let (scaledW, scaledH) = VideoEncodingSettings.evenDimensions(
                width: abs(naturalSize.width) * exportScale,
                height: abs(naturalSize.height) * exportScale
            )
            let renderSize = CGSize(width: scaledW, height: scaledH)
            let totalDuration = CMTimeGetSeconds(composition.duration)
            let timeMap = timeMapForExport(compositionDuration: totalDuration)
            if hasEffects {
                session.videoComposition = buildEffectsVideoComposition(
                    for: composition,
                    videoTrack: compositionVideoTrack,
                    renderSize: renderSize,
                    timeMap: timeMap,
                    timeRangeDuration: totalDuration
                )
            } else {
                // Scale-only: no custom compositor needed, use a plain layer
                // instruction with a single transform.
                session.videoComposition = buildScaleOnlyComposition(
                    videoTrack: compositionVideoTrack,
                    renderSize: renderSize,
                    totalDuration: totalDuration
                )
            }
        }

        return session
    }

    private func saveVideo() {
        if exportAsGIF && !isGIF {
            // GIF mode: need Save As panel since extension changes
            saveVideoAs()
            return
        }
        guard let dirURL = SaveDirectoryAccess.resolveRecordingDirectoryIfAccessible() else {
            saveVideoAs()
            return
        }
        let ext = exportAsGIF ? "gif" : videoURL.pathExtension
        let name = videoURL.deletingPathExtension().lastPathComponent + ".\(ext)"
        let destURL = dirURL.appendingPathComponent(name)
        if exportAsGIF && !isGIF {
            convertToGIF(destURL: destURL)
        } else {
            saveToDestination(destURL, dirURL: dirURL)
        }
    }

    private func saveVideoAs() {
        let panel = NSSavePanel()
        let saveAsGIF = exportAsGIF && !isGIF
        panel.allowedContentTypes = saveAsGIF ? [.gif] : (isGIF ? [.gif] : [.mpeg4Movie])
        let ext = saveAsGIF ? "gif" : videoURL.pathExtension
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".\(ext)"
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        panel.level = .statusBar + 3
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            if saveAsGIF {
                self.convertToGIF(destURL: url)
            } else {
                self.saveToDestination(url, dirURL: nil)
            }
        }
    }

    private func showSaveMenu() {
        saveVideoAs()
    }

    private func showDimensionsMenu() {
        let menu = NSMenu()
        let w = originalWidth, h = originalHeight

        // Original (100%)
        let origItem = NSMenuItem(title: "\(w) × \(h)  (Original)", action: #selector(dimensionSelected(_:)), keyEquivalent: "")
        origItem.target = self
        origItem.tag = 100
        origItem.state = exportScale >= 0.999 ? .on : .off
        menu.addItem(origItem)

        menu.addItem(NSMenuItem.separator())

        // Preset percentages — only include if the result is at least 128px wide
        let presets: [(Int, String)] = [(75, "75%"), (50, "50%"), (33, "33%"), (25, "25%")]
        for (pct, label) in presets {
            let scaledW = w * pct / 100
            let scaledH = h * pct / 100
            guard scaledW >= 128 else { continue }
            // Round to even for codec compatibility
            let evenW = (scaledW / 2) * 2
            let evenH = (scaledH / 2) * 2
            let item = NSMenuItem(title: "\(evenW) × \(evenH)  (\(label))", action: #selector(dimensionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            item.state = abs(exportScale - CGFloat(pct) / 100.0) < 0.01 ? .on : .off
            menu.addItem(item)
        }

        let pos = NSPoint(x: dimensionsBtnRect.minX, y: dimensionsBtnRect.maxY)
        menu.popUp(positioning: nil, at: pos, in: self)
    }

    @objc private func dimensionSelected(_ sender: NSMenuItem) {
        exportScale = CGFloat(sender.tag) / 100.0
        savedURL = nil
        needsDisplay = true
    }

    private func showQualityMenu() {
        let menu = NSMenu()
        let options: [(VideoQuality, String)] = [
            (.high,   L("High")),
            (.medium, L("Medium")),
            (.low,    L("Low")),
        ]
        for (q, label) in options {
            let item = NSMenuItem(title: label, action: #selector(qualitySelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q.rawValue
            item.state = (q == exportQuality) ? .on : .off
            menu.addItem(item)
        }
        let pos = NSPoint(x: qualityBtnRect.minX, y: qualityBtnRect.maxY)
        menu.popUp(positioning: nil, at: pos, in: self)
    }

    @objc private func qualitySelected(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let q = VideoQuality(rawValue: raw) {
            exportQuality = q
            savedURL = nil
            needsDisplay = true
        }
    }

    private func convertToGIF(destURL: URL, completion: ((Bool) -> Void)? = nil) {
        guard let asset = asset else { completion?(false); return }
        showStatus(L("Processing GIF…"), persist: true)

        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)
        // GIF capped at 15fps
        let gifFPS = min(15, asset.tracks(withMediaType: .video).first.map { Int($0.nominalFrameRate.rounded()) } ?? 15)
        let scale = exportScale
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty

        // Build the effects-composition pipeline on the main thread before jumping
        // to background so the video composition builder sees our current state.
        var readerAsset: AVAsset = asset
        var readerVideoTrackOpt: AVAssetTrack? = asset.tracks(withMediaType: .video).first
        var readerTimeRange: CMTimeRange = timeRange
        var readerVideoComposition: AVMutableVideoComposition?
        var readerOutW = 0
        var readerOutH = 0
        if hasEffects, let vt = readerVideoTrackOpt {
            let comp = AVMutableComposition()
            if let cvt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                // Insert each kept source range sequentially at the growing
                // composition end. Without cuts this is a single insert equal
                // to [trimStart, trimEnd].
                let kept = VideoCuts.keptRanges(
                    trimStart: CMTimeGetSeconds(timeRange.start),
                    trimEnd: CMTimeGetSeconds(timeRange.end),
                    cuts: cutSegments
                )
                var compCursor = CMTime.zero
                for (srcStart, srcEnd) in kept {
                    let range = CMTimeRange(
                        start: CMTime(seconds: srcStart, preferredTimescale: 600),
                        end: CMTime(seconds: srcEnd, preferredTimescale: 600)
                    )
                    try? cvt.insertTimeRange(range, of: vt, at: compCursor)
                    compCursor = CMTimeAdd(compCursor, range.duration)
                }
                let natSize = vt.naturalSize.applying(vt.preferredTransform)
                let (outW, outH) = VideoEncodingSettings.evenDimensions(
                    width: abs(natSize.width) * scale,
                    height: abs(natSize.height) * scale
                )
                readerOutW = outW
                readerOutH = outH
                readerAsset = comp
                readerVideoTrackOpt = cvt
                readerTimeRange = CMTimeRange(start: .zero, duration: comp.duration)
                let timeMapEntries = VideoCuts.timeMap(for: kept).map { entry in
                    EffectsCompositionInstruction.TimeMapEntry(
                        compStart: entry.0, compEnd: entry.1, sourceOffset: entry.2
                    )
                }
                readerVideoComposition = buildEffectsVideoComposition(
                    for: comp,
                    videoTrack: cvt,
                    renderSize: CGSize(width: outW, height: outH),
                    timeMap: timeMapEntries,
                    timeRangeDuration: CMTimeGetSeconds(comp.duration)
                )
            }
        }

        DispatchQueue.global(qos: .background).async { [weak self] in
            do {
                let reader = try AVAssetReader(asset: readerAsset)
                guard let videoTrack = readerVideoTrackOpt else {
                    DispatchQueue.main.async {
                        self?.showStatus(L("No video track found"), isError: true)
                        completion?(false)
                    }
                    return
                }

                let readerOutput: AVAssetReaderOutput
                if let comp = readerVideoComposition {
                    let cOut = AVAssetReaderVideoCompositionOutput(
                        videoTracks: [videoTrack],
                        videoSettings: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferWidthKey as String: readerOutW,
                            kCVPixelBufferHeightKey as String: readerOutH,
                        ]
                    )
                    cOut.videoComposition = comp
                    cOut.alwaysCopiesSampleData = false
                    readerOutput = cOut
                } else {
                    var outputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    if scale < 0.999 {
                        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
                        let w = Int(abs(natSize.width) * scale) / 2 * 2
                        let h = Int(abs(natSize.height) * scale) / 2 * 2
                        outputSettings[kCVPixelBufferWidthKey as String] = w
                        outputSettings[kCVPixelBufferHeightKey as String] = h
                    }
                    let tOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                    tOut.alwaysCopiesSampleData = false
                    readerOutput = tOut
                }
                reader.timeRange = readerTimeRange
                reader.add(readerOutput)

                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
                let sourceFPS = Int(videoTrack.nominalFrameRate.rounded())
                let encoder = GIFEncoder(url: tmpURL, fps: gifFPS, sourceFPS: max(sourceFPS, gifFPS))
                reader.startReading()

                let durationSec = CMTimeGetSeconds(readerTimeRange.duration)
                let estimatedFrames = max(1, Int(durationSec * Double(sourceFPS)))
                var framesRead = 0
                var lastReportedPct = -1

                while reader.status == .reading {
                    autoreleasepool {
                        if let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                           let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                            encoder.addFrame(pixelBuffer)
                            framesRead += 1
                        }
                    }
                    // Update progress on main thread (reading = 0–50%, finalize = 50–100%)
                    let pct = min(50, framesRead * 50 / estimatedFrames)
                    if pct != lastReportedPct {
                        lastReportedPct = pct
                        DispatchQueue.main.async {
                            self?.showStatus(String(format: L("Processing GIF…") + " %d%%", pct), persist: true)
                        }
                    }
                }

                DispatchQueue.main.async {
                    self?.showStatus(L("Processing GIF…") + " 50%", persist: true)
                }
                encoder.finish()
                DispatchQueue.main.async {
                    self?.showStatus(L("Processing GIF…") + " 100%", persist: true)
                }

                // Move to destination
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.moveItem(at: tmpURL, to: destURL)

                DispatchQueue.main.async {
                    self?.savedURL = destURL
                    self?.showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                    self?.needsDisplay = true
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.showStatus(L("GIF conversion failed"), isError: true)
                    completion?(false)
                }
            }
        }
    }

    private func saveToDestination(_ destURL: URL, dirURL: URL?) {
        let needsTrim = trimStart > 0.01 || (duration - trimEnd) > 0.01
        let needsScale = exportScale < 0.999
        let needsRecompress = exportQuality != .high
        let needsEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty
        let needsCuts = !cutSegments.isEmpty
        let needsExport = needsTrim || isMuted || needsScale || needsRecompress || needsEffects || needsCuts

        if !needsExport {
            // No processing needed — copy temp file to destination
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.copyItem(at: videoURL, to: destURL)
                savedURL = destURL
                if let dirURL = dirURL { SaveDirectoryAccess.stopAccessing(url: dirURL) }
                showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                needsDisplay = true
            } catch {
                if dirURL != nil {
                    // Bookmarked directory failed — fall back to Save As
                    saveVideoAs()
                } else {
                    showStatus(L("Save failed"), isError: true)
                }
            }
            return
        }

        guard let asset = asset else { return }
        showStatus(L("Exporting..."))

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(videoURL.pathExtension)")
        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        let onCompletion: (Bool) -> Void = { [weak self] success in
            guard let self = self else { return }
            if success {
                try? FileManager.default.removeItem(at: destURL)
                do {
                    try FileManager.default.moveItem(at: tmpURL, to: destURL)
                    self.savedURL = destURL
                    if let dirURL = dirURL { SaveDirectoryAccess.stopAccessing(url: dirURL) }
                    self.showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                    self.needsDisplay = true
                } catch {
                    self.showStatus(L("Save failed"), isError: true)
                }
            } else {
                self.showStatus(L("Export failed"), isError: true)
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }

        if needsRecompress {
            reencodeExport(asset: asset, timeRange: timeRange, outputURL: tmpURL, completion: onCompletion)
        } else {
            guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: tmpURL) else {
                showStatus(L("Export failed"), isError: true)
                return
            }
            Task {
                await session.export()
                await MainActor.run { onCompletion(session.status == .completed) }
            }
        }
    }

    /// Re-encode pipeline with explicit bitrate control via AVAssetReader/Writer.
    /// Used when the user selects a non-High quality preset so the bitrate
    /// actually takes effect (AVAssetExportSession presets hardcode bitrate).
    private func reencodeExport(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL, completion: @escaping (Bool) -> Void) {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(false)
            return
        }

        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let srcW = abs(natSize.width)
        let srcH = abs(natSize.height)
        let (outW, outH) = VideoEncodingSettings.evenDimensions(width: srcW * exportScale, height: srcH * exportScale)
        let srcFPS = Int(videoTrack.nominalFrameRate.rounded())
        let fps = max(srcFPS, 1)

        let includeAudio = !isMuted
        let srcAudioTracks = asset.tracks(withMediaType: .audio)
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty
        let hasCuts = !cutSegments.isEmpty

        // When effects OR cuts exist we must route through a composition so
        // cuts actually skip frames and the compositor applies zoom + censor.
        // Otherwise we read raw scaled frames directly from the source track
        // and pull audio straight from the original asset.
        let readerAsset: AVAsset
        let readerVideoTrack: AVAssetTrack
        let readerAudioTracks: [AVAssetTrack]
        let readerTimeRange: CMTimeRange
        let readerComposition: AVMutableVideoComposition?
        if hasEffects || hasCuts {
            let comp = AVMutableComposition()
            guard let cvt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                completion(false); return
            }

            // Build audio comp-tracks mirroring the source. They're filled in
            // parallel with the video inserts below so audio stays in sync.
            var compAudioTracks: [AVMutableCompositionTrack] = []
            if includeAudio {
                for _ in srcAudioTracks {
                    if let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        compAudioTracks.append(ca)
                    }
                }
            }

            // Insert kept source ranges (trim minus cuts) sequentially.
            let kept = VideoCuts.keptRanges(
                trimStart: CMTimeGetSeconds(timeRange.start),
                trimEnd: CMTimeGetSeconds(timeRange.end),
                cuts: cutSegments
            )
            var compCursor = CMTime.zero
            for (srcStart, srcEnd) in kept {
                let range = CMTimeRange(
                    start: CMTime(seconds: srcStart, preferredTimescale: 600),
                    end: CMTime(seconds: srcEnd, preferredTimescale: 600)
                )
                try? cvt.insertTimeRange(range, of: videoTrack, at: compCursor)
                for (srcAT, dstAT) in zip(srcAudioTracks, compAudioTracks) {
                    try? dstAT.insertTimeRange(range, of: srcAT, at: compCursor)
                }
                compCursor = CMTimeAdd(compCursor, range.duration)
            }

            readerAsset = comp
            readerVideoTrack = cvt
            readerAudioTracks = compAudioTracks
            readerTimeRange = CMTimeRange(start: .zero, duration: comp.duration)
            if hasEffects {
                let timeMapEntries = VideoCuts.timeMap(for: kept).map { entry in
                    EffectsCompositionInstruction.TimeMapEntry(
                        compStart: entry.0, compEnd: entry.1, sourceOffset: entry.2
                    )
                }
                readerComposition = buildEffectsVideoComposition(
                    for: comp,
                    videoTrack: cvt,
                    renderSize: CGSize(width: outW, height: outH),
                    timeMap: timeMapEntries,
                    timeRangeDuration: CMTimeGetSeconds(comp.duration)
                )
            } else {
                readerComposition = nil
            }
        } else {
            readerAsset = asset
            readerVideoTrack = videoTrack
            readerAudioTracks = srcAudioTracks
            readerTimeRange = timeRange
            readerComposition = nil
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { completion(false); return }
            do {
                try? FileManager.default.removeItem(at: outputURL)
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
                let videoSettings = VideoEncodingSettings.outputSettings(
                    width: outW, height: outH, fps: fps,
                    codec: .h264, quality: self.exportQuality
                )
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = false
                // Orientation: the video composition path already produces upright
                // render-size frames, so don't re-apply preferredTransform.
                if !hasEffects {
                    videoInput.transform = videoTrack.preferredTransform
                }
                guard writer.canAdd(videoInput) else { completion(false); return }
                writer.add(videoInput)

                let reader = try AVAssetReader(asset: readerAsset)
                reader.timeRange = readerTimeRange

                // Video output: either composition output (zoom path) or direct
                // track output (scale-only path).
                let videoOutput: AVAssetReaderOutput
                if let comp = readerComposition {
                    let cOut = AVAssetReaderVideoCompositionOutput(
                        videoTracks: [readerVideoTrack],
                        videoSettings: [
                            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        ]
                    )
                    cOut.videoComposition = comp
                    cOut.alwaysCopiesSampleData = false
                    videoOutput = cOut
                } else {
                    var readerOutputSettings: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    ]
                    if self.exportScale < 0.999 {
                        readerOutputSettings[kCVPixelBufferWidthKey as String] = outW
                        readerOutputSettings[kCVPixelBufferHeightKey as String] = outH
                    }
                    let tOut = AVAssetReaderTrackOutput(track: readerVideoTrack, outputSettings: readerOutputSettings)
                    tOut.alwaysCopiesSampleData = false
                    videoOutput = tOut
                }
                guard reader.canAdd(videoOutput) else { completion(false); return }
                reader.add(videoOutput)

                var audioInputs: [AVAssetWriterInput] = []
                var audioOutputs: [AVAssetReaderTrackOutput] = []
                if includeAudio {
                    for track in readerAudioTracks {
                        let audioSettings: [String: Any] = [
                            AVFormatIDKey: kAudioFormatMPEG4AAC,
                            AVSampleRateKey: 48000,
                            AVNumberOfChannelsKey: 2,
                            AVEncoderBitRateKey: 128_000,
                        ]
                        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                        input.expectsMediaDataInRealTime = false
                        if writer.canAdd(input) { writer.add(input); audioInputs.append(input) }

                        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVLinearPCMBitDepthKey: 16,
                            AVLinearPCMIsFloatKey: false,
                            AVLinearPCMIsBigEndianKey: false,
                            AVLinearPCMIsNonInterleaved: false,
                        ])
                        output.alwaysCopiesSampleData = false
                        if reader.canAdd(output) { reader.add(output); audioOutputs.append(output) }
                    }
                }

                guard reader.startReading() else { completion(false); return }
                guard writer.startWriting() else { completion(false); return }
                writer.startSession(atSourceTime: .zero)

                let group = DispatchGroup()
                let videoQueue = DispatchQueue(label: "macshot.export.video")
                let audioQueue = DispatchQueue(label: "macshot.export.audio")

                // Pump video
                group.enter()
                videoInput.requestMediaDataWhenReady(on: videoQueue) {
                    while videoInput.isReadyForMoreMediaData {
                        guard reader.status == .reading,
                              let sample = videoOutput.copyNextSampleBuffer() else {
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                        // Shift PTS so the output starts at t=0
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        let shifted = CMTimeSubtract(pts, readerTimeRange.start)
                        if let retimed = sample.retimed(presentationTime: shifted) {
                            if !videoInput.append(retimed) {
                                videoInput.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    }
                }

                // Pump audio (each track independently)
                for (input, output) in zip(audioInputs, audioOutputs) {
                    group.enter()
                    input.requestMediaDataWhenReady(on: audioQueue) {
                        while input.isReadyForMoreMediaData {
                            guard reader.status == .reading,
                                  let sample = output.copyNextSampleBuffer() else {
                                input.markAsFinished()
                                group.leave()
                                return
                            }
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                            let shifted = CMTimeSubtract(pts, readerTimeRange.start)
                            if let retimed = sample.retimed(presentationTime: shifted) {
                                if !input.append(retimed) {
                                    input.markAsFinished()
                                    group.leave()
                                    return
                                }
                            }
                        }
                    }
                }

                group.notify(queue: .global(qos: .userInitiated)) {
                    writer.finishWriting {
                        let ok = (writer.status == .completed) && (reader.status != .failed)
                        DispatchQueue.main.async { completion(ok) }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    private func uploadVideo() {
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"

        if provider == "gdrive" && !GoogleDriveUploader.shared.isSignedIn {
            showStatus(L("Sign in to Google Drive in Settings"), isError: true)
            return
        }
        if provider == "s3" && !S3Uploader.shared.isConfigured {
            showStatus(L("Configure S3 in Settings"), isError: true)
            return
        }
        if provider != "gdrive" && provider != "s3" {
            showStatus(L("Video upload requires Google Drive or S3"), isError: true)
            return
        }

        let providerLabel = provider == "s3" ? "S3" : "Drive"
        showStatus(String(format: L("Uploading to %@... %d%%"), providerLabel, 0))

        let progressHandler: (Double) -> Void = { [weak self] fraction in
            self?.showStatus(String(format: L("Uploading to %@... %d%%"), providerLabel, Int(fraction * 100)))
        }

        let completionHandler: (Result<String, Error>) -> Void = { [weak self] result in
            switch result {
            case .success(let link):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                self?.showStatus(L("Uploaded! Link copied."))
            case .failure(let error):
                self?.showStatus(String(format: L("Upload failed: %@"), error.localizedDescription), isError: true)
            }
        }

        let uploadFileURL: (URL, Bool) -> Void = { fileURL, isTemp in
            let wrappedCompletion: (Result<String, Error>) -> Void = { result in
                if isTemp { try? FileManager.default.removeItem(at: fileURL) }
                completionHandler(result)
            }
            if provider == "s3" {
                S3Uploader.shared.onProgress = progressHandler
                S3Uploader.shared.uploadVideo(url: fileURL, completion: wrappedCompletion)
            } else {
                GoogleDriveUploader.shared.onProgress = progressHandler
                GoogleDriveUploader.shared.uploadVideo(url: fileURL, completion: wrappedCompletion)
            }
        }

        let needsTrim = trimStart > 0.01 || (duration - trimEnd) > 0.01
        let needsEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty
        let needsCuts = !cutSegments.isEmpty
        let needsExport = needsTrim || isMuted || needsEffects || needsCuts

        if !needsExport {
            uploadFileURL(videoURL, false)
        } else {
            guard let asset = asset else { return }
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("macshot_upload_\(UUID().uuidString).mp4")

            let timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                                        end: CMTime(seconds: trimEnd, preferredTimescale: 600))
            guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: tmpURL) else {
                showStatus(L("Export failed"), isError: true)
                return
            }

            Task {
                await session.export()
                await MainActor.run {
                    guard session.status == .completed else {
                        self.showStatus(L("Export failed"), isError: true)
                        return
                    }
                    uploadFileURL(tmpURL, true)
                }
            }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // Space
            togglePlayPause()
        case 123: // Left arrow — step back one frame
            stepFrame(forward: false)
        case 124: // Right arrow — step forward one frame
            stepFrame(forward: true)
        default:
            // Segment-related keys (Delete, +/-) are handled by EffectsBandView
            // when it's first responder; fall through here.
            super.keyDown(with: event)
        }
    }


    /// Rebuild the AVPlayerItem's videoComposition so live playback reflects
    /// the current zoom + censor segments. Also used when editing segments
    /// during playback — AVPlayer picks up composition changes on the next frame.
    ///
    /// When there are no cuts the preview plays directly off the original
    /// asset (segment times align with the asset clock so `timeMap` is a
    /// pass-through). When there are cuts the preview plays off a composition
    /// whose video+audio tracks contain only the kept ranges — that way cut
    /// ranges are physically skipped during playback.
    ///
    /// **Important:** swapping the player item causes a black flash while
    /// AVPlayer re-initializes its rendering pipeline, so we only do it when
    /// the cut *topology* changes (adding/removing cuts, or dragging a cut's
    /// boundaries). Rect edits on existing zoom/censor segments just update
    /// the videoComposition on the current item — cheap and flicker-free.
    fileprivate func applyZoomTransformForCurrentTime() {
        guard let player = player, let asset = asset else { return }

        let hasCuts = !cutSegments.isEmpty
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty
        // Fingerprint of the current cut set. When it hasn't changed we can
        // keep the existing composition-backed player item and only refresh
        // its videoComposition.
        let cutFingerprint = cutSegmentsFingerprint()

        // Fast path: nothing to apply, fall back to the original asset with
        // no videoComposition. Only swap items if we're currently on a
        // composition-backed item.
        if !hasCuts && !hasEffects {
            if previewUsesComposition {
                swapPreviewPlayerItem(asset: asset, videoComposition: nil)
                previewUsesComposition = false
                previewCompositionCutFingerprint = ""
            } else {
                player.currentItem?.videoComposition = nil
            }
            return
        }

        // No cuts: stay on the original asset and only attach the effects
        // composition — much cheaper than rebuilding the player item.
        if !hasCuts {
            if previewUsesComposition {
                swapPreviewPlayerItem(asset: asset, videoComposition: nil)
                previewUsesComposition = false
                previewCompositionCutFingerprint = ""
            }
            if hasEffects {
                player.currentItem?.videoComposition = buildEffectsVideoComposition(
                    for: asset,
                    videoTrack: asset.tracks(withMediaType: .video).first,
                    renderSize: nil,
                    timeMap: singleShiftTimeMap(shift: 0, duration: CMTimeGetSeconds(asset.duration)),
                    timeRangeDuration: CMTimeGetSeconds(asset.duration)
                )
            } else {
                player.currentItem?.videoComposition = nil
            }
            return
        }

        // Cuts exist. If we're already on a cut-backed composition whose
        // cut topology matches what we want, just refresh the effects
        // videoComposition on the existing item — no player-item swap
        // means no black flash.
        if previewUsesComposition,
           previewCompositionCutFingerprint == cutFingerprint,
           let currentItem = player.currentItem,
           let compAsset = currentItem.asset as? AVMutableComposition,
           let cvt = compAsset.tracks(withMediaType: .video).first {
            if hasEffects {
                let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: duration, cuts: cutSegments)
                let timeMapEntries = VideoCuts.timeMap(for: kept).map { entry in
                    EffectsCompositionInstruction.TimeMapEntry(
                        compStart: entry.0, compEnd: entry.1, sourceOffset: entry.2
                    )
                }
                currentItem.videoComposition = buildEffectsVideoComposition(
                    for: compAsset,
                    videoTrack: cvt,
                    renderSize: nil,
                    timeMap: timeMapEntries,
                    timeRangeDuration: CMTimeGetSeconds(compAsset.duration)
                )
            } else {
                currentItem.videoComposition = nil
            }
            return
        }

        // Cut topology actually changed — rebuild the composition-backed
        // player item. Also covers the first transition from original-asset
        // preview into cut-preview.
        let comp = AVMutableComposition()
        guard let vt = asset.tracks(withMediaType: .video).first,
              let cvt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }
        var compAudioTracks: [AVMutableCompositionTrack] = []
        for _ in asset.tracks(withMediaType: .audio) {
            if let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                compAudioTracks.append(ca)
            }
        }
        // Use the full asset duration as the "trim" here so preview cuts
        // apply globally, independent of the trim markers.
        let kept = VideoCuts.keptRanges(
            trimStart: 0,
            trimEnd: duration,
            cuts: cutSegments
        )
        var cursor = CMTime.zero
        for (srcStart, srcEnd) in kept {
            let range = CMTimeRange(
                start: CMTime(seconds: srcStart, preferredTimescale: 600),
                end: CMTime(seconds: srcEnd, preferredTimescale: 600)
            )
            try? cvt.insertTimeRange(range, of: vt, at: cursor)
            for (srcAT, dstAT) in zip(asset.tracks(withMediaType: .audio), compAudioTracks) {
                try? dstAT.insertTimeRange(range, of: srcAT, at: cursor)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }

        var videoComp: AVMutableVideoComposition?
        if hasEffects {
            let timeMapEntries = VideoCuts.timeMap(for: kept).map { entry in
                EffectsCompositionInstruction.TimeMapEntry(
                    compStart: entry.0, compEnd: entry.1, sourceOffset: entry.2
                )
            }
            videoComp = buildEffectsVideoComposition(
                for: comp,
                videoTrack: cvt,
                renderSize: nil,
                timeMap: timeMapEntries,
                timeRangeDuration: CMTimeGetSeconds(comp.duration)
            )
        }
        swapPreviewPlayerItem(asset: comp, videoComposition: videoComp)
        previewUsesComposition = true
        previewCompositionCutFingerprint = cutFingerprint
    }

    /// Stable identifier for the current cut set — order-independent string
    /// summarizing each cut's `[start, end]`. Rect/style edits on zoom or
    /// censor segments don't affect this, so they won't trigger a player
    /// item rebuild.
    private func cutSegmentsFingerprint() -> String {
        guard !cutSegments.isEmpty else { return "" }
        return cutSegments
            .map { String(format: "%.4f-%.4f", $0.startTime, $0.endTime) }
            .sorted()
            .joined(separator: "|")
    }

    /// Snapshot of the cut topology used to build `player.currentItem` when
    /// that item is a cut-stripped composition. Compared against the current
    /// fingerprint to decide whether a player-item swap is needed.
    private var previewCompositionCutFingerprint = ""

    /// Replace the player's current item with a new one backed by `asset`,
    /// preserving playback position and rate. Preview seeks target the source
    /// asset clock, so we map the current time through the cut-aware time
    /// map before resuming.
    private func swapPreviewPlayerItem(asset: AVAsset, videoComposition: AVMutableVideoComposition?) {
        guard let player = player else { return }
        let wasPlaying = player.rate != 0
        let prevRate = player.rate
        let prevSourceTime: Double = {
            if let current = player.currentItem {
                let t = CMTimeGetSeconds(current.currentTime())
                return previewUsesComposition ? previewCompTimeToSource(t) : t
            }
            return trimStart
        }()

        let newItem = AVPlayerItem(asset: asset)
        newItem.videoComposition = videoComposition
        player.replaceCurrentItem(with: newItem)

        // Map source time → target item's clock. The comp item's clock is
        // "kept-ranges concatenated from 0". Outside of preview-comp mode
        // (straight asset), source == comp time.
        let targetT: Double
        if videoComposition != nil || asset is AVMutableComposition {
            targetT = previewSourceTimeToComp(prevSourceTime, against: asset)
        } else {
            targetT = prevSourceTime
        }
        player.seek(to: CMTime(seconds: targetT, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.rate = prevRate }
    }

    /// Convert a preview composition-clock time to source-asset time using
    /// the current cuts.
    private func previewCompTimeToSource(_ compTime: Double) -> Double {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: duration, cuts: cutSegments)
        let entries = VideoCuts.timeMap(for: kept)
        for (compStart, compEnd, offset) in entries where compTime >= compStart && compTime < compEnd {
            return compTime + offset
        }
        if let last = entries.last, compTime >= last.1 {
            return compTime + last.2
        }
        return compTime
    }

    /// Inverse of `previewCompTimeToSource`. Clamps to the nearest kept
    /// range when `sourceTime` falls inside a cut.
    private func previewSourceTimeToComp(_ sourceTime: Double, against asset: AVAsset) -> Double {
        let kept = VideoCuts.keptRanges(trimStart: 0, trimEnd: duration, cuts: cutSegments)
        var cursor: Double = 0
        for (srcStart, srcEnd) in kept {
            if sourceTime < srcStart {
                return cursor
            }
            if sourceTime <= srcEnd {
                return cursor + (sourceTime - srcStart)
            }
            cursor += srcEnd - srcStart
        }
        return cursor
    }

    /// True when the player's current item is a cut-stripped composition
    /// (so its clock no longer matches the source asset).
    private var previewUsesComposition = false

    /// Build an `AVMutableVideoComposition` driven by `EffectsVideoCompositor`.
    /// The compositor renders zoom + censor segments per frame via Core Image,
    /// so motion is smooth and blur/pixelate can coexist with zoom in a single
    /// pass.
    ///
    /// - Parameters:
    ///   - asset: Asset whose tracks are referenced (may be a composition).
    ///   - videoTrack: Specific track to instrument. Must belong to `asset`.
    ///     If nil, picks the first video track.
    ///   - renderSize: Output size. Pass nil to use the video track's natural
    ///     (orientation-applied) size.
    ///   - timeShift: Seconds to subtract from segment times to put them on
    ///     the composition's clock. Export sets this to `trimStart`.
    ///   - timeRangeDuration: Total composition length in seconds (composition
    ///     clock). Used for the instruction timeRange.
    /// Simple composition for the scale-only export path (no zoom, no censor).
    /// Applies preferredTransform + uniform scale via setTransform — cheap, no
    /// custom compositor cost.
    private func buildScaleOnlyComposition(videoTrack: AVAssetTrack, renderSize: CGSize, totalDuration: Double) -> AVMutableVideoComposition {
        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let scaleX = renderSize.width / abs(natSize.width)
        let scaleY = renderSize.height / abs(natSize.height)
        let transform = videoTrack.preferredTransform
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: totalDuration, preferredTimescale: 600))
        instruction.backgroundColor = NSColor.black.cgColor

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        let fps = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        return composition
    }

    /// Build an AVMutableVideoComposition backed by the custom effects
    /// compositor.
    ///
    /// - Parameters:
    ///   - asset: the asset (often an AVMutableComposition) whose track we
    ///     read. Its track IDs must match `videoTrack`.
    ///   - videoTrack: the specific track to read from.
    ///   - renderSize: nil means "use natural-size rendering."
    ///   - timeMap: composition-time → source-asset-time mapping. Callers
    ///     without cuts pass a single entry spanning the whole composition.
    ///   - timeRangeDuration: total length (in composition time) of the
    ///     instruction's timeRange.
    private func buildEffectsVideoComposition(for asset: AVAsset, videoTrack: AVAssetTrack?, renderSize: CGSize?, timeMap: [EffectsCompositionInstruction.TimeMapEntry], timeRangeDuration: Double) -> AVMutableVideoComposition? {
        let track = videoTrack ?? asset.tracks(withMediaType: .video).first
        guard let videoTrack = track else { return nil }
        let natSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let naturalW = abs(natSize.width)
        let naturalH = abs(natSize.height)
        let renderW = renderSize?.width ?? naturalW
        let renderH = renderSize?.height ?? naturalH

        // Skip composition entirely when there's nothing to render — callers
        // should already guard on this, but being explicit avoids shipping a
        // custom compositor through the pipeline unnecessarily.
        guard !zoomSegments.isEmpty || !censorSegments.isEmpty else {
            return nil
        }

        // Bake orientation + scale into one transform. The compositor applies
        // it to the raw source buffer to produce a render-space CIImage.
        let scaleX = renderW / naturalW
        let scaleY = renderH / naturalH
        let baseTransform = videoTrack.preferredTransform
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Snapshot segments *by value* into plain arrays. The compositor runs
        // on background queues; we must not share main-actor state with it.
        let zoomSnapshot = zoomSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        let censorSnapshot = censorSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }

        let instruction = EffectsCompositionInstruction(
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: timeRangeDuration, preferredTimescale: 600)
            ),
            videoTrackID: videoTrack.trackID,
            naturalSize: CGSize(width: naturalW, height: naturalH),
            renderSize: CGSize(width: renderW, height: renderH),
            baseTransform: baseTransform,
            timeMap: timeMap,
            zoomSegments: zoomSnapshot,
            censorSegments: censorSnapshot
        )

        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = EffectsVideoCompositor.self
        composition.instructions = [instruction]
        composition.renderSize = CGSize(width: renderW, height: renderH)
        let fps = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        return composition
    }

    /// Convenience: build a single-entry time map from a scalar shift. All
    /// existing non-cut callers use this.
    private func singleShiftTimeMap(shift: Double, duration: Double) -> [EffectsCompositionInstruction.TimeMapEntry] {
        return [.init(compStart: 0, compEnd: duration, sourceOffset: shift)]
    }

    /// Map composition-time → source-asset-time for the standard export path
    /// (trim + cuts). `compositionDuration` is the composition's actual
    /// duration (already shortened by cuts).
    private func timeMapForExport(compositionDuration: Double) -> [EffectsCompositionInstruction.TimeMapEntry] {
        let kept = VideoCuts.keptRanges(
            trimStart: trimStart,
            trimEnd: trimEnd,
            cuts: cutSegments
        )
        let entries = VideoCuts.timeMap(for: kept)
        if entries.isEmpty {
            // Fall back to a passthrough single-entry map (should not happen
            // when the caller already has a non-zero composition duration).
            return singleShiftTimeMap(shift: trimStart, duration: compositionDuration)
        }
        return entries.map {
            EffectsCompositionInstruction.TimeMapEntry(compStart: $0.0, compEnd: $0.1, sourceOffset: $0.2)
        }
    }

    private func stepFrame(forward: Bool) {
        guard let player = player else { return }
        // Pause if playing
        if player.rate > 0 { player.pause(); needsDisplay = true }

        let fps = asset?.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30
        let frameDuration = 1.0 / Double(fps)
        let currentSource = mapPreviewClockToSourceTime(CMTimeGetSeconds(player.currentTime()))
        let targetSource = forward
            ? min(currentSource + frameDuration, trimEnd)
            : max(currentSource - frameDuration, trimStart)
        let target = mapSourceTimeToPreviewClock(targetSource)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }

    // MARK: - EffectsBandView integration

    /// Compute the scroll view's visible height for a given row count,
    /// capped at `effectsVisibleRowCount` rows so the editor window doesn't
    /// grow beyond a sensible limit. Matches `EffectsBandView.intrinsicContentSize`
    /// including its top/bottom padding so resize handles stay visible.
    fileprivate func effectsScrollViewHeight(forRowCount rows: Int) -> CGFloat {
        let visible = max(1, min(effectsVisibleRowCount, rows))
        // (visible × stride − gap) + 2× vertical inset (matches EffectsBandView.verticalInset = 4)
        return CGFloat(visible) * effectsRowStride - 2 + 8
    }
}

extension VideoEditorView: EffectsBandViewDelegate {
    func effectsBandDidMutate(_ view: EffectsBandView) {
        savedURL = nil
        applyZoomTransformForCurrentTime()
        needsDisplay = true
    }

    func effectsBand(_ view: EffectsBandView, didSelectSegment segmentID: UUID?) {
        updateEffectsOverlay()
    }

    func effectsBand(_ view: EffectsBandView, didChangeRowCount rowCount: Int) {
        currentEffectRowCount = rowCount
        let newScrollH = effectsScrollViewHeight(forRowCount: rowCount)
        effectsBandHeightConstraint?.animator().constant = newScrollH
        // Player view also shrinks so the whole controls band (including the
        // trim timeline) has room to grow upward.
        playerBottomConstraint?.animator().constant = -controlsH
        needsDisplay = true
    }

    func effectsBand(_ view: EffectsBandView, showStatus message: String, isError: Bool) {
        showStatus(message, isError: isError)
    }
}

private extension CMSampleBuffer {
    /// Returns a copy with a new presentation timestamp. Duration is preserved.
    func retimed(presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(self),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: self,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        return status == noErr ? out : nil
    }
}
