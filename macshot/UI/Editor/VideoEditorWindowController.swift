import Cocoa
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Standalone video editor window for trimming and exporting recorded videos.
final class VideoEditorWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var editorView: VideoEditorView?
    private static var activeControllers: [VideoEditorWindowController] = []

    static func open(url: URL) {
        let controller = VideoEditorWindowController()
        controller.show(url: url)
        activeControllers.append(controller)
        if activeControllers.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func show(url: URL) {
        guard let screen = NSScreen.main else { return }

        // Size window to fit content, capped at 60% of screen
        let controlsH: CGFloat = 130
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
        let winW = max(480, contentW * scale)
        let winH = max(360, contentH * scale + controlsH)
        let winX = screen.frame.midX - winW / 2
        let winY = screen.frame.midY - winH / 2

        let win = NSWindow(
            contentRect: NSRect(x: winX, y: winY, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "macshot Video Editor"
        win.minSize = NSSize(width: 600, height: 400)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.backgroundColor = NSColor(white: 0.12, alpha: 1)

        let view = VideoEditorView(frame: NSRect(x: 0, y: 0, width: winW, height: winH), videoURL: url)
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
            let hasOtherWindows = NSApp.windows.contains { $0 !== closingWindow && $0.isVisible && $0.styleMask.contains(.titled) }
            if !hasOtherWindows {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

// MARK: - VideoEditorView

private final class VideoEditorView: NSView {

    private let videoURL: URL
    private let isGIF: Bool
    private var player: AVPlayer?
    private var playerView: AVPlayerView?
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

    // Button rects
    private var playBtnRect: NSRect = .zero
    private var saveBtnRect: NSRect = .zero
    private var saveArrowRect: NSRect = .zero
    private var uploadBtnRect: NSRect = .zero
    private var copyBtnRect: NSRect = .zero
    private var muteBtnRect: NSRect = .zero
    private var finderBtnRect: NSRect = .zero
    private var isMuted: Bool = false
    private var savedURL: URL?
    private var statusMessage: String?
    private var statusIsError: Bool = false
    private var statusTimer: Timer?

    // Layout
    private let controlsH: CGFloat = 130
    private let timelinePad: CGFloat = 20

    init(frame: NSRect, videoURL: URL) {
        self.videoURL = videoURL
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
        let item = AVPlayerItem(url: videoURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        let pv = AVPlayerView()
        pv.player = player
        pv.controlsStyle = .none
        pv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pv)

        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: topAnchor),
            pv.leadingAnchor.constraint(equalTo: leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: trailingAnchor),
            pv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -controlsH),
        ])
        playerView = pv

        // Observe playback position
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self = self, !self.isDraggingScrubber else { return }
            let t = CMTimeGetSeconds(time)
            if t >= self.trimEnd {
                self.player?.pause()
                self.player?.seek(to: CMTime(seconds: self.trimStart, preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            self.needsDisplay = true
        }

        needsDisplay = true
    }

    func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        player?.pause()
        player = nil
        playerView?.player = nil
        gifPlaybackTimer?.invalidate()
        gifPlaybackTimer = nil
        // Clean up temp recording file
        try? FileManager.default.removeItem(at: videoURL)
    }

    private var currentPlaybackTime: Double {
        if isGIF {
            return gifPlaybackTime
        } else {
            return CMTimeGetSeconds(player?.currentTime() ?? .zero)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Controls background
        let controlsBg = NSRect(x: 0, y: 0, width: bounds.width, height: controlsH)
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(rect: controlsBg).fill()

        // Separator
        NSColor.white.withAlphaComponent(0.1).setFill()
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
        let tlY: CGFloat = 55
        let tlH: CGFloat = 30
        timelineRect = NSRect(x: tlX, y: tlY, width: tlW, height: tlH)

        // Track background
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: timelineRect, xRadius: 4, yRadius: 4).fill()

        // Trimmed region
        let startX = tlX + CGFloat(trimStart / duration) * tlW
        let endX = tlX + CGFloat(trimEnd / duration) * tlW
        let trimRect = NSRect(x: startX, y: tlY, width: endX - startX, height: tlH)
        NSColor.systemPurple.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: trimRect, xRadius: 2, yRadius: 2).fill()

        // Trim handles
        let handleW: CGFloat = 10
        let handleH: CGFloat = tlH + 8

        // Start handle
        let startHandleRect = NSRect(x: startX - handleW / 2, y: tlY - 4, width: handleW, height: handleH)
        NSColor.systemPurple.setFill()
        NSBezierPath(roundedRect: startHandleRect, xRadius: 3, yRadius: 3).fill()
        drawHandleGrip(in: startHandleRect)

        // End handle
        let endHandleRect = NSRect(x: endX - handleW / 2, y: tlY - 4, width: handleW, height: handleH)
        NSColor.systemPurple.setFill()
        NSBezierPath(roundedRect: endHandleRect, xRadius: 3, yRadius: 3).fill()
        drawHandleGrip(in: endHandleRect)

        // Playhead
        if player != nil || isGIF {
            let currentTime = currentPlaybackTime
            let playheadX = max(tlX, min(tlX + tlW, tlX + CGFloat(currentTime / duration) * tlW))
            NSColor.white.setFill()
            let playheadRect = NSRect(x: playheadX - 1, y: tlY - 2, width: 2, height: tlH + 4)
            NSBezierPath(roundedRect: playheadRect, xRadius: 1, yRadius: 1).fill()

            // Playhead circle (clamped to timeline bounds)
            let circleR: CGFloat = 5
            let circleX = max(tlX + circleR, min(tlX + tlW - circleR, playheadX))
            NSBezierPath(ovalIn: NSRect(x: circleX - circleR, y: tlY + tlH + 2, width: circleR * 2, height: circleR * 2)).fill()
        }
    }

    private func drawHandleGrip(in rect: NSRect) {
        NSColor.white.withAlphaComponent(0.5).setStroke()
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
        // Use compact (icon-only) buttons when window is narrow
        let compact = bounds.width < 700
        let labelBtnW: CGFloat = compact ? iconBtnW : 100

        // Left group: play, mute
        var x: CGFloat = timelinePad

        let isPlaying = isGIF ? gifIsPlaying : (player?.rate ?? 0 > 0)
        playBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: playBtnRect, symbol: isPlaying ? "pause.fill" : "play.fill", accent: true)
        x += iconBtnW + gap

        muteBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: muteBtnRect, symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accent: false, active: isMuted)
        x += iconBtnW + gap

        // File info (hidden when window is too narrow)
        if !compact {
            let infoAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
            ]
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size] as? Int) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
            let ext = videoURL.pathExtension.uppercased()
            let fpsValue = asset?.tracks(withMediaType: .video).first?.nominalFrameRate ?? 0
            let fpsStr = fpsValue > 0 ? "  ·  \(Int(fpsValue.rounded()))fps" : ""
            var resStr = ""
            if let track = asset?.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                resStr = "  ·  \(Int(abs(size.width)))×\(Int(abs(size.height)))"
            } else if isGIF, let src = CGImageSourceCreateWithURL(videoURL as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                resStr = "  ·  \(img.width)×\(img.height)"
            }
            let infoStr = "\(ext)  ·  \(sizeStr)\(fpsStr)\(resStr)" as NSString
            let infoSize = infoStr.size(withAttributes: infoAttrs)
            infoStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - infoSize.height) / 2), withAttributes: infoAttrs)
        }

        // Right group: save, upload, finder, copy
        x = bounds.width - timelinePad
        x -= labelBtnW
        copyBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        if compact {
            drawIconButton(rect: copyBtnRect, symbol: "doc.on.doc", accent: false)
        } else {
            drawLabelButton(rect: copyBtnRect, symbol: "doc.on.doc", label: "Copy Path")
        }
        x -= gap + iconBtnW
        finderBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: finderBtnRect, symbol: "folder", accent: false, dimmed: savedURL == nil)
        x -= gap + labelBtnW
        let uploadProvider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        let canUpload = (uploadProvider == "gdrive" && GoogleDriveUploader.shared.isSignedIn) || (uploadProvider == "s3" && S3Uploader.shared.isConfigured)
        uploadBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        if compact {
            drawIconButton(rect: uploadBtnRect, symbol: "icloud.and.arrow.up", accent: false)
        } else {
            drawLabelButton(rect: uploadBtnRect, symbol: "icloud.and.arrow.up", label: "Upload", dimmed: !canUpload)
        }
        let arrowW: CGFloat = 20
        x -= gap + labelBtnW + arrowW
        let fullSaveW = labelBtnW + arrowW
        let fullSaveRect = NSRect(x: x, y: btnY, width: fullSaveW, height: btnH)
        saveBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        saveArrowRect = NSRect(x: x + labelBtnW, y: btnY, width: arrowW, height: btnH)

        // Draw combined background
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: fullSaveRect, xRadius: 6, yRadius: 6).fill()

        // Draw save icon + label in left portion
        if compact {
            if let img = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                let imgRect = NSRect(x: saveBtnRect.midX - img.size.width / 2, y: saveBtnRect.midY - img.size.height / 2,
                                      width: img.size.width, height: img.size.height)
                tinted.draw(in: imgRect)
            }
        } else {
            let iconSize: CGFloat = 12
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let labelSize = ("Save" as NSString).size(withAttributes: attrs)
            let totalW = iconSize + 4 + labelSize.width
            let startX = saveBtnRect.midX - totalW / 2
            if let img = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.withAlphaComponent(0.85).setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: startX, y: saveBtnRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            ("Save" as NSString).draw(at: NSPoint(x: startX + iconSize + 4, y: saveBtnRect.midY - labelSize.height / 2), withAttributes: attrs)
        }

        // Draw separator line
        NSColor.white.withAlphaComponent(0.2).setStroke()
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
                NSColor.white.withAlphaComponent(0.6).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: saveArrowRect.midX - chevron.size.width / 2, y: saveArrowRect.midY - chevron.size.height / 2,
                                    width: chevron.size.width, height: chevron.size.height))
        }
    }

    private func drawIconButton(rect: NSRect, symbol: String, accent: Bool, active: Bool = false, dimmed: Bool = false) {
        let bg = accent ? NSColor.systemPurple : (active ? NSColor.systemPurple.withAlphaComponent(0.4) : NSColor.white.withAlphaComponent(dimmed ? 0.04 : 0.1))
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.25 : 1.0
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.white.withAlphaComponent(alpha).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            let imgRect = NSRect(x: rect.midX - img.size.width / 2, y: rect.midY - img.size.height / 2,
                                  width: img.size.width, height: img.size.height)
            tinted.draw(in: imgRect)
        }
    }

    private func drawLabelButton(rect: NSRect, symbol: String, label: String, dimmed: Bool = false) {
        let bg = NSColor.white.withAlphaComponent(dimmed ? 0.04 : 0.1)
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.25 : 0.85
        let iconSize: CGFloat = 12
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
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
                NSColor.white.withAlphaComponent(alpha).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: startX, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        str.draw(at: NSPoint(x: startX + iconSize + iconGap, y: rect.midY - textSize.height / 2), withAttributes: attrs)
    }

    private func drawTimeLabels() {
        let currentTime = currentPlaybackTime
        let trimDuration = trimEnd - trimStart

        let leftStr = formatTime(currentTime) as NSString
        let rightStr = "\(formatTime(trimDuration)) selected" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]

        let leftSize = leftStr.size(withAttributes: attrs)
        leftStr.draw(at: NSPoint(x: timelinePad, y: 90), withAttributes: attrs)

        let rightSize = rightStr.size(withAttributes: attrs)
        rightStr.draw(at: NSPoint(x: bounds.width - timelinePad - rightSize.width, y: 90), withAttributes: attrs)
    }

    private func drawStatus(_ message: String) {
        let color: NSColor = statusIsError ? NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1.0) : .systemGreen
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let str = message as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 90), withAttributes: attrs)
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - floor(seconds)) * 10)
        return String(format: "%d:%02d.%d", m, s, ms)
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Trim handles
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
            isDraggingScrubber = true
            scrubTo(point: point)
            return
        }

        // Buttons
        if playBtnRect.contains(point) { togglePlayPause(); return }
        if muteBtnRect.contains(point) { toggleMute(); return }
        if saveArrowRect.contains(point) { saveVideoAs(); return }
        if saveBtnRect.contains(point) { saveVideo(); return }
        if uploadBtnRect.contains(point) { uploadVideo(); return }
        if finderBtnRect.contains(point) {
            if let url = savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return
        }
        if copyBtnRect.contains(point) { copyPath(); return }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let t = max(0, min(duration, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))

        if isDraggingStart {
            trimStart = min(t, trimEnd - 0.1)
            player?.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            needsDisplay = true
        } else if isDraggingEnd {
            trimEnd = max(t, trimStart + 0.1)
            player?.seek(to: CMTime(seconds: trimEnd, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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
            let current = CMTimeGetSeconds(player.currentTime())
            if current < trimStart || current >= trimEnd - 0.1 {
                player.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600))
            }
            player.play()
        }
        needsDisplay = true
    }

    private func showStatus(_ msg: String, isError: Bool = false) {
        statusMessage = msg
        statusIsError = isError
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: isError ? 6 : 3, repeats: false) { [weak self] _ in
            self?.statusMessage = nil
            self?.needsDisplay = true
        }
        needsDisplay = true
    }

    private func copyPath() {
        let url = savedURL ?? videoURL
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showStatus("Path copied!")
    }

    private func exportSession(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) -> AVAssetExportSession? {
        // If muted, create a composition without audio tracks
        if isMuted {
            let composition = AVMutableComposition()
            guard let videoTrack = asset.tracks(withMediaType: .video).first,
                  let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            try? compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return nil }
            session.outputURL = outputURL
            session.outputFileType = .mp4
            return session
        } else {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return nil }
            session.outputURL = outputURL
            session.outputFileType = .mp4
            session.timeRange = timeRange
            return session
        }
    }

    private func saveVideo() {
        guard let dirURL = SaveDirectoryAccess.resolveRecordingDirectoryIfAccessible() else {
            // No valid bookmark — fall back to Save As panel
            saveVideoAs()
            return
        }
        let ext = videoURL.pathExtension
        let name = videoURL.deletingPathExtension().lastPathComponent + ".\(ext)"
        let destURL = dirURL.appendingPathComponent(name)
        saveToDestination(destURL, dirURL: dirURL)
    }

    private func saveVideoAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = isGIF ? [.gif] : [.mpeg4Movie]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".\(videoURL.pathExtension)"
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        panel.level = .statusBar + 3
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.saveToDestination(url, dirURL: nil)
        }
    }

    private func saveToDestination(_ destURL: URL, dirURL: URL?) {
        let needsTrim = trimStart > 0.01 || (duration - trimEnd) > 0.01
        let needsExport = needsTrim || isMuted

        if !needsExport {
            // No processing needed — copy temp file to destination
            try? FileManager.default.removeItem(at: destURL)
            do {
                try FileManager.default.copyItem(at: videoURL, to: destURL)
                savedURL = destURL
                if let dirURL = dirURL { SaveDirectoryAccess.stopAccessing(url: dirURL) }
                showStatus("Saved to \(destURL.lastPathComponent)")
                needsDisplay = true
            } catch {
                if dirURL != nil {
                    // Bookmarked directory failed — fall back to Save As
                    saveVideoAs()
                } else {
                    showStatus("Save failed", isError: true)
                }
            }
            return
        }

        guard let asset = asset else { return }
        showStatus("Exporting...")

        // Export to a temp file first, then move to destination
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(videoURL.pathExtension)")
        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: tmpURL) else {
            showStatus("Export failed", isError: true)
            return
        }

        Task {
            await session.export()
            await MainActor.run {
                if session.status == .completed {
                    try? FileManager.default.removeItem(at: destURL)
                    do {
                        try FileManager.default.moveItem(at: tmpURL, to: destURL)
                        self.savedURL = destURL
                        if let dirURL = dirURL { SaveDirectoryAccess.stopAccessing(url: dirURL) }
                        self.showStatus("Saved to \(destURL.lastPathComponent)")
                        self.needsDisplay = true
                    } catch {
                        self.showStatus("Save failed", isError: true)
                    }
                } else {
                    self.showStatus("Export failed", isError: true)
                    try? FileManager.default.removeItem(at: tmpURL)
                }
            }
        }
    }

    private func uploadVideo() {
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"

        if provider == "gdrive" && !GoogleDriveUploader.shared.isSignedIn {
            showStatus("Sign in to Google Drive in Preferences", isError: true)
            return
        }
        if provider == "s3" && !S3Uploader.shared.isConfigured {
            showStatus("Configure S3 in Preferences", isError: true)
            return
        }
        if provider != "gdrive" && provider != "s3" {
            showStatus("Video upload requires Google Drive or S3", isError: true)
            return
        }

        let providerLabel = provider == "s3" ? "S3" : "Drive"
        showStatus("Uploading to \(providerLabel)... 0%")

        let progressHandler: (Double) -> Void = { [weak self] fraction in
            self?.showStatus("Uploading to \(providerLabel)... \(Int(fraction * 100))%")
        }

        let completionHandler: (Result<String, Error>) -> Void = { [weak self] result in
            switch result {
            case .success(let link):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                self?.showStatus("Uploaded! Link copied.")
            case .failure(let error):
                self?.showStatus("Upload failed: \(error.localizedDescription)", isError: true)
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
        let needsExport = needsTrim || isMuted

        if !needsExport {
            uploadFileURL(videoURL, false)
        } else {
            guard let asset = asset else { return }
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("macshot_upload_\(UUID().uuidString).mp4")

            let timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                                        end: CMTime(seconds: trimEnd, preferredTimescale: 600))
            guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: tmpURL) else {
                showStatus("Export failed", isError: true)
                return
            }

            Task {
                await session.export()
                await MainActor.run {
                    guard session.status == .completed else {
                        self.showStatus("Export failed", isError: true)
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
        default:
            super.keyDown(with: event)
        }
    }
}
