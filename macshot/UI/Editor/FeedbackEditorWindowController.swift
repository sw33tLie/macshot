import Cocoa

private final class FeedbackEditorBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class FeedbackNotesStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class FeedbackActionButton: NSButton {
    var handler: (() -> Void)?
    override var title: String {
        didSet { toolTip = title }
    }
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bezelStyle = .rounded
        target = self
        action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { handler?() }
}

/// A separate editor, based on the detached editor's window/scroll layout.
/// Feedback never enters the image annotation undo stack or history format.
@MainActor final class FeedbackEditorWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let window: NSWindow?
    private static var controllers: [FeedbackEditorWindowController] = []
    private let source: CGImage
    private(set) var document: FeedbackDocument
    private let canvas: FeedbackEditorView
    private let scroll = NSScrollView()
    private let list = FeedbackNotesStackView()
    private let text = ScopedUndoTextView()
    private let status = NSTextField(labelWithString: L("Draft not saved yet"))
    private let details = NSTextField(wrappingLabelWithString: L("Click a point or select a region, then write a modification request."))
    private let ocrLabel = NSTextField(wrappingLabelWithString: "")
    private let history = UndoManager()
    private var selected: UUID?
    private var editingBaseline: FeedbackDocument?
    private var revision: UInt64 = 0
    private var savedRevision: UInt64?
    private var isWorking = false
    private var isSubmitted = false
    private var sessionCloseButton: FeedbackActionButton?
    private var sessionSubmitButton: FeedbackActionButton?
    private var mayClose = false
    private var isRefreshing = false
    private var ocrGeneration = UUID()
    private var actions: [NSControl] = []
    private var pendingSave: DispatchWorkItem?
    var onReturnToImageEditor: (() -> Void)?
    private var returnToImageEditor = false
    var onSubmit: ((FeedbackDocument, CGImage, CGImage, @escaping (Result<Void, Error>) -> Void) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var sessionActive = false

    @discardableResult static func open(image: CGImage, document: FeedbackDocument? = nil) -> FeedbackEditorWindowController {
        if let document, let existing = controllers.first(where: { $0.document.id == document.id }) {
            existing.showWindow(nil)
            return existing
        }
        let controller = FeedbackEditorWindowController(image: image, document: document)
        controller.onReturnToImageEditor = {
            DetachedEditorWindowController.open(image: NSImage(cgImage: image,
                size: NSSize(width: image.width, height: image.height)), disableBeautify: true)
        }
        controllers.append(controller)
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.fit()
        return controller
    }

    init(image: CGImage, document: FeedbackDocument? = nil) {
        source = image
        self.document = document ?? FeedbackDocument(width: image.width, height: image.height)
        canvas = FeedbackEditorView(image: image)
        let frame = NSScreen.preferredVisibleFrame
        let size = NSSize(width: min(1200, frame.width * 0.92), height: min(820, frame.height * 0.92))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.window = window
        super.init()
        window.contentView = FeedbackEditorBackgroundView(frame: CGRect(origin: .zero, size: size))
        window.center()
        window.title = L("macshot · Modification Feedback")
        window.minSize = NSSize(width: 900, height: 650)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildInterface()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func showWindow(_ sender: Any?) { window?.makeKeyAndOrderFront(sender) }

    private func button(_ title: String, _ handler: @escaping () -> Void) -> NSButton {
        let b = FeedbackActionButton(title, handler: handler)
        actions.append(b)
        return b
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 0; root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])

        let tools = NSStackView()
        tools.spacing = 10; tools.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        tools.wantsLayer = true; tools.layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        tools.appearance = NSAppearance(named: .darkAqua)
        let mode = NSSegmentedControl(labels: [L("Point Note"), L("Region Note")], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        mode.selectedSegment = 0
        actions.append(mode)
        tools.addArrangedSubview(mode)
        for b in [button(L("Global Note"), { [weak self] in self?.add(FeedbackNote(kind: .global)) }),
                  button(L("Undo"), { [weak self] in self?.commitText(); self?.history.undo() }),
                  button(L("Redo"), { [weak self] in self?.commitText(); self?.history.redo() }),
                  button("−", { [weak self] in self?.zoom(0.8) }), button("＋", { [weak self] in self?.zoom(1.25) }),
                  button(L("Fit Canvas"), { [weak self] in self?.fit() })] { tools.addArrangedSubview(b) }
        root.addArrangedSubview(tools)
        tools.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let body = NSStackView()
        body.spacing = 0; body.alignment = .top
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.windowBackgroundColor
        scroll.allowsMagnification = true; scroll.minMagnification = 0.05; scroll.maxMagnification = 8
        scroll.contentView = CenteringClipView(frame: scroll.contentView.frame)
        scroll.documentView = canvas
        body.addArrangedSubview(scroll)

        let side = NSStackView()
        side.orientation = .vertical; side.alignment = .leading; side.spacing = 12
        side.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let title = NSTextField(labelWithString: L("Modification Feedback"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        side.addArrangedSubview(title)
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        listScroll.documentView = list
        NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: listScroll.contentView.leadingAnchor), list.trailingAnchor.constraint(equalTo: listScroll.contentView.trailingAnchor), list.topAnchor.constraint(equalTo: listScroll.contentView.topAnchor)])
        side.addArrangedSubview(listScroll)
        side.addArrangedSubview(details)
        let editScroll = NSScrollView()
        editScroll.borderType = .bezelBorder; editScroll.hasVerticalScroller = true
        text.isRichText = false; text.allowsUndo = true; text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.delegate = self
        editScroll.documentView = text
        side.addArrangedSubview(editScroll)
        ocrLabel.font = .systemFont(ofSize: 12); ocrLabel.textColor = .secondaryLabelColor
        side.addArrangedSubview(ocrLabel)
        let noteActions = NSStackView(views: [button(L("Extract Region Text"), { [weak self] in self?.recognize() }), button(L("Delete Note"), { [weak self] in self?.deleteSelected() })])
        side.addArrangedSubview(noteActions)
        noteActions.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -36).isActive = true
        let hint = NSTextField(wrappingLabelWithString: L("OCR only reads image content. Empty notes are excluded from export. The source is fixed with redactions preserved."))
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        side.addArrangedSubview(hint)
        body.addArrangedSubview(side)
        root.addArrangedSubview(body)

        let bottom = NSStackView()
        bottom.distribution = .fill
        bottom.spacing = 10; bottom.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        status.font = .systemFont(ofSize: 12); status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(status)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        bottom.addArrangedSubview(spacer)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 12).isActive = true
        bottom.addArrangedSubview(button(L("Copy Feedback Text"), { [weak self] in self?.copyDescription() }))
        bottom.addArrangedSubview(button(L("Export Feedback…"), { [weak self] in self?.exportFeedback() }))
        bottom.addArrangedSubview(button(L("Return to Image Editor"), { [weak self] in
            self?.returnToImageEditor = true
            self?.window?.performClose(nil)
        }))
        root.addArrangedSubview(bottom)
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalTo: root.widthAnchor), bottom.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 440), side.widthAnchor.constraint(equalToConstant: 340),
            side.heightAnchor.constraint(equalTo: body.heightAnchor), scroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            listScroll.heightAnchor.constraint(equalTo: body.heightAnchor, multiplier: 0.36), editScroll.heightAnchor.constraint(equalToConstant: 140)
        ])
        for v in [listScroll, details, editScroll, ocrLabel, hint] { v.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -36).isActive = true }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvas.onCreate = { [weak self] in self?.add($0) }
        canvas.onSelect = { [weak self] in self?.select($0) }
        canvas.onMove = { [weak self] id, rect in
            self?.change { d in if let i = d.notes.firstIndex(where: { $0.id == id }) { d.notes[i].rect = rect; d.notes[i].ocr = nil } }
        }
    }

    func configureSession(submit: @escaping (FeedbackDocument, CGImage, CGImage, @escaping (Result<Void, Error>) -> Void) -> Void,
                          cancel: @escaping () -> Void) {
        sessionActive = true; onSubmit = submit; onCancel = cancel
        window?.title = L("macshot · AI Is Waiting for Feedback")
        guard let root = window?.contentView?.subviews.first as? NSStackView,
              let bottom = root.arrangedSubviews.last as? NSStackView else { return }
        if let last = bottom.arrangedSubviews.last { bottom.removeArrangedSubview(last); last.removeFromSuperview() }
        let closeButton = button(L("Cancel Session"), { [weak self] in self?.window?.performClose(nil) })
        sessionCloseButton = closeButton as? FeedbackActionButton
        bottom.addArrangedSubview(closeButton)
        let submitButton = button(L("Submit to AI"), { [weak self] in self?.submitFeedback() })
        sessionSubmitButton = submitButton as? FeedbackActionButton
        submitButton.bezelColor = .systemBlue
        bottom.addArrangedSubview(submitButton)
        status.stringValue = L("AI is waiting · drafts are not submitted automatically")
    }

    private func refresh() {
        canvas.notes = document.notes; canvas.selected = selected
        for v in list.arrangedSubviews { list.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, note) in document.notes.enumerated() {
            let kind = note.kind == .global ? L("Global Note") : (note.kind == .region ? L("Region Note") : L("Point Note"))
            let title = "\(i+1) · \(kind)  " + (note.comment.isEmpty ? L("Write a modification request…") : String(note.comment.prefix(32)))
            let b = FeedbackActionButton(title) { [weak self] in self?.select(note.id) }
            b.alignment = .left; b.lineBreakMode = .byTruncatingTail
            if note.id == selected { b.contentTintColor = .systemBlue }
            list.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        isRefreshing = true
        let note = document.notes.first { $0.id == selected }
        text.discardUndoHistory()
        text.string = note?.comment ?? ""
        text.isEditable = note != nil && !isWorking && !isSubmitted
        details.stringValue = note.map { $0.kind == .global ? L("Global Note") : String(format: L("Position: %d, %d · image pixels"), Int($0.rect.minX), Int($0.rect.minY)) }
            ?? L("Select a point or region, then write a modification request.")
        ocrLabel.stringValue = note?.ocr.map { String(format: L("Region text: %@"), $0) } ?? ""
        isRefreshing = false
    }

    private func select(_ id: UUID) {
        guard !isWorking else { return }
        commitText(); selected = id; refresh()
        if let note = document.notes.first(where: { $0.id == id }), note.kind != .global {
            let r = note.rect
            canvas.scrollToVisible(CGRect(x: max(0,r.minX-30), y: max(0,CGFloat(document.height)-r.maxY-30), width: max(60,r.width+60), height: max(60,r.height+60)))
        }
        window?.makeFirstResponder(text)
    }

    private func add(_ note: FeedbackNote) {
        guard !isWorking, !isSubmitted, document.notes.count < 1000 else { return }
        change { $0.notes.append(note) }
        select(note.id)
    }
    private func deleteSelected() {
        guard let selected else { return }
        change { $0.notes.removeAll { $0.id == selected } }
        self.selected = nil; refresh()
    }

    private func restore(_ old: FeedbackDocument) {
        let current = document
        history.registerUndo(withTarget: self) { $0.restore(current) }
        document = old; editingBaseline = nil
        refresh(); persist()
    }
    private func change(_ edit: (inout FeedbackDocument) -> Void) {
        guard !isWorking, !isSubmitted else { return }
        commitText()
        let old = document
        edit(&document)
        guard old != document else { return }
        history.registerUndo(withTarget: self) { $0.restore(old) }
        refresh(); persist()
    }
    private func commitText() {
        if text.isEditable {
            if text.hasMarkedText() { text.unmarkText() }
            if let i = document.notes.firstIndex(where: { $0.id == selected }), document.notes[i].comment != text.string {
                if editingBaseline == nil { editingBaseline = document }
                document.notes[i].comment = text.string
                persist()
            }
        }
        guard let old = editingBaseline else { return }
        editingBaseline = nil
        if old != document { history.registerUndo(withTarget: self) { $0.restore(old) } }
        text.discardUndoHistory()
    }
    func textDidChange(_ notification: Notification) {
        guard !isRefreshing, !isWorking, let i = document.notes.firstIndex(where: { $0.id == selected }) else { return }
        if editingBaseline == nil { editingBaseline = document }
        document.notes[i].comment = text.string
        persist()
    }

    private func persist(immediately: Bool = false, completion: ((Bool) -> Void)? = nil) {
        pendingSave?.cancel()
        revision &+= 1
        let revision = revision, doc = document, image = source
        status.stringValue = L("Saving draft…")
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try FeedbackDraftStore.save(doc, source: image) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if revision == self.revision {
                    switch result {
                    case .success:
                        self.savedRevision = revision
                        if !self.isSubmitted {
                            self.status.stringValue = self.sessionActive ? L("Draft saved · AI is waiting for submission") : L("Draft saved")
                        }
                    case .failure(let error): self.status.stringValue = String(format: L("Could not save draft: %@"), FeedbackLocalization.message(error))
                    }
                }
                if case .success = result { completion?(true) } else { completion?(false) }
            }
        }
        pendingSave = work
        if immediately { FeedbackDraftStore.queue.async(execute: work) }
        else { FeedbackDraftStore.queue.asyncAfter(deadline: .now() + 0.4, execute: work) }
    }

    static func prepareForTermination() {
        for controller in controllers { controller.commitText(); controller.persist(immediately: true) }
    }

    static var hasPendingDrafts: Bool {
        controllers.contains { $0.savedRevision != $0.revision || $0.editingBaseline != nil }
    }

    static func saveBeforeTermination() async -> Bool {
        for controller in controllers {
            controller.commitText()
            let saved = await withCheckedContinuation { continuation in
                controller.persist(immediately: true) { continuation.resume(returning: $0) }
            }
            if !saved {
                controller.showError(NSError(domain: "macshot.feedback", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L("Could not save the draft. Quit was stopped. Please try again.")]))
                return false
            }
        }
        return true
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) { canvas.regionMode = sender.selectedSegment == 1 }
    private func zoom(_ factor: CGFloat) { scroll.magnification = max(scroll.minMagnification, min(scroll.maxMagnification, scroll.magnification * factor)) }
    private func fit() {
        scroll.layoutSubtreeIfNeeded()
        let size = scroll.contentView.bounds.size
        scroll.magnification = max(scroll.minMagnification, min(1, min(size.width/CGFloat(source.width), size.height/CGFloat(source.height))))
    }

    private func recognize() {
        commitText()
        guard !isWorking, let note = document.notes.first(where: { $0.id == selected }), note.kind == .region,
              let crop = source.cropping(to: note.rect.integral) else { return }
        let token = UUID(); ocrGeneration = token
        status.stringValue = L("Reading region text…")
        VisionOCR.performTextRecognition(cgImage: crop) { [weak self] observations, error in
            let value = observations.map(\.text).joined(separator: "\n")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ocrGeneration == token, !self.isWorking,
                      self.document.notes.contains(where: { $0.id == note.id && $0.rect == note.rect }) else { return }
                if let error { self.showError(error); return }
                self.change { d in if let i = d.notes.firstIndex(where: { $0.id == note.id }) { d.notes[i].ocr = value } }
            }
        }
    }

    private func copyDescription() {
        guard !isWorking else { return }
        commitText()
        do {
            let root = try FeedbackSessionManager.shared.resolveDirectoryForManualExport()
            do {
                let doc = try document.validated()
                let preview = try FeedbackExport.preview(source, document: doc)
                let markdown = doc.markdown(labels: FeedbackLocalization.markdownLabels)
                let taskID = UUID()
                let folder = root.appendingPathComponent(taskID.uuidString, isDirectory: true)
                let image = source
                setWorking(true); status.stringValue = L("Exporting…")
                MediaExportCoordinator.shared.start(title: L("Export Feedback"), status: L("Writing feedback images and notes"),
                    operation: { cancellation, _ in
                        try cancellation.beginPublication()
                        try await MediaExportIO.perform {
                            _ = try FeedbackExport.writeManual(source: image, preview: preview, document: doc,
                                                               root: root, taskID: taskID, markdown: markdown)
                        }
                    }, completion: { [weak self] result in
                        root.stopAccessingSecurityScopedResource()
                        guard let self else { return }
                        self.setWorking(false)
                        switch result {
                        case .success:
                            let handoff = FeedbackExport.manualClipboardText(markdown: markdown, root: root, taskID: taskID)
                            NSPasteboard.general.clearContents()
                            guard NSPasteboard.general.setString(handoff, forType: .string) else {
                                self.showError(NSError(domain: "macshot.feedback", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Could not copy feedback text to the clipboard. The files were saved at \(folder.path)."]))
                                return
                            }
                            self.status.stringValue = L("Feedback exported")
                            if !self.sessionActive { self.window?.performClose(nil) }
                        case .failure(let error): self.showError(error)
                        }
                    })
            } catch {
                root.stopAccessingSecurityScopedResource()
                throw error
            }
        } catch { showError(error) }
    }

    private func setWorking(_ working: Bool) {
        isWorking = working; text.isEditable = !working && !isSubmitted && selected != nil
        for action in actions { action.isEnabled = !working && (!isSubmitted || action === sessionCloseButton) }
        canvas.isHidden = false
    }

    private func exportFeedback() {
        guard !isWorking, let window else { return }
        commitText()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L("Export Feedback"); panel.message = L("Choose a parent folder. A new feedback folder will be created without overwriting existing files.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let parent = panel.url else { return }
            let accessed = parent.startAccessingSecurityScopedResource()
            let folder = parent.appendingPathComponent("macshot-feedback-\(UUID().uuidString)")
            do {
                let doc = try self.document.validated(), image = self.source
                let preview = try FeedbackExport.preview(image, document: doc)
                let markdown = doc.markdown(labels: FeedbackLocalization.markdownLabels)
                self.setWorking(true); self.status.stringValue = L("Exporting…")
                MediaExportCoordinator.shared.start(title: L("Export Feedback"), status: L("Writing feedback images and notes"), operation: { cancellation, _ in
                    try cancellation.beginPublication()
                    try await MediaExportIO.perform {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                        try FeedbackExport.write(source: image, preview: preview, document: doc, directory: folder, markdown: markdown)
                    }
                }, completion: { [weak self] result in
                    if accessed { parent.stopAccessingSecurityScopedResource() }
                    guard let self else { return }
                    self.setWorking(false)
                    switch result {
                    case .success: self.status.stringValue = L("Feedback exported"); NSWorkspace.shared.activateFileViewerSelecting([folder])
                    case .failure(let error): self.showError(error)
                    }
                })
            } catch { if accessed { parent.stopAccessingSecurityScopedResource() }; self.showError(error) }
        }
    }

    private func submitFeedback() {
        guard !isWorking, sessionActive, let onSubmit else { return }
        commitText()
        if document.submitted.notes.isEmpty {
            let alert = NSAlert(); alert.messageText = L("Submit empty feedback?")
            alert.informativeText = L("This round has no written requests. AI will receive empty feedback.")
            alert.addButton(withTitle: L("Submit Empty Feedback")); alert.addButton(withTitle: L("Continue Editing"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let doc = try document.validated()
            let preview = try FeedbackExport.preview(source, document: doc)
            setWorking(true); status.stringValue = L("Submitting…")
            onSubmit(doc, source, preview) { [weak self] result in
                guard let self else { return }
                self.setWorking(false)
                switch result {
                case .success:
                    self.sessionActive = false; self.isSubmitted = true
                    self.onCancel = nil; self.onSubmit = nil
                    self.sessionCloseButton?.title = L("Close")
                    self.sessionSubmitButton?.title = L("Submitted to AI")
                    self.setWorking(false)
                    self.status.stringValue = L("Submitted to AI"); self.window?.title = L("macshot · Feedback Submitted")
                case .failure(let error): if self.sessionActive { self.showError(error) }
                }
            }
        } catch { showError(error) }
    }

    func endSession(message: String) {
        sessionActive = false; onSubmit = nil; onCancel = nil
        sessionCloseButton?.title = L("Close")
        sessionSubmitButton?.title = L("Continue Editing Draft")
        sessionSubmitButton?.handler = { [weak self] in
            self?.status.stringValue = L("Draft saved")
            self?.window?.title = L("macshot · Modification Feedback")
        }
        status.stringValue = message; window?.title = "macshot · \(message)"
    }

    private func showError(_ error: Error) {
        status.stringValue = FeedbackLocalization.message(error)
        guard let window else { return }
        let alert = NSAlert(error: FeedbackLocalization.localizedError(error)); alert.beginSheetModal(for: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if mayClose { return true }
        guard !isWorking else { return false }
        commitText()
        if sessionActive {
            let alert = NSAlert(); alert.messageText = L("Cancel this feedback session?")
            alert.informativeText = L("Notes remain a local draft and will not be returned as submitted feedback.")
            alert.addButton(withTitle: L("Continue Editing")); alert.addButton(withTitle: L("Cancel Session"))
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        setWorking(true)
        persist(immediately: true) { [weak self] success in
            guard let self else { return }
            self.setWorking(false)
            if success { self.onCancel?(); self.mayClose = true; sender.close() }
            else { self.showError(NSError(domain: "macshot.feedback", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Could not save the draft. Please try again. The window remains open.")])) }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        text.discardUndoHistory(); history.removeAllActions(); text.delegate = nil
        Self.controllers.removeAll { $0 === self }
        if returnToImageEditor { onReturnToImageEditor?() }
        onReturnToImageEditor = nil
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}
