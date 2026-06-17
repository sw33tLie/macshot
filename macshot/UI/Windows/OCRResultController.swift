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
    private var qrCodes: [QRCodePayload]
    private var isShowingTranslation = false

    init(text: String, image: NSImage?, qrCodes: [QRCodePayload] = []) {
        self.originalText = text
        self.qrCodes = qrCodes
        super.init()
        buildWindow(text: text, image: image, qrCodes: qrCodes)
    }

    // MARK: - Build

    private func buildWindow(text: String, image: NSImage?, qrCodes: [QRCodePayload]) {
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
        panel.title = qrCodes.isEmpty ? L("Text Recognition") : L("Text & QR Recognition")
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
        let headerH: CGFloat = 52

        // Header bar (language selector + stats)
        let header = NSView(frame: NSRect(x: rightX, y: H - headerH, width: rightW, height: headerH))
        header.autoresizingMask = [.width, .minYMargin]
        cv.addSubview(header)

        let headerRow = NSStackView(frame: NSRect(x: 12, y: 12, width: rightW - 24, height: 28))
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.spacing = 8
        headerRow.autoresizingMask = [.width]
        header.addSubview(headerRow)

        // Language popup
        let langLabel = NSTextField(labelWithString: L("Translate to:"))
        langLabel.font = NSFont.systemFont(ofSize: 12)
        langLabel.textColor = .secondaryLabelColor
        langLabel.setContentHuggingPriority(.required, for: .horizontal)
        headerRow.addArrangedSubview(langLabel)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
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
        popup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        headerRow.addArrangedSubview(popup)
        self.langPopup = popup

        // Translate button
        let translateBtn = NSButton(title: L("Translate"), target: self, action: #selector(toggleTranslate))
        translateBtn.bezelStyle = .rounded
        translateBtn.widthAnchor.constraint(equalToConstant: 100).isActive = true
        headerRow.addArrangedSubview(translateBtn)
        self.translateButton = translateBtn

        // Spinner (hidden)
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.widthAnchor.constraint(equalToConstant: 16).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 16).isActive = true
        headerRow.addArrangedSubview(spinner)
        self.spinnerView = spinner

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(spacer)

        // Char/word count label
        let charCount = text.count
        let wordCount = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let countLbl = NSTextField(labelWithString: String(format: L("%d chars · %d words"), charCount, wordCount))
        countLbl.font = NSFont.systemFont(ofSize: 11)
        countLbl.textColor = .tertiaryLabelColor
        countLbl.alignment = .right
        countLbl.lineBreakMode = .byTruncatingTail
        countLbl.setContentHuggingPriority(.required, for: .horizontal)
        countLbl.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerRow.addArrangedSubview(countLbl)
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
        let copyBtn = NSButton(title: L("Copy") + "  ⌘↩", target: self, action: #selector(copyAll))
        copyBtn.bezelStyle = .rounded
        copyBtn.frame = NSRect(x: rightW - 110, y: (footerH - 28) / 2, width: 100, height: 28)
        copyBtn.autoresizingMask = [.minXMargin]
        copyBtn.keyEquivalent = "\r"
        copyBtn.keyEquivalentModifierMask = [.command]
        (copyBtn.cell as? NSButtonCell)?.backgroundColor = NSColor.controlAccentColor
        footer.addSubview(copyBtn)
        self.copyButton = copyBtn

        // AI Search button
        let aiSearchBtn = NSButton(title: L("AI Search"), target: self, action: #selector(openAISearch))
        aiSearchBtn.bezelStyle = .rounded
        aiSearchBtn.frame = NSRect(x: rightW - 220, y: (footerH - 28) / 2, width: 100, height: 28)
        aiSearchBtn.autoresizingMask = [.minXMargin]
        footer.addSubview(aiSearchBtn)

        let qrSectionH = qrCodes.isEmpty ? CGFloat(0) : min(CGFloat(46 + qrCodes.count * 36), 168)

        // Scrollable text view
        let textAreaY = footerH + 1
        let textAreaH = H - headerH - 1 - footerH - 1 - qrSectionH
        let scrollView = NSScrollView(frame: NSRect(x: rightX, y: textAreaY + qrSectionH, width: rightW, height: textAreaH))
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
        let noTextMessage = L("(No text detected in the selected area)")
        tv.string = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? noTextMessage
            : text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tv.textColor = .secondaryLabelColor
        }
        tv.usesFindBar = true
        scrollView.documentView = tv
        self.textView = tv

        if !qrCodes.isEmpty {
            let qrSection = makeQRCodeSection(
                qrCodes: qrCodes,
                frame: NSRect(x: rightX, y: textAreaY, width: rightW, height: qrSectionH)
            )
            qrSection.autoresizingMask = [.width, .maxYMargin]
            cv.addSubview(qrSection)
        }

        panel.contentView = cv
        self.window = panel
    }

    private func makeQRCodeSection(qrCodes: [QRCodePayload], frame: NSRect) -> NSView {
        let section = NSView(frame: frame)

        let topSep = NSBox(frame: NSRect(x: 0, y: frame.height - 1, width: frame.width, height: 1))
        topSep.boxType = .separator
        topSep.autoresizingMask = [.width, .minYMargin]
        section.addSubview(topSep)

        let title = NSTextField(labelWithString: qrCodes.count == 1 ? L("QR Code") : L("QR Codes"))
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 14, y: frame.height - 28, width: 160, height: 18)
        title.autoresizingMask = [.maxYMargin]
        section.addSubview(title)

        let rowH: CGFloat = 30
        var rowY = frame.height - 32 - rowH
        for (idx, qrCode) in qrCodes.enumerated() where rowY >= 6 {
            let hasURL = qrCode.url != nil
            let copyW: CGFloat = 56
            let openW: CGFloat = hasURL ? 86 : 0
            let gap: CGFloat = hasURL ? 8 : 0
            let rightPad: CGFloat = 12
            let buttonsW = copyW + openW + gap + rightPad

            let valueField = NSTextField(frame: NSRect(x: 14, y: rowY + 4, width: frame.width - 28 - buttonsW, height: 22))
            valueField.stringValue = qrCode.value
            valueField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            valueField.textColor = .labelColor
            valueField.isEditable = false
            valueField.isSelectable = true
            valueField.isBordered = false
            valueField.drawsBackground = false
            valueField.lineBreakMode = .byTruncatingMiddle
            valueField.autoresizingMask = [.width]
            section.addSubview(valueField)

            var buttonX = frame.width - rightPad - copyW
            let copy = NSButton(title: L("Copy"), target: self, action: #selector(copyQRCode(_:)))
            copy.bezelStyle = .rounded
            copy.tag = idx
            copy.frame = NSRect(x: buttonX, y: rowY + 2, width: copyW, height: 26)
            copy.autoresizingMask = [.minXMargin]
            section.addSubview(copy)

            if hasURL {
                buttonX -= openW + gap
                let open = NSButton(title: L("Open Link"), target: self, action: #selector(openQRCode(_:)))
                open.bezelStyle = .rounded
                open.tag = idx
                open.frame = NSRect(x: buttonX, y: rowY + 2, width: openW, height: 26)
                open.autoresizingMask = [.minXMargin]
                section.addSubview(open)
            }

            rowY -= rowH + 6
        }

        return section
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
        MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
        }
    }

    // MARK: - Actions

    @objc private func copyAll() {
        let text = textView?.string ?? ""
        let noTextMessage = L("(No text detected in the selected area)")
        let copyText = text == noTextMessage ? qrCodes.map(\.value).joined(separator: "\n") : text
        guard !copyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        close()
    }

    @objc private func copyQRCode(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < qrCodes.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(qrCodes[sender.tag].value, forType: .string)
    }

    @objc private func openQRCode(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < qrCodes.count,
              let url = qrCodes[sender.tag].url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAISearch() {
        guard let text = textView?.string, !text.isEmpty else { return }
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)&csuir=1&udm=50") else { return }
        NSWorkspace.shared.open(url)
        close()
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
        translateButton?.title = L("Translate")
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
            self.translateButton?.title = wasShowingTranslation ? L("Show Original") : L("Translate")
            self.updateCharCount(for: previousText)
        }
        um.setActionName(L("Translation"))
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
                alert.messageText = L("Translation Failed")
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
                self.translateButton?.title = L("Show Original")
                self.updateCharCount(for: translatedText)
            }
        }
    }

    private func updateCharCount(for text: String) {
        let chars = text.count
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        charCountLabel?.stringValue = String(format: L("%d chars · %d words"), chars, words)
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
                switch event.keyCode {
                case 8:  fr.copy(nil);      return true  // C
                case 7:  fr.cut(nil);       return true  // X
                case 9:  fr.paste(nil);     return true  // V
                case 0:  fr.selectAll(nil); return true  // A
                case 6:  fr.undoManager?.undo(); return true  // Z
                default: break
                }
            }
            if flags == [.command, .shift], event.keyCode == 6 {  // Z
                fr.undoManager?.redo(); return true
            }
        }
        // Cmd+W to close — handle outside the text view check so it always works
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 13 {  // W
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
