import Cocoa

class OCRResultController {

    private var window: NSPanel?
    private var textView: NSTextView?

    init(text: String) {
        let panelWidth: CGFloat = 480
        let panelHeight: CGFloat = 360

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(
            x: screen.visibleFrame.midX - panelWidth / 2,
            y: screen.visibleFrame.midY - panelHeight / 2
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: panelWidth, height: panelHeight)),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "OCR — Recognized Text"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 180)
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        contentView.autoresizingMask = [.width, .height]

        // Button bar at bottom
        let buttonBarHeight: CGFloat = 44
        let buttonBar = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: buttonBarHeight))
        buttonBar.autoresizingMask = [.width]

        let copyButton = NSButton(title: "Copy All", target: nil, action: nil)
        copyButton.bezelStyle = .rounded
        copyButton.frame = NSRect(x: panelWidth - 100, y: 10, width: 85, height: 28)
        copyButton.autoresizingMask = [.minXMargin]
        copyButton.keyEquivalent = "c"
        copyButton.keyEquivalentModifierMask = [.command]
        buttonBar.addSubview(copyButton)

        let closeButton = NSButton(title: "Close", target: nil, action: nil)
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: panelWidth - 190, y: 10, width: 80, height: 28)
        closeButton.autoresizingMask = [.minXMargin]
        closeButton.keyEquivalent = "\u{1b}" // Escape
        buttonBar.addSubview(closeButton)

        // Character count label
        let charCount = text.count
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let countLabel = NSTextField(labelWithString: "\(charCount) chars, \(wordCount) words")
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.frame = NSRect(x: 12, y: 14, width: 200, height: 16)
        buttonBar.addSubview(countLabel)

        contentView.addSubview(buttonBar)

        // Separator
        let separator = NSBox(frame: NSRect(x: 0, y: buttonBarHeight, width: panelWidth, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width]
        contentView.addSubview(separator)

        // Scrollable text view
        let scrollFrame = NSRect(x: 0, y: buttonBarHeight + 1, width: panelWidth, height: panelHeight - buttonBarHeight - 1)
        let scrollView = NSScrollView(frame: scrollFrame)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: scrollFrame.width, height: scrollFrame.height))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width, .height]
        tv.string = text
        tv.usesFindBar = true

        scrollView.documentView = tv
        contentView.addSubview(scrollView)

        panel.contentView = contentView
        self.window = panel
        self.textView = tv

        // Wire up buttons using target/action
        copyButton.target = self
        copyButton.action = #selector(copyAll)
        closeButton.target = self
        closeButton.action = #selector(closePanel)

        // If no text was found, show a helpful message
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tv.string = "(No text detected in the selected area)"
            tv.textColor = .secondaryLabelColor
        }
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Select all text for easy copying
        textView?.selectAll(nil)
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        textView = nil
    }

    @objc private func copyAll() {
        guard let text = textView?.string, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Brief visual feedback: flash the button title
        if let contentView = window?.contentView,
           let buttonBar = contentView.subviews.first,
           let copyBtn = buttonBar.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Copy All" || $0.title == "Copied!" }) {
            copyBtn.title = "Copied!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                copyBtn.title = "Copy All"
            }
        }
    }

    @objc private func closePanel() {
        close()
    }
}
