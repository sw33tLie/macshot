import AppKit

/// Title-bar strip: undo/redo, project title, status and the Export button.
final class VideoEditorTopBar: NSView {
    let undoButton: VideoIconButton
    let redoButton: VideoIconButton
    let titleLabel = VideoEditorStyle.label("", size: 13, weight: .semibold)
    let subtitleLabel = VideoEditorStyle.label("", size: 11, color: VideoEditorStyle.textTertiary)
    let statusLabel = VideoEditorStyle.label("", size: 11.5, weight: .medium, color: VideoEditorStyle.textSecondary)
    let exportButton: VideoPillButton
    let copyButton: VideoPillButton

    init(target: AnyObject) {
        undoButton = VideoIconButton(symbol: "arrow.uturn.backward", size: 13, tooltip: L("Undo"), target: target,
                                     action: #selector(VideoEditorWindowController.undoAction))
        redoButton = VideoIconButton(symbol: "arrow.uturn.forward", size: 13, tooltip: L("Redo"), target: target,
                                     action: #selector(VideoEditorWindowController.redoAction))
        exportButton = VideoPillButton(title: L("Export"), symbol: "square.and.arrow.up", target: target,
                                       action: #selector(VideoEditorWindowController.showExportPanel(_:)))
        copyButton = VideoPillButton(title: L("Copy"), symbol: "doc.on.doc", target: target,
                                     action: #selector(VideoEditorWindowController.copyAction))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        exportButton.fill = VideoEditorStyle.accent
        exportButton.textColor = .white
        copyButton.toolTip = L("Copy the edited video to the clipboard")
        for button in [undoButton, redoButton] {
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        titleLabel.alignment = .center
        subtitleLabel.alignment = .center
        subtitleLabel.font = VideoEditorStyle.mono(11, .regular)
        statusLabel.alignment = .right
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.spacing = 1
        titles.translatesAutoresizingMaskIntoConstraints = false
        for view in [undoButton, redoButton, titles, statusLabel, copyButton, exportButton] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            undoButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 84),
            undoButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            redoButton.leadingAnchor.constraint(equalTo: undoButton.trailingAnchor, constant: 2),
            redoButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titles.centerXAnchor.constraint(equalTo: centerXAnchor),
            titles.centerYAnchor.constraint(equalTo: centerYAnchor),
            titles.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),
            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            exportButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            exportButton.heightAnchor.constraint(equalToConstant: 30),
            copyButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -8),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.heightAnchor.constraint(equalToConstant: 30),
            statusLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titles.trailingAnchor, constant: 12),
        ])
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        VideoEditorStyle.window.setFill()
        bounds.fill()
        VideoEditorStyle.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // Dragging the empty bar moves the window.
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil); return }
        window?.performDrag(with: event)
    }
}

/// Above the stage: aspect ratio and crop.
final class VideoStageToolbar: NSView {
    let aspectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let cropButton: VideoPillButton
    let resetCropButton: VideoPillButton

    init(target: AnyObject) {
        cropButton = VideoPillButton(title: L("Crop"), symbol: "crop", target: target,
                                     action: #selector(VideoEditorWindowController.toggleCrop))
        resetCropButton = VideoPillButton(title: L("Reset"), symbol: nil, target: target,
                                          action: #selector(VideoEditorWindowController.resetCrop))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        aspectPopup.translatesAutoresizingMaskIntoConstraints = false
        aspectPopup.controlSize = .regular
        aspectPopup.isBordered = false
        aspectPopup.font = VideoEditorStyle.font(12.5, .semibold)
        for aspect in VideoAspectRatio.allCases {
            aspectPopup.addItem(withTitle: aspect == .auto ? L("Auto") : aspect.label)
            aspectPopup.lastItem?.representedObject = aspect.rawValue
        }
        aspectPopup.target = target
        aspectPopup.action = #selector(VideoEditorWindowController.aspectChanged(_:))
        aspectPopup.toolTip = L("Aspect ratio")
        let aspectIcon = NSImageView(image: VideoEditorStyle.symbol("aspectratio", size: 13) ?? NSImage())
        aspectIcon.contentTintColor = VideoEditorStyle.textSecondary
        let stack = NSStackView(views: [aspectIcon, aspectPopup, NSBox.verticalDivider(), cropButton, resetCropButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        cropButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        resetCropButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        resetCropButton.isHidden = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        VideoEditorStyle.stage.setFill()
        bounds.fill()
    }
}

extension NSBox {
    static func verticalDivider() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = VideoEditorStyle.separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }
}

/// Transport controls between the stage and the timeline.
final class VideoTransportBar: NSView {
    let addButton: VideoPillButton
    let autoZoomButton: VideoPillButton
    let playButton: VideoIconButton
    let previousButton: VideoIconButton
    let nextButton: VideoIconButton
    let timeLabel = VideoEditorStyle.label("0:00.00", size: 12.5, weight: .medium)
    let durationLabel = VideoEditorStyle.label("/ 0:00.00", size: 12.5, color: VideoEditorStyle.textTertiary)
    let muteButton: VideoIconButton
    let zoomOutButton: VideoIconButton
    let zoomInButton: VideoIconButton
    let fitButton: VideoPillButton

    init(target: AnyObject) {
        addButton = VideoPillButton(title: L("Add"), symbol: "plus", chevron: true, target: target,
                                    action: #selector(VideoEditorWindowController.showAddMenu(_:)))
        autoZoomButton = VideoPillButton(title: L("Auto Zoom"), symbol: "wand.and.stars", target: target,
                                         action: #selector(VideoEditorWindowController.autoZoomAction))
        playButton = VideoIconButton(symbol: "play.fill", size: 16, tooltip: L("Play"), target: target,
                                     action: #selector(VideoEditorWindowController.togglePlayAction))
        previousButton = VideoIconButton(symbol: "backward.end.fill", size: 12, tooltip: L("Previous edit"), target: target,
                                         action: #selector(VideoEditorWindowController.previousEditAction))
        nextButton = VideoIconButton(symbol: "forward.end.fill", size: 12, tooltip: L("Next edit"), target: target,
                                     action: #selector(VideoEditorWindowController.nextEditAction))
        muteButton = VideoIconButton(symbol: "speaker.wave.2.fill", size: 13, tooltip: L("Mute"), target: target,
                                     action: #selector(VideoEditorWindowController.toggleMuteAction))
        zoomOutButton = VideoIconButton(symbol: "minus.magnifyingglass", size: 13, tooltip: L("Zoom out timeline"),
                                        target: target, action: #selector(VideoEditorWindowController.timelineZoomOut))
        zoomInButton = VideoIconButton(symbol: "plus.magnifyingglass", size: 13, tooltip: L("Zoom in timeline"),
                                       target: target, action: #selector(VideoEditorWindowController.timelineZoomIn))
        fitButton = VideoPillButton(title: L("Fit"), symbol: nil, target: target,
                                    action: #selector(VideoEditorWindowController.timelineFit))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = VideoEditorStyle.mono(13, .semibold)
        durationLabel.font = VideoEditorStyle.mono(13, .regular)
        playButton.cornerRadius = 17
        playButton.tint = .white
        for button in [previousButton, nextButton, muteButton, zoomOutButton, zoomInButton] {
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        playButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        for button in [addButton, autoZoomButton, fitButton] { button.heightAnchor.constraint(equalToConstant: 28).isActive = true }

        let left = NSStackView(views: [addButton, autoZoomButton])
        left.spacing = 8
        let center = NSStackView(views: [timeLabel, durationLabel, NSBox.verticalDivider(), previousButton, playButton, nextButton])
        center.spacing = 6
        center.setCustomSpacing(4, after: timeLabel)
        center.setCustomSpacing(14, after: durationLabel)
        center.setCustomSpacing(10, after: center.arrangedSubviews[2])
        let right = NSStackView(views: [muteButton, NSBox.verticalDivider(), zoomOutButton, fitButton, zoomInButton])
        right.spacing = 4
        for stack in [left, center, right] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 50),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
            center.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        VideoEditorStyle.panel.setFill()
        bounds.fill()
        VideoEditorStyle.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func setPlaying(_ playing: Bool) {
        playButton.image = VideoEditorStyle.symbol(playing ? "pause.fill" : "play.fill", size: 16)
        playButton.toolTip = playing ? L("Pause") : L("Play")
        playButton.setAccessibilityLabel(playButton.toolTip)
    }

    func setMuted(_ muted: Bool) {
        muteButton.image = VideoEditorStyle.symbol(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 13)
        muteButton.isActive = muted
        muteButton.toolTip = muted ? L("Unmute") : L("Mute")
    }

    static func format(_ seconds: Double) -> String {
        let hundredths = Int((max(0, seconds) * 100).rounded())
        let m = hundredths / 6000, s = (hundredths / 100) % 60, h = hundredths % 100
        if m >= 60 { return String(format: "%d:%02d:%02d.%02d", m / 60, m % 60, s, h) }
        return String(format: "%d:%02d.%02d", m, s, h)
    }
}
