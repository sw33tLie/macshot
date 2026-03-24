import Cocoa

class UploadToastController {

    private var window: NSPanel?
    private var statusLabel: NSTextField?
    private var linkButton: NSButton?
    private var deleteButton: NSButton?
    private var closeButton: NSButton?
    private var spinner: NSProgressIndicator?
    private var dismissTask: DispatchWorkItem?
    private var currentDeleteURL: String?
    var onDismiss: (() -> Void)?

    func show(status: String) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame
        let toastWidth: CGFloat = 320
        let toastHeight: CGFloat = 60
        let padding: CGFloat = 16

        let startX = screenFrame.maxX + 10
        let finalX = screenFrame.maxX - toastWidth - padding
        let y = screenFrame.minY + padding

        let panel = NSPanel(
            contentRect: NSRect(x: startX, y: y, width: toastWidth, height: toastHeight),
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

        let contentView = ToastContentView(frame: NSRect(origin: .zero, size: NSSize(width: toastWidth, height: toastHeight)))
        panel.contentView = contentView

        // Spinner
        let spinnerView = NSProgressIndicator(frame: NSRect(x: 16, y: (toastHeight - 20) / 2, width: 20, height: 20))
        spinnerView.style = .spinning
        spinnerView.controlSize = .small
        spinnerView.startAnimation(nil)
        contentView.addSubview(spinnerView)
        self.spinner = spinnerView

        // Status label
        let label = NSTextField(labelWithString: status)
        label.frame = NSRect(x: 44, y: (toastHeight - 20) / 2, width: toastWidth - 60, height: 20)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        contentView.addSubview(label)
        self.statusLabel = label

        self.window = panel
        panel.orderFrontRegardless()

        // Animate in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: finalX, y: y, width: toastWidth, height: toastHeight),
                display: true
            )
        }
    }

    func showSuccess(link: String, deleteURL: String) {
        guard let window = window, let contentView = window.contentView else { return }
        self.currentDeleteURL = deleteURL

        // Remove spinner
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil

        // Resize taller to fit buttons — taller for long links
        let toastWidth: CGFloat = 360
        let linkHeight: CGFloat = link.count > 40 ? 36 : 18
        let toastHeight: CGFloat = 72 + linkHeight
        let frame = window.frame
        let newFrame = NSRect(x: frame.minX, y: frame.minY, width: toastWidth, height: toastHeight)

        window.setFrame(newFrame, display: false)
        contentView.frame = NSRect(origin: .zero, size: NSSize(width: toastWidth, height: toastHeight))
        (contentView as? ToastContentView)?.needsDisplay = true

        // Update status
        statusLabel?.removeFromSuperview()

        // "Link copied!" label
        let copiedLabel = NSTextField(labelWithString: "Link copied to clipboard!")
        copiedLabel.frame = NSRect(x: 16, y: toastHeight - 30, width: toastWidth - 80, height: 18)
        copiedLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        copiedLabel.textColor = .white
        contentView.addSubview(copiedLabel)
        statusLabel = copiedLabel

        // Close button (X)
        let close = NSButton(frame: NSRect(x: toastWidth - 30, y: toastHeight - 30, width: 20, height: 20))
        close.bezelStyle = .inline
        close.isBordered = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        close.contentTintColor = .white.withAlphaComponent(0.7)
        close.target = self
        close.action = #selector(dismissClicked)
        contentView.addSubview(close)
        self.closeButton = close

        // Link button (clickable, wraps for long URLs)
        let linkBtn = NSButton(frame: NSRect(x: 16, y: toastHeight - 30 - linkHeight - 8, width: toastWidth - 32, height: linkHeight))
        linkBtn.bezelStyle = .inline
        linkBtn.isBordered = false
        linkBtn.alignment = .left
        let linkAttrs = NSMutableAttributedString(string: link, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedRed: 0.5, green: 0.8, blue: 1.0, alpha: 1.0),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        linkBtn.attributedTitle = linkAttrs
        linkBtn.target = self
        linkBtn.action = #selector(openLink)
        linkBtn.toolTip = link
        (linkBtn.cell as? NSButtonCell)?.wraps = true
        contentView.addSubview(linkBtn)
        self.linkButton = linkBtn

        // Delete button (only for imgbb — Google Drive has no delete URL)
        if !deleteURL.isEmpty {
            let delBtn = NSButton(frame: NSRect(x: 16, y: 10, width: 140, height: 22))
            delBtn.bezelStyle = .inline
            delBtn.isBordered = false
            let delAttrs = NSMutableAttributedString(string: "Delete from server", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1.0),
            ])
            delBtn.attributedTitle = delAttrs
            delBtn.target = self
            delBtn.action = #selector(deleteUpload)
            contentView.addSubview(delBtn)
            self.deleteButton = delBtn
        }

        // Auto-dismiss after 10 seconds
        dismissTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.animateOut()
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: task)
    }

    func showError(message: String) {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil

        let fullMessage = "Upload failed: \(message)"
        statusLabel?.stringValue = fullMessage
        statusLabel?.textColor = NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1.0)
        statusLabel?.lineBreakMode = .byWordWrapping
        statusLabel?.maximumNumberOfLines = 3

        // Expand toast height if the message needs more room
        if let label = statusLabel, let panel = window {
            let toastWidth: CGFloat = 320
            let maxLabelW = toastWidth - 32
            let boundingSize = NSSize(width: maxLabelW, height: 200)
            let neededSize = (fullMessage as NSString).boundingRect(
                with: boundingSize,
                options: [.usesLineFragmentOrigin],
                attributes: [.font: label.font!]
            ).size
            let newHeight = max(60, neededSize.height + 36)
            var frame = panel.frame
            frame.size.height = newHeight
            panel.setFrame(frame, display: true)
            panel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
            label.frame = NSRect(x: 16, y: (newHeight - neededSize.height) / 2, width: maxLabelW, height: neededSize.height + 4)
        }

        // Auto-dismiss after 8 seconds (longer for errors so user can read)
        dismissTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.animateOut()
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: task)
    }

    @objc private func openLink() {
        guard let link = linkButton?.toolTip, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func deleteUpload() {
        guard let deleteURL = currentDeleteURL, let url = URL(string: deleteURL) else { return }
        // imgbb delete URLs must be opened in a browser for confirmation
        NSWorkspace.shared.open(url)

        // Remove from stored uploads
        if let link = linkButton?.toolTip {
            var uploads = UserDefaults.standard.array(forKey: "imgbbUploads") as? [[String: String]] ?? []
            uploads.removeAll { $0["link"] == link }
            UserDefaults.standard.set(uploads, forKey: "imgbbUploads")
        }

        let delAttrs = NSMutableAttributedString(string: "Opened in browser", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedRed: 0.5, green: 1.0, blue: 0.5, alpha: 1.0),
        ])
        deleteButton?.attributedTitle = delAttrs
        deleteButton?.isEnabled = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.animateOut()
        }
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
        linkButton = nil
        deleteButton = nil
        closeButton = nil
        spinner = nil
        onDismiss?()
        onDismiss = nil
    }

    private func animateOut() {
        guard let window = window else { return }
        let frame = window.frame
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let offscreenX = screen.visibleFrame.maxX + 10

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                NSRect(x: offscreenX, y: frame.minY, width: frame.width, height: frame.height),
                display: true
            )
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.dismiss()
        })
    }
}

// MARK: - Toast background view

private class ToastContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor(white: 0.12, alpha: 0.95).setFill()
        path.fill()

        NSColor.white.withAlphaComponent(0.1).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        border.lineWidth = 1
        border.stroke()
    }
}
