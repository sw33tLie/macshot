import Cocoa

@MainActor
final class QuickTranslationController: NSObject {
    private enum RetryAction {
        case none
        case ocr
        case translation
    }

    private var window: QuickTranslationPanel?
    private var sourceTextView: NSTextView?
    private var translationTextView: NSTextView?
    private var languagePopup: NSPopUpButton?
    private var providerPopup: NSPopUpButton?
    private var statusRow: NSStackView?
    private var statusLabel: NSTextField?
    private var spinner: NSProgressIndicator?
    private var copyButton: NSButton?
    private var retryButton: NSButton?

    private var retainedImage: NSImage?
    private var sourceText = ""
    private var translatedText = ""
    private var selectedProvider: TranslationProvider
    private var retryAction: RetryAction = .none
    private var requestID: UInt = 0
    private let translationRequestScope = UUID()
    private var didTearDown = false

    var onClose: (() -> Void)?

    override init() {
        let configuredProvider = TranslationService.provider
        selectedProvider = configuredProvider == .apple
            && !TranslationService.appleTranslationAvailable ? .google : configuredProvider
        super.init()
        buildWindow()
    }

    func show(image: NSImage, anchorRect: NSRect) {
        retainedImage = image
        positionWindow(near: anchorRect)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startOCR()
    }

    func close() {
        window?.close()
    }

    private func buildWindow() {
        let size = NSSize(width: 520, height: 460)
        let panel = QuickTranslationPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        panel.title = L("Quick Translation")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 420, height: 430)
        panel.delegate = self
        panel.onCopy = { [weak self] in
            self?.copyTranslation()
        }

        let contentView = NSView()
        panel.contentView = contentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let targetLabel = NSTextField(labelWithString: L("Translate to:"))
        targetLabel.font = NSFont.systemFont(ofSize: 12)
        targetLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview(targetLabel)

        let popup = NSPopUpButton()
        for language in TranslationService.availableLanguages {
            popup.addItem(withTitle: language.name)
            popup.lastItem?.representedObject = language.code
        }
        if let index = TranslationService.availableLanguages.firstIndex(
            where: { $0.code == TranslationService.targetLanguage }) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = #selector(languageChanged(_:))
        popup.widthAnchor.constraint(equalToConstant: 155).isActive = true
        header.addArrangedSubview(popup)
        languagePopup = popup

        stack.addArrangedSubview(header)

        let providerRow = NSStackView()
        providerRow.orientation = .horizontal
        providerRow.alignment = .centerY
        providerRow.spacing = 8

        let providerLabel = NSTextField(labelWithString: L("Provider:"))
        providerLabel.font = NSFont.systemFont(ofSize: 12)
        providerLabel.textColor = .secondaryLabelColor
        providerLabel.setContentHuggingPriority(.required, for: .horizontal)
        providerRow.addArrangedSubview(providerLabel)

        let providerSelector = NSPopUpButton(frame: .zero, pullsDown: false)
        let providers = TranslationProvider.allCases.filter {
            $0 != .apple || TranslationService.appleTranslationAvailable
        }
        for provider in providers {
            providerSelector.addItem(withTitle: L(provider.displayNameKey))
            providerSelector.lastItem?.representedObject = provider.rawValue
        }
        if let item = providerSelector.itemArray.first(where: {
            $0.representedObject as? String == selectedProvider.rawValue
        }) {
            providerSelector.select(item)
        }
        providerSelector.target = self
        providerSelector.action = #selector(providerChanged(_:))
        providerSelector.widthAnchor.constraint(equalToConstant: 200).isActive = true
        providerRow.addArrangedSubview(providerSelector)
        providerPopup = providerSelector

        stack.addArrangedSubview(providerRow)
        providerLabel.widthAnchor.constraint(equalTo: targetLabel.widthAnchor).isActive = true

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 7
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.isHidden = true

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        statusRow.addArrangedSubview(progress)
        spinner = progress

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        statusRow.addArrangedSubview(status)
        statusLabel = status

        stack.addArrangedSubview(statusRow)
        statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        self.statusRow = statusRow

        let originalLabel = sectionLabel(L("Original"))
        stack.addArrangedSubview(originalLabel)

        let (sourceScrollView, sourceView) = makeReadOnlyTextView()
        stack.addArrangedSubview(sourceScrollView)
        sourceScrollView.heightAnchor.constraint(equalToConstant: 92).isActive = true
        sourceScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        sourceTextView = sourceView

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let translationLabel = sectionLabel(L("Translation"))
        stack.addArrangedSubview(translationLabel)

        let (translationScrollView, translatedView) = makeReadOnlyTextView()
        stack.addArrangedSubview(translationScrollView)
        translationScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        translationScrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        translationScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 115).isActive = true
        translationScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        translationTextView = translatedView

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let retry = NSButton(title: L("Retry"), target: self, action: #selector(retry(_:)))
        retry.bezelStyle = .rounded
        retry.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retry.imagePosition = .imageLeading
        retry.isHidden = true
        footer.addArrangedSubview(retry)
        retryButton = retry

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(footerSpacer)

        let copy = NSButton(
            title: L("Copy Translation"), target: self, action: #selector(copyTranslation(_:)))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = ""
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.imagePosition = .imageLeading
        copy.isEnabled = false
        footer.addArrangedSubview(copy)
        copyButton = copy

        let close = NSButton(title: L("Close"), target: self, action: #selector(closePanel(_:)))
        close.bezelStyle = .rounded
        footer.addArrangedSubview(close)

        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        window = panel
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeReadOnlyTextView() -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 5)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        scrollView.documentView = textView

        return (scrollView, textView)
    }

    private func positionWindow(near anchorRect: NSRect) {
        guard let window else { return }
        let screen = bestScreen(for: anchorRect)
        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let gap: CGFloat = 12

        var x = anchorRect.midX - windowSize.width / 2
        var y = anchorRect.maxY + gap
        if y + windowSize.height > visibleFrame.maxY {
            y = anchorRect.minY - windowSize.height - gap
        }

        x = min(max(x, visibleFrame.minX), visibleFrame.maxX - windowSize.width)
        y = min(max(y, visibleFrame.minY), visibleFrame.maxY - windowSize.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func bestScreen(for rect: NSRect) -> NSScreen {
        NSScreen.screens.max { lhs, rhs in
            intersectionArea(lhs.frame, rect) < intersectionArea(rhs.frame, rect)
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func selectedTargetLanguage() -> String {
        languagePopup?.selectedItem?.representedObject as? String
            ?? TranslationService.targetLanguage
    }

    private func startOCR() {
        guard let image = retainedImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showOCRError(L("Could not read the selected image"))
            return
        }

        requestID &+= 1
        let activeRequestID = requestID
        sourceText = ""
        translatedText = ""
        retryAction = .none
        sourceTextView?.string = ""
        showProgress(L("Recognizing text..."))
        setTranslationMessage(L("Recognizing text..."), color: .secondaryLabelColor)
        copyButton?.isEnabled = false
        retryButton?.isHidden = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            VisionOCR.performTextRecognition(cgImage: cgImage) { request, error in
                let recognizedText = VisionOCR.recognizedText(from: request)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.requestID == activeRequestID, self.window != nil else {
                        return
                    }
                    let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        if let error {
                            self.showOCRError(error.localizedDescription)
                        } else {
                            self.showNoText()
                        }
                        return
                    }

                    self.sourceText = recognizedText
                    self.sourceTextView?.string = recognizedText
                    self.startTranslation()
                }
            }
        }
    }

    private func startTranslation() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showNoText()
            return
        }

        requestID &+= 1
        let activeRequestID = requestID
        let targetLanguage = selectedTargetLanguage()
        TranslationService.cancelTranslations(requestScope: translationRequestScope)
        TranslationService.targetLanguage = targetLanguage
        translatedText = ""
        retryAction = .none
        copyButton?.isEnabled = false
        retryButton?.isHidden = true
        showProgress(L("Translating..."))
        setTranslationMessage(L("Translating..."), color: .secondaryLabelColor)

        TranslationService.translateBatch(
            texts: [text],
            targetLang: targetLanguage,
            provider: selectedProvider,
            requestScope: translationRequestScope) {
            [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requestID == activeRequestID, self.window != nil else {
                    return
                }

                switch result {
                case .success(let translations):
                    guard let translation = translations.first?.trimmingCharacters(
                        in: .whitespacesAndNewlines), !translation.isEmpty else {
                        self.showTranslationError(L("No response from translation service"))
                        return
                    }
                    self.translatedText = translation
                    self.translationTextView?.string = translation
                    self.translationTextView?.textColor = .labelColor
                    self.finishProgress()
                    self.statusRow?.isHidden = true
                    self.copyButton?.isEnabled = true

                case .failure(let error):
                    self.showTranslationError(error.localizedDescription)
                }
            }
        }
    }

    private func showProgress(_ message: String) {
        statusRow?.isHidden = false
        spinner?.isHidden = false
        spinner?.startAnimation(nil)
        statusLabel?.stringValue = message
        statusLabel?.textColor = .secondaryLabelColor
    }

    private func finishProgress() {
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
    }

    private func showNoText() {
        finishProgress()
        statusRow?.isHidden = false
        retryAction = retainedImage == nil ? .none : .ocr
        statusLabel?.stringValue = L("No text found")
        statusLabel?.textColor = .secondaryLabelColor
        setTranslationMessage(L("No text found"), color: .secondaryLabelColor)
        retryButton?.isHidden = retryAction == .none
        copyButton?.isEnabled = false
    }

    private func showOCRError(_ message: String) {
        finishProgress()
        statusRow?.isHidden = false
        retryAction = retainedImage == nil ? .none : .ocr
        statusLabel?.stringValue = L("Text recognition failed")
        statusLabel?.textColor = .systemRed
        setTranslationMessage(message, color: .systemRed)
        retryButton?.isHidden = retryAction == .none
        copyButton?.isEnabled = false
    }

    private func showTranslationError(_ message: String) {
        finishProgress()
        statusRow?.isHidden = false
        retryAction = .translation
        statusLabel?.stringValue = L("Translation Failed")
        statusLabel?.textColor = .systemRed
        setTranslationMessage(message, color: .systemRed)
        retryButton?.isHidden = false
        copyButton?.isEnabled = false
    }

    private func setTranslationMessage(_ message: String, color: NSColor) {
        translationTextView?.string = message
        translationTextView?.textColor = color
    }

    private func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        TranslationService.targetLanguage = selectedTargetLanguage()
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startTranslation()
        }
    }

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let provider = TranslationProvider(rawValue: rawValue) else { return }
        selectedProvider = provider
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startTranslation()
        } else {
            statusRow?.isHidden = true
        }
    }

    @objc private func retry(_ sender: NSButton) {
        switch retryAction {
        case .none:
            break
        case .ocr:
            startOCR()
        case .translation:
            startTranslation()
        }
    }

    @objc private func copyTranslation(_ sender: NSButton) {
        copyTranslation()
    }

    @objc private func closePanel(_ sender: NSButton) {
        close()
    }

    private func tearDown() {
        guard !didTearDown else { return }
        didTearDown = true
        requestID &+= 1
        TranslationService.cancelTranslations(requestScope: translationRequestScope)
        retainedImage = nil
        sourceText = ""
        translatedText = ""
        window?.delegate = nil
        window = nil
        sourceTextView = nil
        translationTextView = nil
        providerPopup = nil
        statusRow = nil
        onClose?()
        onClose = nil
    }
}

extension QuickTranslationController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        tearDown()
    }
}

private final class QuickTranslationPanel: NSPanel {
    var onCopy: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if KeyboardShortcutMatcher.matches(event, character: "w", modifiers: .command) {
            performClose(nil)
            return true
        }
        if flags == .command && (event.keyCode == 36 || event.keyCode == 76) {
            onCopy?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
