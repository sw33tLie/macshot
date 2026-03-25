import Cocoa

class UploadToastController {

    private var window: NSPanel?
    private var statusLabel: NSTextField?
    private var linkLabel: NSTextField?
    private var openButton: NSButton?
    private var iconView: NSImageView?
    private var spinner: NSProgressIndicator?
    private var dismissTask: DispatchWorkItem?
    private var currentLink: String?
    var onDismiss: (() -> Void)?

    private let toastWidth: CGFloat = 380
    private let cornerRadius: CGFloat = 14

    func show(status: String) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let toastHeight: CGFloat = 56
        let topPadding: CGFloat = 12

        // Top-center, just below the menu bar
        let x = screenFrame.midX - toastWidth / 2
        let startY = visibleFrame.maxY + 10
        let finalY = visibleFrame.maxY - toastHeight - topPadding

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: startY, width: toastWidth, height: toastHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let contentView = ToastBackgroundView(frame: NSRect(origin: .zero, size: NSSize(width: toastWidth, height: toastHeight)))
        contentView.cornerRadius = cornerRadius
        contentView.onClicked = { [weak self] in self?.animateOut() }
        panel.contentView = contentView

        // App icon
        let icon = NSImageView(frame: NSRect(x: 14, y: (toastHeight - 28) / 2, width: 28, height: 28))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(icon)
        self.iconView = icon

        // Spinner (overlays the icon area during upload)
        let spinnerView = NSProgressIndicator(frame: NSRect(x: 14, y: (toastHeight - 20) / 2, width: 20, height: 20))
        spinnerView.style = .spinning
        spinnerView.controlSize = .small
        spinnerView.startAnimation(nil)
        contentView.addSubview(spinnerView)
        self.spinner = spinnerView
        icon.isHidden = true

        // Status label
        let label = NSTextField(labelWithString: status)
        label.frame = NSRect(x: 50, y: (toastHeight - 18) / 2, width: toastWidth - 66, height: 18)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        contentView.addSubview(label)
        self.statusLabel = label

        self.window = panel
        panel.orderFrontRegardless()

        // Animate in from top
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: x, y: finalY, width: toastWidth, height: toastHeight),
                display: true
            )
        }
    }

    func updateProgress(_ fraction: Double) {
        statusLabel?.stringValue = "Uploading... \(Int(fraction * 100))%"
    }

    func showSuccess(link: String, deleteURL: String) {
        guard let window = window, let contentView = window.contentView else { return }
        self.currentLink = link

        // Remove spinner, show icon
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
        iconView?.isHidden = false

        // Remove old status label
        statusLabel?.removeFromSuperview()
        statusLabel = nil

        // Compute height based on link text length
        let linkFont = NSFont.systemFont(ofSize: 11)
        let maxLinkW = toastWidth - 140
        let linkTextSize = (link as NSString).boundingRect(
            with: NSSize(width: maxLinkW, height: 200),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: linkFont]
        ).size
        let linkH = max(16, ceil(linkTextSize.height))
        let toastHeight = max(64, linkH + 42)

        // Resize and reposition (stay top-center)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let topPadding: CGFloat = 12
        let x = screen.frame.midX - toastWidth / 2
        let y = visibleFrame.maxY - toastHeight - topPadding

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().setFrame(NSRect(x: x, y: y, width: toastWidth, height: toastHeight), display: true)
        }
        contentView.frame = NSRect(origin: .zero, size: NSSize(width: toastWidth, height: toastHeight))
        contentView.needsDisplay = true

        // Reposition icon
        iconView?.frame = NSRect(x: 14, y: (toastHeight - 28) / 2, width: 28, height: 28)

        // Title
        let titleLabel = NSTextField(labelWithString: "URL copied to the clipboard")
        titleLabel.frame = NSRect(x: 50, y: toastHeight - 28, width: toastWidth - 140, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)
        self.statusLabel = titleLabel

        // Link (subtitle)
        let linkLabel = NSTextField(wrappingLabelWithString: link)
        linkLabel.frame = NSRect(x: 50, y: 10, width: toastWidth - 140, height: linkH)
        linkLabel.font = linkFont
        linkLabel.textColor = .secondaryLabelColor
        linkLabel.isSelectable = false
        contentView.addSubview(linkLabel)
        self.linkLabel = linkLabel

        // "Open" button (native-looking, right side)
        let btn = NSButton(frame: NSRect(x: toastWidth - 76, y: (toastHeight - 28) / 2, width: 62, height: 28))
        btn.title = "Open"
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        btn.target = self
        btn.action = #selector(openLink)
        contentView.addSubview(btn)
        self.openButton = btn

        // Auto-dismiss after 8 seconds
        scheduleDismiss(seconds: 8)
    }

    func showError(message: String) {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
        iconView?.isHidden = false

        guard let panel = window, let contentView = panel.contentView else { return }

        let fullMessage = "Upload failed: \(message)"
        let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let maxLabelW = toastWidth - 66  // 50 left pad + 16 right pad
        let textSize = (fullMessage as NSString).boundingRect(
            with: NSSize(width: maxLabelW, height: 200),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: labelFont]
        ).size

        let toastHeight = max(56, ceil(textSize.height) + 28)

        // Resize and reposition
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let topPadding: CGFloat = 12
        let x = screen.frame.midX - toastWidth / 2
        let y = visibleFrame.maxY - toastHeight - topPadding

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().setFrame(NSRect(x: x, y: y, width: toastWidth, height: toastHeight), display: true)
        }
        contentView.frame = NSRect(origin: .zero, size: NSSize(width: toastWidth, height: toastHeight))
        contentView.needsDisplay = true

        // Update label to wrap
        statusLabel?.stringValue = fullMessage
        statusLabel?.textColor = .systemRed
        statusLabel?.lineBreakMode = .byWordWrapping
        statusLabel?.maximumNumberOfLines = 0
        statusLabel?.frame = NSRect(x: 50, y: (toastHeight - ceil(textSize.height)) / 2, width: maxLabelW, height: ceil(textSize.height) + 2)

        // Reposition icon
        iconView?.frame = NSRect(x: 14, y: (toastHeight - 28) / 2, width: 28, height: 28)

        scheduleDismiss(seconds: 6)
    }

    private func scheduleDismiss(seconds: Double) {
        dismissTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.animateOut()
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    @objc private func openLink() {
        guard let link = currentLink, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
        dismiss()
    }

    @objc private func dismissClicked() {
        dismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        statusLabel = nil
        linkLabel = nil
        openButton = nil
        iconView = nil
        spinner = nil
        onDismiss?()
        onDismiss = nil
    }

    private func animateOut() {
        guard let window = window else { return }
        let frame = window.frame
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let offscreenY = screen.visibleFrame.maxY + 10

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                NSRect(x: frame.minX, y: offscreenY, width: frame.width, height: frame.height),
                display: true
            )
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.dismiss()
        })
    }
}

// MARK: - Background view (mimics macOS notification appearance)

private class ToastBackgroundView: NSView {

    var cornerRadius: CGFloat = 14
    var onClicked: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        // Don't dismiss if clicking the "Open" button — let it handle itself
        let point = convert(event.locationInWindow, from: nil)
        for subview in subviews where subview is NSButton {
            if subview.frame.contains(point) {
                super.mouseDown(with: event)
                return
            }
        }
        onClicked?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)

        // Use the system visual effect material colors for a native feel
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(white: 0.18, alpha: 0.92).setFill()
        } else {
            NSColor(white: 0.98, alpha: 0.95).setFill()
        }
        path.fill()

        // Subtle border
        NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 0.5
        border.stroke()
    }
}
