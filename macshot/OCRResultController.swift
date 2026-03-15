import Cocoa

class OCRResultController: NSObject {

    private var window: NSPanel?
    private var textView: NSTextView?
    private var charCountLabel: NSTextField?
    private var translateButton: NSButton?
    private var langPopup: NSPopUpButton?
    private var copyButton: NSButton?
    private var spinnerView: NSProgressIndicator?

    private var originalText: String
    private var isShowingTranslation = false

    init(text: String, image: NSImage?) {
        self.originalText = text
        super.init()
        buildWindow(text: text, image: image)
    }

    // MARK: - Build

    private func buildWindow(text: String, image: NSImage?) {
        let W: CGFloat = 720
        let H: CGFloat = 460
        let previewW: CGFloat = image != nil ? 240 : 0
        let gap: CGFloat = 0

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(
            x: screen.visibleFrame.midX - W / 2,
            y: screen.visibleFrame.midY - H / 2
        )

        let panel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: W, height: H)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Text Recognition"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 480, height: 300)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        cv.autoresizingMask = [.width, .height]

        // ── Left: image preview ──────────────────────────────
        if let image = image {
            let previewContainer = NSView(frame: NSRect(x: 0, y: 0, width: previewW, height: H))
            previewContainer.autoresizingMask = [.height]
            previewContainer.wantsLayer = true
            previewContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
            cv.addSubview(previewContainer)

            let imgView = NSImageView(frame: previewContainer.bounds.insetBy(dx: 12, dy: 12))
            imgView.image = image
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.imageAlignment = .alignCenter
            imgView.wantsLayer = true
            imgView.layer?.cornerRadius = 6
            imgView.layer?.masksToBounds = true
            imgView.autoresizingMask = [.width, .height]
            previewContainer.addSubview(imgView)

            // Vertical separator
            let sep = NSBox(frame: NSRect(x: previewW, y: 0, width: 1, height: H))
            sep.boxType = .custom
            sep.borderColor = NSColor.separatorColor
            sep.fillColor = NSColor.separatorColor
            sep.borderWidth = 0
            sep.autoresizingMask = [.height]
            cv.addSubview(sep)
        }

        // ── Right: text area + controls ──────────────────────
        let rightX = previewW + gap
        let rightW = W - rightX
        let footerH: CGFloat = 52
        let headerH: CGFloat = 44

        // Header bar (language selector + stats)
        let header = NSView(frame: NSRect(x: rightX, y: H - headerH, width: rightW, height: headerH))
        header.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(header)

        // Language popup
        let langLabel = NSTextField(labelWithString: "Translate to:")
        langLabel.font = NSFont.systemFont(ofSize: 12)
        langLabel.textColor = .secondaryLabelColor
        langLabel.frame = NSRect(x: 12, y: (headerH - 16) / 2, width: 90, height: 16)
        header.addSubview(langLabel)

        let popup = NSPopUpButton(frame: NSRect(x: 106, y: (headerH - 24) / 2, width: 160, height: 24), pullsDown: false)
        for lang in TranslationService.availableLanguages {
            popup.addItem(withTitle: lang.name)
            popup.lastItem?.representedObject = lang.code
        }
        // Select saved language
        let savedCode = TranslationService.targetLanguage
        if let idx = TranslationService.availableLanguages.firstIndex(where: { $0.code == savedCode }) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        header.addSubview(popup)
        self.langPopup = popup

        // Char/word count label (right side of header)
        let charCount = text.count
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let countLbl = NSTextField(labelWithString: "\(charCount) chars · \(wordCount) words")
        countLbl.font = NSFont.systemFont(ofSize: 11)
        countLbl.textColor = .tertiaryLabelColor
        countLbl.frame = NSRect(x: rightW - 180, y: (headerH - 14) / 2, width: 168, height: 14)
        countLbl.alignment = .right
        countLbl.autoresizingMask = [.minXMargin]
        header.addSubview(countLbl)
        self.charCountLabel = countLbl

        // Header separator
        let headerSep = NSBox(frame: NSRect(x: rightX, y: H - headerH - 1, width: rightW, height: 1))
        headerSep.boxType = .separator
        headerSep.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(headerSep)

        // Footer separator
        let footerSep = NSBox(frame: NSRect(x: rightX, y: footerH, width: rightW, height: 1))
        footerSep.boxType = .separator
        footerSep.autoresizingMask = [.width]
        cv.addSubview(footerSep)

        // Footer bar
        let footer = NSView(frame: NSRect(x: rightX, y: 0, width: rightW, height: footerH))
        footer.autoresizingMask = [.width]
        cv.addSubview(footer)

        // Copy button (primary, right-aligned)
        let copyBtn = NSButton(title: "Copy  ⌘↩", target: self, action: #selector(copyAll))
        copyBtn.bezelStyle = .rounded
        copyBtn.frame = NSRect(x: rightW - 110, y: (footerH - 28) / 2, width: 100, height: 28)
        copyBtn.autoresizingMask = [.minXMargin]
        copyBtn.keyEquivalent = "\r"
        copyBtn.keyEquivalentModifierMask = [.command]
        (copyBtn.cell as? NSButtonCell)?.backgroundColor = NSColor.controlAccentColor
        footer.addSubview(copyBtn)
        self.copyButton = copyBtn

        // Translate button
        let translateBtn = NSButton(title: "Translate", target: self, action: #selector(toggleTranslate))
        translateBtn.bezelStyle = .rounded
        translateBtn.frame = NSRect(x: rightW - 220, y: (footerH - 28) / 2, width: 100, height: 28)
        translateBtn.autoresizingMask = [.minXMargin]
        footer.addSubview(translateBtn)
        self.translateButton = translateBtn

        // Spinner (hidden)
        let spinner = NSProgressIndicator(frame: NSRect(x: rightW - 240, y: (footerH - 16) / 2, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.autoresizingMask = [.minXMargin]
        footer.addSubview(spinner)
        self.spinnerView = spinner

        // Scrollable text view
        let textAreaY = footerH + 1
        let textAreaH = H - headerH - 1 - footerH - 1
        let scrollView = NSScrollView(frame: NSRect(x: rightX, y: textAreaY, width: rightW, height: textAreaH))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        cv.addSubview(scrollView)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: rightW, height: textAreaH))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 14, height: 14)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width, .height]
        tv.drawsBackground = false
        tv.string = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "(No text detected in the selected area)"
            : text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tv.textColor = .secondaryLabelColor
        }
        tv.usesFindBar = true
        scrollView.documentView = tv
        self.textView = tv

        panel.contentView = cv
        self.window = panel
    }

    // MARK: - Show / Close

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let tv = self.textView else { return }
            self.window?.makeFirstResponder(tv)
            tv.selectAll(nil)
        }
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    // MARK: - Actions

    @objc private func copyAll() {
        guard let text = textView?.string, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let original = copyButton?.title ?? "Copy  ⌘↩"
        copyButton?.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton?.title = original
        }
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let code = sender.selectedItem?.representedObject as? String else { return }
        TranslationService.targetLanguage = code
        // If currently showing translation, re-translate with new language
        if isShowingTranslation {
            performTranslation(targetLang: code)
        }
    }

    @objc private func toggleTranslate() {
        if isShowingTranslation {
            restoreOriginal()
        } else {
            let code = (langPopup?.selectedItem?.representedObject as? String)
                ?? TranslationService.targetLanguage
            performTranslation(targetLang: code)
        }
    }

    @objc private func restoreOriginal() {
        isShowingTranslation = false
        setTextViewString(originalText)  // registers undo back to translated state
        translateButton?.title = "Translate"
        updateCharCount(for: originalText)
    }

    /// Sets the text view string and registers an undo action that restores
    /// the previous string AND flips isShowingTranslation + button title.
    private func setTextViewString(_ newText: String) {
        guard let tv = textView, let um = tv.undoManager else {
            textView?.string = newText
            return
        }
        let previousText = tv.string
        let wasShowingTranslation = isShowingTranslation
        tv.string = newText
        um.registerUndo(withTarget: self) { [weak self] target in
            guard let self = self else { return }
            self.isShowingTranslation = wasShowingTranslation
            self.setTextViewString(previousText)
            self.translateButton?.title = wasShowingTranslation ? "Show Original" : "Translate"
            self.updateCharCount(for: previousText)
        }
        um.setActionName("Translation")
    }

    private func performTranslation(targetLang: String) {
        guard let tv = textView else { return }
        let sourceText = isShowingTranslation ? originalText : tv.string
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceText.hasPrefix("(No text") else { return }

        translateButton?.isEnabled = false
        spinnerView?.isHidden = false
        spinnerView?.startAnimation(nil)

        // Split into lines for per-line translation (preserves layout)
        let lines = sourceText.components(separatedBy: "\n")
        let nonEmpty = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        TranslationService.translateBatch(texts: nonEmpty, targetLang: targetLang) { [weak self] result in
            guard let self = self else { return }
            self.spinnerView?.stopAnimation(nil)
            self.spinnerView?.isHidden = true
            self.translateButton?.isEnabled = true

            switch result {
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Translation Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window = self.window { alert.beginSheetModal(for: window) }

            case .success(let translated):
                // Restore empty lines to preserve paragraph structure
                var result: [String] = []
                for (i, original) in lines.enumerated() {
                    if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.append("")
                    } else if i < translated.count {
                        result.append(translated[i])
                    }
                }
                let translatedText = result.joined(separator: "\n")
                self.isShowingTranslation = true
                self.setTextViewString(translatedText)
                self.translateButton?.title = "Show Original"
                self.updateCharCount(for: translatedText)
            }
        }
    }

    private func updateCharCount(for text: String) {
        let chars = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        charCountLabel?.stringValue = "\(chars) chars · \(words) words"
    }
}

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Ensure Cmd+C, Cmd+A, Cmd+Z etc. always reach the first responder (NSTextView).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let the first responder handle standard text editing shortcuts first.
        if let fr = firstResponder as? NSTextView {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command {
                switch event.charactersIgnoringModifiers {
                case "c": fr.copy(nil);      return true
                case "x": fr.cut(nil);       return true
                case "v": fr.paste(nil);     return true
                case "a": fr.selectAll(nil); return true
                case "z": fr.undoManager?.undo(); return true
                default: break
                }
            }
            if flags == [.command, .shift], event.charactersIgnoringModifiers == "z" {
                fr.undoManager?.redo(); return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
