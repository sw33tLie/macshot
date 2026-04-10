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
        let controlsH: CGFloat = 140
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
        win.title = L("macshot Video Editor")
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
            (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
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

    // Timeline thumbnails
    private var thumbnailImages: [NSImage] = []
    private var thumbnailsGenerating: Bool = false
    private var lastThumbnailWidth: CGFloat = 0

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
    private let controlsH: CGFloat = 140
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
        let tlH: CGFloat = 36
        timelineRect = NSRect(x: tlX, y: tlY, width: tlW, height: tlH)

        // Regenerate thumbnails if width changed significantly
        if abs(tlW - lastThumbnailWidth) > 40 && !thumbnailsGenerating && asset != nil {
            generateThumbnails()
        }

        // Track background with rounded clip
        let trackPath = NSBezierPath(roundedRect: timelineRect, xRadius: 5, yRadius: 5)
        NSColor.white.withAlphaComponent(0.06).setFill()
        trackPath.fill()

        // Draw thumbnails
        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        if !thumbnailImages.isEmpty {
            let count = thumbnailImages.count
            let thumbW = tlW / CGFloat(count)
            for (i, img) in thumbnailImages.enumerated() {
                let r = NSRect(x: tlX + CGFloat(i) * thumbW, y: tlY, width: thumbW + 1, height: tlH)
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

        // Trim border highlight
        let trimRect = NSRect(x: startX, y: tlY, width: endX - startX, height: tlH)
        let trimBorder = NSBezierPath(roundedRect: trimRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        trimBorder.lineWidth = 1.5
        NSColor.systemPurple.withAlphaComponent(0.8).setStroke()
        trimBorder.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Trim handles
        let handleW: CGFloat = 10
        let handleH: CGFloat = tlH + 8

        let startHandleRect = NSRect(x: startX - handleW / 2, y: tlY - 4, width: handleW, height: handleH)
        NSColor.systemPurple.setFill()
        NSBezierPath(roundedRect: startHandleRect, xRadius: 3, yRadius: 3).fill()
        drawHandleGrip(in: startHandleRect)

        let endHandleRect = NSRect(x: endX - handleW / 2, y: tlY - 4, width: handleW, height: handleH)
        NSColor.systemPurple.setFill()
        NSBezierPath(roundedRect: endHandleRect, xRadius: 3, yRadius: 3).fill()
        drawHandleGrip(in: endHandleRect)

        // Playhead
        if player != nil || isGIF {
            let currentTime = currentPlaybackTime
            let playheadX = max(tlX, min(tlX + tlW, tlX + CGFloat(currentTime / duration) * tlW))

            // Playhead line with subtle shadow
            NSColor.white.withAlphaComponent(0.9).setFill()
            let playheadRect = NSRect(x: playheadX - 1, y: tlY - 2, width: 2, height: tlH + 4)
            NSBezierPath(roundedRect: playheadRect, xRadius: 1, yRadius: 1).fill()

            // Playhead circle
            let circleR: CGFloat = 5
            let circleX = max(tlX + circleR, min(tlX + tlW - circleR, playheadX))
            NSColor.white.setFill()
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
        let copyArrowW: CGFloat = 20
        let fullCopyW = labelBtnW + copyArrowW
        x -= fullCopyW
        let fullCopyRect = NSRect(x: x, y: btnY, width: fullCopyW, height: btnH)
        copyBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        copyArrowRect = NSRect(x: x + labelBtnW, y: btnY, width: copyArrowW, height: btnH)

        // Draw combined background
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: fullCopyRect, xRadius: 6, yRadius: 6).fill()

        if compact {
            if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: copyBtnRect.midX - img.size.width / 2, y: copyBtnRect.midY - img.size.height / 2,
                                        width: img.size.width, height: img.size.height))
            }
        } else {
            let iconSize: CGFloat = 12
            let copyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let copyLabel = L("Copy") as NSString
            let copyLabelSize = copyLabel.size(withAttributes: copyAttrs)
            let totalCopyW = iconSize + 4 + copyLabelSize.width
            let copyStartX = copyBtnRect.midX - totalCopyW / 2
            if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.withAlphaComponent(0.85).setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: copyStartX, y: copyBtnRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            copyLabel.draw(at: NSPoint(x: copyStartX + iconSize + 4, y: copyBtnRect.midY - copyLabelSize.height / 2), withAttributes: copyAttrs)
        }

        // Separator line
        NSColor.white.withAlphaComponent(0.2).setStroke()
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
                NSColor.white.withAlphaComponent(0.6).setFill()
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
        if compact {
            drawIconButton(rect: uploadBtnRect, symbol: "icloud.and.arrow.up", accent: false)
        } else {
            drawLabelButton(rect: uploadBtnRect, symbol: "icloud.and.arrow.up", label: L("Upload"), dimmed: !canUpload)
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
            let saveLabel = L("Save") as NSString
            let labelSize = saveLabel.size(withAttributes: attrs)
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
            saveLabel.draw(at: NSPoint(x: startX + iconSize + 4, y: saveBtnRect.midY - labelSize.height / 2), withAttributes: attrs)
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
        let labelY = timelineRect.maxY + 14

        let leftStr = formatTime(currentTime) as NSString
        let rightStr = String(format: L("%@ selected"), formatTime(trimDuration)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]

        leftStr.draw(at: NSPoint(x: timelinePad, y: labelY), withAttributes: attrs)

        let rightSize = rightStr.size(withAttributes: attrs)
        rightStr.draw(at: NSPoint(x: bounds.width - timelinePad - rightSize.width, y: labelY), withAttributes: attrs)
    }

    private func drawStatus(_ message: String) {
        let color: NSColor = statusIsError ? NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1.0) : .systemGreen
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let str = message as NSString
        let size = str.size(withAttributes: attrs)
        let labelY = timelineRect.maxY + 14
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: labelY), withAttributes: attrs)
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

    private func copyToClipboard() {
        let url = savedURL ?? videoURL
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if isGIF || url.pathExtension.lowercased() == "gif" {
            if let data = try? Data(contentsOf: url) {
                let item = NSPasteboardItem()
                item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
                item.setString(url.absoluteString, forType: .fileURL)
                pasteboard.writeObjects([item])
            }
        } else {
            pasteboard.writeObjects([url as NSURL])
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
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".mp4"
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        panel.level = .statusBar + 3
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.saveToDestination(url, dirURL: nil)
        }
    }

    private func showSaveMenu() {
        let menu = NSMenu()
        let saveAsItem = NSMenuItem(title: L("Save As…"), action: #selector(saveAsAction), keyEquivalent: "")
        saveAsItem.target = self
        menu.addItem(saveAsItem)
        menu.addItem(NSMenuItem.separator())
        let gifItem = NSMenuItem(title: L("Save as GIF…"), action: #selector(saveAsGIFAction), keyEquivalent: "")
        gifItem.target = self
        menu.addItem(gifItem)
        let pos = NSPoint(x: saveArrowRect.minX, y: saveArrowRect.maxY)
        menu.popUp(positioning: nil, at: pos, in: self)
    }

    @objc private func saveAsAction() { saveVideoAs() }

    @objc private func saveAsGIFAction() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".gif"
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        panel.level = .statusBar + 3
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.convertToGIF(destURL: url)
        }
    }

    private func convertToGIF(destURL: URL) {
        guard let asset = asset else { return }
        showStatus(L("Converting to GIF…"))

        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)
        // GIF capped at 15fps
        let gifFPS = min(15, asset.tracks(withMediaType: .video).first.map { Int($0.nominalFrameRate.rounded()) } ?? 15)

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let reader = try AVAssetReader(asset: asset)
                guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                    await MainActor.run { self?.showStatus(L("No video track found"), isError: true) }
                    return
                }
                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                trackOutput.alwaysCopiesSampleData = false
                reader.timeRange = timeRange
                reader.add(trackOutput)

                let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
                let sourceFPS = Int(videoTrack.nominalFrameRate.rounded())
                let encoder = GIFEncoder(url: tmpURL, fps: gifFPS, sourceFPS: max(sourceFPS, gifFPS))
                reader.startReading()

                while reader.status == .reading {
                    if let sampleBuffer = trackOutput.copyNextSampleBuffer(),
                       let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        encoder.addFrame(pixelBuffer)
                    }
                }
                encoder.finish()

                // Move to destination
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.moveItem(at: tmpURL, to: destURL)

                await MainActor.run {
                    self?.savedURL = destURL
                    self?.showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                    self?.needsDisplay = true
                }
            } catch {
                await MainActor.run {
                    self?.showStatus(L("GIF conversion failed"), isError: true)
                }
            }
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

        // Export to a temp file first, then move to destination
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(videoURL.pathExtension)")
        let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
        let endTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
        let timeRange = CMTimeRange(start: startTime, end: endTime)

        guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: tmpURL) else {
            showStatus(L("Export failed"), isError: true)
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
        let needsExport = needsTrim || isMuted

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
            super.keyDown(with: event)
        }
    }

    private func stepFrame(forward: Bool) {
        guard let player = player else { return }
        // Pause if playing
        if player.rate > 0 { player.pause(); needsDisplay = true }

        let fps = asset?.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30
        let frameDuration = 1.0 / Double(fps)
        let current = CMTimeGetSeconds(player.currentTime())
        let target = forward
            ? min(current + frameDuration, trimEnd)
            : max(current - frameDuration, trimStart)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }
}
