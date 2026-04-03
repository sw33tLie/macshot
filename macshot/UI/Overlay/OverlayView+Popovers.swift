import Cocoa

extension OverlayView {

    func showUploadConfirmPopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.isVisible {
            PopoverHelper.dismiss()
            return
        }

        let current = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 32))

        let toggle = NSButton(checkboxWithTitle: "Confirm before upload", target: nil, action: nil)
        toggle.state = current ? .on : .off
        toggle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: 10, y: (32 - toggle.frame.height) / 2)
        toggle.target = toggle  // self-target via associated handler
        container.addSubview(toggle)

        class ToggleHandler: NSObject {
            @objc func toggled(_ sender: NSButton) {
                UserDefaults.standard.set(sender.state == .on, forKey: "uploadConfirmEnabled")
            }
        }
        let handler = ToggleHandler()
        toggle.target = handler
        toggle.action = #selector(ToggleHandler.toggled(_:))
        objc_setAssociatedObject(toggle, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        let size = NSSize(width: max(180, toggle.frame.width + 20), height: 32)
        container.frame.size = size

        if let anchor = anchorView {
            PopoverHelper.show(
                container, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                container, size: size, at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY),
                in: self, preferredEdge: .maxX)
        }
    }

    func showRedactTypePopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.isVisible {
            PopoverHelper.dismiss()
            return
        }
        let types = AutoRedactor.redactTypeNames
        let picker = ListPickerView()
        picker.items = types.map { item in
            .init(
                title: item.label,
                isSelected: UserDefaults.standard.object(forKey: item.key) as? Bool ?? true)
        }
        picker.onSelect = { [weak self] idx in
            let key = types[idx].key
            let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
            UserDefaults.standard.set(!current, forKey: key)
            picker.items = types.map { item in
                .init(
                    title: item.label,
                    isSelected: UserDefaults.standard.object(forKey: item.key) as? Bool ?? true)
            }
            self?.needsDisplay = true
        }
        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: size, at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY),
                in: self, preferredEdge: .maxX)
        }
    }

    func showTranslatePopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.isVisible {
            PopoverHelper.dismiss()
            return
        }
        let languages = TranslationService.availableLanguages
        let currentCode = TranslationService.targetLanguage
        let picker = ListPickerView()
        let pickerW: CGFloat = 180
        picker.frame.size.width = pickerW
        picker.items = languages.map { lang in
            .init(title: lang.name, isSelected: lang.code == currentCode)
        }
        picker.onSelect = { [weak self] idx in
            let newCode = languages[idx].code
            TranslationService.targetLanguage = newCode
            PopoverHelper.dismiss()
            // Retrigger translation if currently active
            if let self = self, self.translateEnabled {
                self.performTranslate(targetLang: newCode)
            }
            self?.needsDisplay = true
        }

        let contentH = picker.frame.height
        let maxH: CGFloat = 350
        let popoverSize = NSSize(width: pickerW, height: min(maxH, contentH))

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: popoverSize))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = picker

        if let anchor = anchorView {
            PopoverHelper.show(
                scrollView, size: popoverSize, relativeTo: anchor.bounds, of: anchor,
                preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                scrollView, size: popoverSize,
                at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY),
                in: self, preferredEdge: .maxX)
        }

        // Scroll to selected after popover is shown
        DispatchQueue.main.async {
            picker.scrollToSelected()
        }
    }

    func showBeautifyGradientPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        let picker = GradientPickerView(selectedIndex: beautifyStyleIndex)
        picker.onSelect = { [weak self] idx in
            self?.beautifyStyleIndex = idx
            UserDefaults.standard.set(idx, forKey: "beautifyStyleIndex")
            self?.cachedCompositedImage = nil
            self?.needsDisplay = true
        }
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: picker.preferredSize, relativeTo: anchor.bounds, of: anchor,
                preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: picker.preferredSize,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .minY)
        }
    }

    func showEmojiPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        let picker = EmojiPickerView()
        picker.onSelectEmoji = { [weak self] emoji in
            self?.currentStampImage = StampEmojis.renderEmoji(emoji)
            self?.currentStampEmoji = emoji
            self?.needsDisplay = true
        }
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: picker.preferredSize, relativeTo: anchor.bounds, of: anchor,
                preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: picker.preferredSize,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .minY)
        }
    }

    // MARK: - Recording Settings Popover

    func showRecordingSettingsPopover(anchorView: NSView?) {
        if PopoverHelper.isVisible {
            PopoverHelper.dismiss()
            return
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        var y: CGFloat = 8
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let labelColor = NSColor.secondaryLabelColor

        func addRow(label: String, control: NSView, controlWidth: CGFloat = 140) {
            let lbl = NSTextField(labelWithString: label)
            lbl.font = labelFont
            lbl.textColor = labelColor
            lbl.frame = NSRect(x: 10, y: y + 2, width: 76, height: 18)
            container.addSubview(lbl)
            control.frame = NSRect(x: 88, y: y, width: controlWidth, height: 22)
            container.addSubview(control)
            y += 28
        }

        // Read current effective values (session override > UserDefaults default)
        let effectiveFormat =
            sessionRecordingFormat ?? UserDefaults.standard.string(forKey: "recordingFormat")
            ?? "mp4"
        let effectiveFPS =
            sessionRecordingFPS
            ?? (UserDefaults.standard.integer(forKey: "recordingFPS") > 0
                ? UserDefaults.standard.integer(forKey: "recordingFPS") : 30)
        let effectiveOnStop =
            sessionRecordingOnStop ?? UserDefaults.standard.string(forKey: "recordingOnStop")
            ?? "editor"

        // Format: MP4 / GIF
        let formatSeg = NSSegmentedControl(
            labels: ["MP4", "GIF"], trackingMode: .selectOne,
            target: nil, action: nil)
        formatSeg.selectedSegment = effectiveFormat == "gif" ? 1 : 0
        (formatSeg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect

        // FPS popup
        let fpsPopup = NSPopUpButton()
        fpsPopup.controlSize = .small
        fpsPopup.font = NSFont.systemFont(ofSize: 11)

        func populateFPS(isGIF: Bool, selectedFPS: Int) {
            fpsPopup.removeAllItems()
            if isGIF {
                fpsPopup.addItems(withTitles: ["5", "10", "15"])
                if selectedFPS <= 5 {
                    fpsPopup.selectItem(at: 0)
                } else if selectedFPS <= 10 {
                    fpsPopup.selectItem(at: 1)
                } else {
                    fpsPopup.selectItem(at: 2)
                }
            } else {
                fpsPopup.addItems(withTitles: ["15", "30", "60", "120"])
                if selectedFPS <= 15 {
                    fpsPopup.selectItem(at: 0)
                } else if selectedFPS <= 30 {
                    fpsPopup.selectItem(at: 1)
                } else if selectedFPS <= 60 {
                    fpsPopup.selectItem(at: 2)
                } else {
                    fpsPopup.selectItem(at: 3)
                }
            }
        }
        populateFPS(isGIF: effectiveFormat == "gif", selectedFPS: effectiveFPS)

        // Handlers write to session overrides, not UserDefaults
        class FormatHandler: NSObject {
            weak var overlayView: OverlayView?
            let fpsPopup: NSPopUpButton
            let populateFPS: (Bool, Int) -> Void
            init(
                overlayView: OverlayView?, fpsPopup: NSPopUpButton,
                populateFPS: @escaping (Bool, Int) -> Void
            ) {
                self.overlayView = overlayView
                self.fpsPopup = fpsPopup
                self.populateFPS = populateFPS
                super.init()
            }
            @objc func changed(_ sender: NSSegmentedControl) {
                let isGIF = sender.selectedSegment == 1
                overlayView?.sessionRecordingFormat = isGIF ? "gif" : "mp4"
                let currentFPS = overlayView?.sessionRecordingFPS ?? 30
                populateFPS(isGIF, currentFPS)
            }
        }

        class FPSHandler: NSObject {
            weak var overlayView: OverlayView?
            init(overlayView: OverlayView?) {
                self.overlayView = overlayView
                super.init()
            }
            @objc func changed(_ sender: NSPopUpButton) {
                if let title = sender.selectedItem?.title, let fps = Int(title) {
                    overlayView?.sessionRecordingFPS = fps
                }
            }
        }

        class WhenDoneHandler: NSObject {
            weak var overlayView: OverlayView?
            init(overlayView: OverlayView?) {
                self.overlayView = overlayView
                super.init()
            }
            @objc func changed(_ sender: NSPopUpButton) {
                let values = ["editor", "finder", "clipboard"]
                overlayView?.sessionRecordingOnStop = values[sender.indexOfSelectedItem]
            }
        }

        let fpsHandler = FPSHandler(overlayView: self)
        fpsPopup.target = fpsHandler
        fpsPopup.action = #selector(FPSHandler.changed(_:))
        objc_setAssociatedObject(fpsPopup, "handler", fpsHandler, .OBJC_ASSOCIATION_RETAIN)

        let formatHandler = FormatHandler(
            overlayView: self, fpsPopup: fpsPopup, populateFPS: populateFPS)
        formatSeg.target = formatHandler
        formatSeg.action = #selector(FormatHandler.changed(_:))
        objc_setAssociatedObject(formatSeg, "handler", formatHandler, .OBJC_ASSOCIATION_RETAIN)

        // When done popup
        let whenDonePopup = NSPopUpButton()
        whenDonePopup.addItems(withTitles: ["Open editor", "Show in Finder", "Copy to clipboard"])
        whenDonePopup.controlSize = .small
        whenDonePopup.font = NSFont.systemFont(ofSize: 11)
        switch effectiveOnStop {
        case "finder": whenDonePopup.selectItem(at: 1)
        case "clipboard": whenDonePopup.selectItem(at: 2)
        default: whenDonePopup.selectItem(at: 0)
        }

        let whenDoneHandler = WhenDoneHandler(overlayView: self)
        whenDonePopup.target = whenDoneHandler
        whenDonePopup.action = #selector(WhenDoneHandler.changed(_:))
        objc_setAssociatedObject(
            whenDonePopup, "handler", whenDoneHandler, .OBJC_ASSOCIATION_RETAIN)

        addRow(label: "Format:", control: formatSeg)
        addRow(label: "FPS:", control: fpsPopup)
        addRow(label: "When done:", control: whenDonePopup)

        let size = NSSize(width: 240, height: y + 4)
        container.frame.size = size

        if let anchor = anchorView {
            PopoverHelper.show(
                container, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                container, size: size,
                at: NSPoint(x: bounds.midX, y: bounds.midY),
                in: self, preferredEdge: .maxY)
        }
    }

    // MARK: - Auto-redact & Translate actions

    func performAutoRedact() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? compositedImage() : nil
        AutoRedactor.redactPII(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performRedactAllText() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? compositedImage() : nil
        AutoRedactor.redactAllText(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performAutoRedactPII() {
        performAutoRedact()
    }

    func performRedactFaces() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? compositedImage() : nil
        AutoRedactor.redactFaces(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performRedactPeople() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? compositedImage() : nil
        AutoRedactor.redactPeople(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func showEffectsPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        if PopoverHelper.isVisible {
            PopoverHelper.dismiss()
            return
        }
        let picker = EffectsPickerView(config: effectsConfig)
        picker.onConfigChanged = { [weak self] config in
            guard let self = self else { return }
            self.effectsPreset = config.preset
            self.effectsBrightness = config.brightness
            self.effectsContrast = config.contrast
            self.effectsSaturation = config.saturation
            self.effectsSharpness = config.sharpness
            UserDefaults.standard.set(config.preset.rawValue, forKey: "effectsPreset")
            UserDefaults.standard.set(Double(config.brightness), forKey: "effectsBrightness")
            UserDefaults.standard.set(Double(config.contrast), forKey: "effectsContrast")
            UserDefaults.standard.set(Double(config.saturation), forKey: "effectsSaturation")
            UserDefaults.standard.set(Double(config.sharpness), forKey: "effectsSharpness")
            self.cachedCompositedImage = nil
            self.cachedEffectsScreenshot = nil
            self.rebuildToolbarLayout()
            self.needsDisplay = true
        }
        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: size,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .maxY)
        }
    }

    func performTranslate(targetLang: String) {
        guard state == .selected, let screenshot = screenshotImage else { return }
        annotations.removeAll { $0.tool == .translateOverlay }
        isTranslating = true
        needsDisplay = true

        TranslateOverlay.translate(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            targetLang: targetLang,
            onError: { [weak self] msg in
                self?.isTranslating = false
                self?.showOverlayError(msg)
                self?.needsDisplay = true
            },
            completion: { [weak self] anns in
                guard let self = self else { return }
                self.isTranslating = false
                self.annotations.removeAll { $0.tool == .translateOverlay }
                self.annotations.append(contentsOf: anns)
                self.undoStack.append(contentsOf: anns.map { .added($0) })
                self.redoStack.removeAll()
                self.needsDisplay = true
            }
        )
    }
}
