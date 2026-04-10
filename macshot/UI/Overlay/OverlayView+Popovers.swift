import Cocoa
import UniformTypeIdentifiers

extension OverlayView {

    func showUploadConfirmPopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.isVisible {
            PopoverHelper.dismiss()
            return
        }

        let current = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 32))

        let toggle = NSButton(checkboxWithTitle: L("Confirm before upload"), target: nil, action: nil)
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

        let showPopover: ([String: Bool]?) -> Void = { [weak self] appleAvailability in
            guard let self = self else { return }
            // When Apple Translation is active, only show installed languages
            let filteredLanguages: [(code: String, name: String)]
            if let avail = appleAvailability {
                filteredLanguages = languages.filter { avail[$0.code] == true }
            } else {
                filteredLanguages = languages
            }
            let picker = ListPickerView()
            let pickerW: CGFloat = 220
            picker.frame.size.width = pickerW
            picker.items = filteredLanguages.map { lang in
                return .init(title: lang.name, isSelected: lang.code == currentCode,
                             isEnabled: true, subtitle: nil)
            }
            picker.onSelect = { [weak self] idx in
                let newCode = filteredLanguages[idx].code
                TranslationService.targetLanguage = newCode
                PopoverHelper.dismiss()
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

            DispatchQueue.main.async {
                picker.scrollToSelected()
            }
        }

        // If Apple Translation is selected, check which languages are installed
        if #available(macOS 15.0, *), TranslationService.provider == .apple {
            TranslationService.checkAppleLanguageAvailability { availability in
                showPopover(availability)
            }
        } else {
            showPopover(nil)
        }
    }

    func showBeautifyGradientPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        let picker = GradientPickerView(selectedIndex: beautifyStyleIndex)
        picker.onSelect = { [weak self] idx in
            guard let self = self else { return }
            self.beautifyStyleIndex = idx
            UserDefaults.standard.set(idx, forKey: "beautifyStyleIndex")
            if idx >= 0 {
                // Gradient selected — clear custom background
                self.customBeautifyBackground = nil
            } else {
                // Custom image selected — load from storage
                self.loadCustomBeautifyBackground()
            }
            self.cachedCompositedImage = nil
            self.needsDisplay = true
            self.updateBeautifySwatch(styleIndex: idx)
            // Rebuild options row so blur slider appears/disappears
            self.rebuildToolbarLayout()
        }
        picker.onCustomImage = { [weak self] in
            PopoverHelper.dismiss()
            self?.pickCustomBeautifyBackground()
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

    func pickCustomBeautifyBackground() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        // Lower overlay window level temporarily so the open panel is interactive
        let savedLevel = window?.level
        window?.level = .normal
        panel.beginSheetModal(for: window!) { [weak self] response in
            self?.window?.level = savedLevel ?? .normal
            guard let self = self, response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            // Store image data (PNG) in UserDefaults for persistence
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                UserDefaults.standard.set(pngData, forKey: "beautifyCustomBgImageData")
            }
            self.customBeautifyBackground = image
            self.prepareBeautifyBackgroundCache()
            self.beautifyStyleIndex = -1
            UserDefaults.standard.set(-1, forKey: "beautifyStyleIndex")
            self.cachedCompositedImage = nil
            self.needsDisplay = true
            self.updateBeautifySwatch(styleIndex: -1)
            self.rebuildToolbarLayout()
        }
    }

    func loadCustomBeautifyBackground() {
        guard let data = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
              let image = NSImage(data: data) else { return }
        customBeautifyBackground = image
        prepareBeautifyBackgroundCache()
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
        let effectiveFPS =
            sessionRecordingFPS
            ?? (UserDefaults.standard.integer(forKey: "recordingFPS") > 0
                ? UserDefaults.standard.integer(forKey: "recordingFPS") : 30)
        let effectiveOnStop =
            sessionRecordingOnStop ?? UserDefaults.standard.string(forKey: "recordingOnStop")
            ?? "editor"

        // FPS popup
        let fpsPopup = NSPopUpButton()
        fpsPopup.controlSize = .small
        fpsPopup.font = NSFont.systemFont(ofSize: 11)
        fpsPopup.addItems(withTitles: ["15", "30", "60", "120"])
        if effectiveFPS <= 15 {
            fpsPopup.selectItem(at: 0)
        } else if effectiveFPS <= 30 {
            fpsPopup.selectItem(at: 1)
        } else if effectiveFPS <= 60 {
            fpsPopup.selectItem(at: 2)
        } else {
            fpsPopup.selectItem(at: 3)
        }

        // Handlers write to session overrides, not UserDefaults
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

        // When done popup
        let whenDonePopup = NSPopUpButton()
        whenDonePopup.addItems(withTitles: [L("Open editor"), L("Show in Finder"), L("Copy to clipboard")])
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

        // Delay popup
        let delayPopup = NSPopUpButton()
        delayPopup.controlSize = .small
        delayPopup.font = NSFont.systemFont(ofSize: 11)
        let delayOptions = [0, 3, 5, 10, 30]
        for s in delayOptions {
            delayPopup.addItem(withTitle: s == 0 ? L("None") : String(format: L("%d seconds"), s))
        }
        let effectiveDelay = sessionRecordingDelay ?? UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        if let idx = delayOptions.firstIndex(of: effectiveDelay) {
            delayPopup.selectItem(at: idx)
        }

        class DelayHandler: NSObject {
            weak var overlayView: OverlayView?
            let options: [Int]
            init(overlayView: OverlayView?, options: [Int]) {
                self.overlayView = overlayView
                self.options = options
                super.init()
            }
            @objc func changed(_ sender: NSPopUpButton) {
                overlayView?.sessionRecordingDelay = options[sender.indexOfSelectedItem]
            }
        }
        let delayHandler = DelayHandler(overlayView: self, options: delayOptions)
        delayPopup.target = delayHandler
        delayPopup.action = #selector(DelayHandler.changed(_:))
        objc_setAssociatedObject(delayPopup, "handler", delayHandler, .OBJC_ASSOCIATION_RETAIN)

        // Hide HUD checkbox
        let effectiveHideHUD = sessionHideRecordingHUD ?? UserDefaults.standard.bool(forKey: "hideRecordingHUD")
        let hideHUDCheck = NSButton(checkboxWithTitle: L("Hide controls"), target: nil, action: nil)
        hideHUDCheck.controlSize = .small
        hideHUDCheck.font = NSFont.systemFont(ofSize: 11)
        hideHUDCheck.state = effectiveHideHUD ? .on : .off

        class HideHUDHandler: NSObject {
            weak var overlayView: OverlayView?
            init(overlayView: OverlayView?) { self.overlayView = overlayView; super.init() }
            @objc func changed(_ sender: NSButton) {
                overlayView?.sessionHideRecordingHUD = (sender.state == .on)
            }
        }
        let hideHUDHandler = HideHUDHandler(overlayView: self)
        hideHUDCheck.target = hideHUDHandler
        hideHUDCheck.action = #selector(HideHUDHandler.changed(_:))
        objc_setAssociatedObject(hideHUDCheck, "handler", hideHUDHandler, .OBJC_ASSOCIATION_RETAIN)

        addRow(label: L("FPS:"), control: fpsPopup)
        addRow(label: L("When done:"), control: whenDonePopup)
        addRow(label: L("Delay:"), control: delayPopup)
        addRow(label: "", control: hideHUDCheck)

        // Webcam settings (only when webcam is enabled)
        if UserDefaults.standard.bool(forKey: "recordWebcam") {
            // Separator
            let sep = NSBox()
            sep.boxType = .separator
            sep.frame = NSRect(x: 10, y: y + 2, width: 220, height: 1)
            container.addSubview(sep)
            y += 10

            // Position
            let posSeg = NSSegmentedControl(labels: ["↙", "↘", "↖", "↗"], trackingMode: .selectOne, target: nil, action: nil)
            let currentPos = UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight"
            switch currentPos {
            case "bottomLeft": posSeg.selectedSegment = 0
            case "bottomRight": posSeg.selectedSegment = 1
            case "topLeft": posSeg.selectedSegment = 2
            case "topRight": posSeg.selectedSegment = 3
            default: posSeg.selectedSegment = 1
            }

            class PosHandler: NSObject {
                weak var overlayView: OverlayView?
                init(overlayView: OverlayView?) { self.overlayView = overlayView; super.init() }
                @objc func changed(_ sender: NSSegmentedControl) {
                    let values = ["bottomLeft", "bottomRight", "topLeft", "topRight"]
                    UserDefaults.standard.set(values[sender.selectedSegment], forKey: "webcamPosition")
                    overlayView?.updateWebcamSetupPreview()
                }
            }
            let posHandler = PosHandler(overlayView: self)
            posSeg.target = posHandler
            posSeg.action = #selector(PosHandler.changed(_:))
            objc_setAssociatedObject(posSeg, "handler", posHandler, .OBJC_ASSOCIATION_RETAIN)

            // Size
            let sizeSeg = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne, target: nil, action: nil)
            let currentSize = UserDefaults.standard.string(forKey: "webcamSize") ?? "medium"
            switch currentSize {
            case "small": sizeSeg.selectedSegment = 0
            case "medium": sizeSeg.selectedSegment = 1
            case "large": sizeSeg.selectedSegment = 2
            default: sizeSeg.selectedSegment = 1
            }

            class SizeHandler: NSObject {
                weak var overlayView: OverlayView?
                init(overlayView: OverlayView?) { self.overlayView = overlayView; super.init() }
                @objc func changed(_ sender: NSSegmentedControl) {
                    let values = ["small", "medium", "large"]
                    UserDefaults.standard.set(values[sender.selectedSegment], forKey: "webcamSize")
                    overlayView?.updateWebcamSetupPreview()
                }
            }
            let sizeHandler = SizeHandler(overlayView: self)
            sizeSeg.target = sizeHandler
            sizeSeg.action = #selector(SizeHandler.changed(_:))
            objc_setAssociatedObject(sizeSeg, "handler", sizeHandler, .OBJC_ASSOCIATION_RETAIN)

            // Shape
            let shapeSeg = NSSegmentedControl(labels: ["●", "▢"], trackingMode: .selectOne, target: nil, action: nil)
            let currentShape = UserDefaults.standard.string(forKey: "webcamShape") ?? "circle"
            shapeSeg.selectedSegment = currentShape == "roundedRect" ? 1 : 0

            class ShapeHandler: NSObject {
                weak var overlayView: OverlayView?
                init(overlayView: OverlayView?) { self.overlayView = overlayView; super.init() }
                @objc func changed(_ sender: NSSegmentedControl) {
                    let values = ["circle", "roundedRect"]
                    UserDefaults.standard.set(values[sender.selectedSegment], forKey: "webcamShape")
                    overlayView?.updateWebcamSetupPreview()
                }
            }
            let shapeHandler = ShapeHandler(overlayView: self)
            shapeSeg.target = shapeHandler
            shapeSeg.action = #selector(ShapeHandler.changed(_:))
            objc_setAssociatedObject(shapeSeg, "handler", shapeHandler, .OBJC_ASSOCIATION_RETAIN)

            addRow(label: L("Cam pos:"), control: posSeg)
            addRow(label: L("Cam size:"), control: sizeSeg)
            addRow(label: L("Cam shape:"), control: shapeSeg)
        }

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
        let sourceImg = tool == .pixelate ? screenshotImage : nil
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
        let sourceImg = tool == .pixelate ? screenshotImage : nil
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
        let sourceImg = tool == .pixelate ? screenshotImage : nil
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
        let sourceImg = tool == .pixelate ? screenshotImage : nil
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
