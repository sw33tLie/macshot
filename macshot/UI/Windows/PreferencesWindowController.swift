import Cocoa
import Carbon
import ServiceManagement

/// Preferences window that intercepts Cmd+Q to close itself instead of quitting the app.
private class PreferencesWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

class PreferencesWindowController: NSWindowController, NSTabViewDelegate, NSWindowDelegate {

    private var hotkeyFields: [HotkeyManager.HotkeySlot: NSTextField] = [:]
    private var hotkeyButtons: [HotkeyManager.HotkeySlot: NSButton] = [:]
    private var recordingSlot: HotkeyManager.HotkeySlot?
    private var savePathField: NSTextField!
    private var autoCopyOCRCheckbox: NSButton!
    private var copySoundCheckbox: NSButton!
    private var rememberSelectionCheckbox: NSButton!
    private var rememberToolCheckbox: NSButton!
    private var thumbnailCheckbox: NSButton!
    private var thumbnailAutoDismissStepper: NSStepper!
    private var thumbnailAutoDismissField: NSTextField!
    private var thumbnailStackingPopup: NSPopUpButton!
    private var launchAtLoginCheckbox: NSButton!
    private var hideMenuBarIconCheckbox: NSButton!
    private var historySizeField: NSTextField!
    private var historySizeStepper: NSStepper!
    private var snapGuidesCheckbox: NSButton!
    private var captureCursorCheckbox: NSButton!
    private var windowTitleCheckbox: NSButton!
    private var quickModePopup: NSPopUpButton!
    private var imageFormatPopup: NSPopUpButton!
    private var qualitySlider: NSSlider!
    private var qualityLabel: NSTextField!
    private var qualityRowLabel: NSTextField!
    private var downscaleRetinaCheckbox: NSButton!
    private var embedColorProfileCheckbox: NSButton!
    private var imgbbKeyField: NSTextField!
    private var localMonitor: Any?
    private weak var uploadsStack: NSStackView?
    private var providerPopup: NSPopUpButton!
    private var gdriveSignInBtn: NSButton!
    private var gdriveStatusLabel: NSTextField!
    // S3 tab controls
    private var s3EndpointField: NSTextField!
    private var s3RegionField: NSTextField!
    private var s3BucketField: NSTextField!
    private var s3AccessKeyField: NSTextField!
    private var s3SecretKeyField: NSSecureTextField!
    private var s3PublicURLField: NSTextField!
    private var s3PathPrefixField: NSTextField!
    private var s3TestBtn: NSButton!
    private var s3StatusLabel: NSTextField!
    // Recording tab controls
    private var recordingFormatPopup: NSPopUpButton!
    private var recordingFPSPopup: NSPopUpButton!
    private var recordingOnStopPopup: NSPopUpButton!
    private var recSavePathField: NSTextField!
    // Scroll capture controls
    private var scrollAutoScrollCheckbox: NSButton!
    private var scrollSpeedPopup: NSPopUpButton!
    private var scrollMaxHeightField: NSTextField!
    private var scrollMaxHeightStepper: NSStepper!
    private var scrollFrozenDetectionCheckbox: NSButton!

    var onHotkeyChanged: (() -> Void)?

    init() {
        let window = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macshot Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        setupUI()
        loadPreferences()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Top-level layout

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        // Logo
        let logo = NSImageView()
        logo.image = NSImage(named: "Logo")
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false

        // Tab view
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "General"
        generalTab.view = makeGeneralTabView()
        tabView.addTabViewItem(generalTab)

        let shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        shortcutsTab.label = "Shortcuts"
        shortcutsTab.view = makeShortcutsTabView()
        tabView.addTabViewItem(shortcutsTab)

        let toolsTab = NSTabViewItem(identifier: "tools")
        toolsTab.label = "Tools"
        toolsTab.view = makeToolsTabView()
        tabView.addTabViewItem(toolsTab)

        let recordingTab = NSTabViewItem(identifier: "recording")
        recordingTab.label = "Recording"
        recordingTab.view = makeRecordingTabView()
        tabView.addTabViewItem(recordingTab)

        let uploadsTab = NSTabViewItem(identifier: "uploads")
        uploadsTab.label = "Uploads"
        uploadsTab.view = makeUploadsTabView()
        tabView.addTabViewItem(uploadsTab)

        let aboutTab = NSTabViewItem(identifier: "about")
        aboutTab.label = "About"
        aboutTab.view = makeAboutTabView()
        tabView.addTabViewItem(aboutTab)

        // Footer separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // Footer labels
        let madeBy = NSTextField(labelWithString: "Made by sw33tLie")
        madeBy.font = NSFont.systemFont(ofSize: 11)
        madeBy.textColor = .secondaryLabelColor
        madeBy.translatesAutoresizingMaskIntoConstraints = false

        let linkBtn = NSButton(title: "github.com/sw33tLie/macshot", target: self, action: #selector(openGitHub))
        linkBtn.bezelStyle = .inline
        linkBtn.isBordered = false
        linkBtn.font = NSFont.systemFont(ofSize: 11)
        linkBtn.attributedTitle = NSAttributedString(string: "github.com/sw33tLie/macshot", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        linkBtn.translatesAutoresizingMaskIntoConstraints = false

        let footerStack = NSStackView(views: [madeBy, NSView(), linkBtn])
        footerStack.orientation = .horizontal
        footerStack.spacing = 0
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(logo)
        cv.addSubview(tabView)
        cv.addSubview(sep)
        cv.addSubview(footerStack)

        NSLayoutConstraint.activate([
            // Logo centered at top
            logo.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            logo.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            logo.widthAnchor.constraint(equalToConstant: 56),
            logo.heightAnchor.constraint(equalToConstant: 56),

            // Tab view below logo, above footer
            tabView.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: sep.topAnchor, constant: -0),

            // Footer separator
            sep.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            sep.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -6),
            sep.heightAnchor.constraint(equalToConstant: 1),

            // Footer
            footerStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            footerStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            footerStack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
            footerStack.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - General Tab

    private func makeGeneralTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        // ── Capture ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Capture"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Enter key action
        quickModePopup = NSPopUpButton()
        quickModePopup.addItems(withTitles: ["Save to file", "Copy to clipboard", "Save + copy to clipboard"])
        quickModePopup.target = self
        quickModePopup.action = #selector(quickModeChanged(_:))

        stack.addArrangedSubview(labeledRow("Enter / Quick Capture:", controls: [quickModePopup]))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // Checkboxes
        autoCopyOCRCheckbox = NSButton(checkboxWithTitle: "Auto-copy OCR text to clipboard", target: self, action: #selector(autoCopyOCRChanged(_:)))
        copySoundCheckbox = NSButton(checkboxWithTitle: "Play sound on copy", target: self, action: #selector(copySoundChanged(_:)))
        rememberSelectionCheckbox = NSButton(checkboxWithTitle: "Remember last selection area", target: self, action: #selector(rememberSelectionChanged(_:)))
        rememberToolCheckbox = NSButton(checkboxWithTitle: "Remember last selected tool", target: self, action: #selector(rememberToolChanged(_:)))
        thumbnailCheckbox = NSButton(checkboxWithTitle: "Show floating thumbnail after capture", target: self, action: #selector(thumbnailChanged(_:)))
        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(launchAtLoginChanged(_:)))
        snapGuidesCheckbox = NSButton(checkboxWithTitle: "Show snap alignment guides", target: self, action: #selector(snapGuidesChanged(_:)))
        captureCursorCheckbox = NSButton(checkboxWithTitle: "Capture mouse cursor in screenshot", target: self, action: #selector(captureCursorChanged(_:)))
        windowTitleCheckbox = NSButton(checkboxWithTitle: "Use window title in saved filename", target: self, action: #selector(windowTitleChanged(_:)))

        for cb in [autoCopyOCRCheckbox!, copySoundCheckbox!, rememberSelectionCheckbox!, rememberToolCheckbox!, thumbnailCheckbox!] {
            stack.addArrangedSubview(indented(cb))
            stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
        }

        // Thumbnail auto-dismiss stepper
        thumbnailAutoDismissField = NSTextField()
        thumbnailAutoDismissField.isEditable = false
        thumbnailAutoDismissField.isSelectable = false
        thumbnailAutoDismissField.alignment = .center
        thumbnailAutoDismissField.widthAnchor.constraint(equalToConstant: 40).isActive = true

        thumbnailAutoDismissStepper = NSStepper()
        thumbnailAutoDismissStepper.minValue = 0
        thumbnailAutoDismissStepper.maxValue = 60
        thumbnailAutoDismissStepper.increment = 1
        thumbnailAutoDismissStepper.target = self
        thumbnailAutoDismissStepper.action = #selector(thumbnailAutoDismissChanged(_:))

        let dismissNote = NSTextField(labelWithString: "seconds before auto-dismiss (0 = never)")
        dismissNote.font = NSFont.systemFont(ofSize: 11)
        dismissNote.textColor = .secondaryLabelColor

        stack.addArrangedSubview(indented(labeledRow("  Dismiss after:", controls: [thumbnailAutoDismissField!, thumbnailAutoDismissStepper!, dismissNote])))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Thumbnail stacking popup
        thumbnailStackingPopup = NSPopUpButton()
        thumbnailStackingPopup.addItems(withTitles: ["Stack (keep all)", "Replace (show only latest)"])
        thumbnailStackingPopup.target = self
        thumbnailStackingPopup.action = #selector(thumbnailStackingChanged(_:))

        stack.addArrangedSubview(indented(labeledRow("  Multiple previews:", controls: [thumbnailStackingPopup!])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(snapGuidesCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(captureCursorCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(windowTitleCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(launchAtLoginCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        hideMenuBarIconCheckbox = NSButton(checkboxWithTitle: "Hide menu bar icon", target: self, action: #selector(hideMenuBarIconChanged(_:)))
        stack.addArrangedSubview(indented(hideMenuBarIconCheckbox))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let hideNote = NSTextField(wrappingLabelWithString: "Hotkeys still work. To show the icon again, re-launch macshot.")
        hideNote.font = NSFont.systemFont(ofSize: 10)
        hideNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(hideNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Output ───────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Output"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Save folder
        savePathField = NSTextField()
        savePathField.isEditable = false
        savePathField.isSelectable = false
        savePathField.lineBreakMode = .byTruncatingMiddle

        let browseBtn = NSButton(title: "Browse…", target: self, action: #selector(browseSavePath(_:)))
        browseBtn.bezelStyle = .rounded

        stack.addArrangedSubview(labeledRow("Save folder:", controls: [savePathField, browseBtn]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Image format
        imageFormatPopup = NSPopUpButton()
        imageFormatPopup.addItems(withTitles: ["PNG", "JPEG", "HEIC", "WebP"])
        imageFormatPopup.target = self
        imageFormatPopup.action = #selector(imageFormatChanged(_:))

        stack.addArrangedSubview(labeledRow("Image format:", controls: [imageFormatPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Quality (applies to JPEG and HEIC)
        qualitySlider = NSSlider()
        qualitySlider.minValue = 10
        qualitySlider.maxValue = 100
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged(_:))
        qualitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        qualityLabel = NSTextField(labelWithString: "85%")
        qualityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        qualityRowLabel = NSTextField(labelWithString: "Quality:")
        qualityRowLabel.font = NSFont.systemFont(ofSize: 13)
        qualityRowLabel.alignment = .right
        qualityRowLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityRowLabel.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let qualityRow = NSStackView(views: [qualityRowLabel, qualitySlider, qualityLabel])
        qualityRow.orientation = .horizontal
        qualityRow.spacing = 8
        qualityRow.alignment = .centerY
        qualityRow.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(qualityRow)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Downscale Retina
        downscaleRetinaCheckbox = NSButton(checkboxWithTitle: "Save at standard resolution (1x)", target: self, action: #selector(downscaleRetinaChanged(_:)))
        stack.addArrangedSubview(indented(downscaleRetinaCheckbox))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)

        let downscaleNote = NSTextField(labelWithString: "Halves dimensions on Retina displays, ~4x smaller files")
        downscaleNote.font = NSFont.systemFont(ofSize: 10)
        downscaleNote.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(indented(downscaleNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Embed color profile
        embedColorProfileCheckbox = NSButton(checkboxWithTitle: "Embed sRGB color profile", target: self, action: #selector(embedColorProfileChanged(_:)))
        stack.addArrangedSubview(indented(embedColorProfileCheckbox))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)

        let profileNote = NSTextField(labelWithString: "Ensures consistent colors across different displays")
        profileNote.font = NSFont.systemFont(ofSize: 10)
        profileNote.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(indented(profileNote))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // History size
        historySizeField = NSTextField()
        historySizeField.isEditable = false
        historySizeField.isSelectable = false
        historySizeField.alignment = .center
        historySizeField.widthAnchor.constraint(equalToConstant: 40).isActive = true

        historySizeStepper = NSStepper()
        historySizeStepper.minValue = 0
        historySizeStepper.maxValue = 50
        historySizeStepper.increment = 1
        historySizeStepper.target = self
        historySizeStepper.action = #selector(historySizeChanged(_:))

        let histNote = NSTextField(labelWithString: "screenshots kept on disk (0 = off)")
        histNote.font = NSFont.systemFont(ofSize: 11)
        histNote.textColor = .secondaryLabelColor

        stack.addArrangedSubview(labeledRow("History size:", controls: [historySizeField, historySizeStepper, histNote]))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Make stack fill scroll width
        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            // no bottom constraint — stack grows to fit content, scroll handles overflow
        ])

        return scroll
    }

    // MARK: - Shortcuts Tab

    private func makeShortcutsTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        stack.addArrangedSubview(sectionHeader("Keyboard Shortcuts"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        for slot in HotkeyManager.HotkeySlot.allCases {
            let field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            field.stringValue = HotkeyManager.displayString(for: slot)

            let btn = NSButton(title: "Record", target: self, action: #selector(recordShortcut(_:)))
            btn.bezelStyle = .rounded
            btn.tag = slot.rawValue

            let clearBtn = NSButton(title: "", target: self, action: #selector(clearShortcut(_:)))
            clearBtn.bezelStyle = .inline
            clearBtn.isBordered = false
            clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear shortcut")
            clearBtn.contentTintColor = .secondaryLabelColor
            clearBtn.imagePosition = .imageOnly
            clearBtn.tag = slot.rawValue
            clearBtn.toolTip = "Clear shortcut"
            clearBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            hotkeyFields[slot] = field
            hotkeyButtons[slot] = btn

            stack.addArrangedSubview(labeledRow("\(slot.label):", controls: [field, btn, clearBtn]))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }

        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let note = NSTextField(wrappingLabelWithString: "Click \"Record\" and press a key combination with at least one modifier (⌘, ⌥, ⌃, ⇧) to set a shortcut.")
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(note))

        // Spacer to push content to top
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        stack.addArrangedSubview(spacer)

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: clipView.heightAnchor),
        ])

        return scroll
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }

        // If already recording this slot, stop
        if recordingSlot == slot {
            stopShortcutRecording()
            return
        }
        // Stop any previous recording
        stopShortcutRecording()

        recordingSlot = slot
        sender.title = "Press keys..."
        hotkeyFields[slot]?.stringValue = "Waiting..."

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            if carbonMods == 0 { return nil }

            let keyCode = UInt32(event.keyCode)
            HotkeyManager.saveHotkey(for: slot, keyCode: keyCode, modifiers: carbonMods)
            self.hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
            self.stopShortcutRecording()
            self.onHotkeyChanged?()
            return nil
        }
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }
        stopShortcutRecording()
        HotkeyManager.disableHotkey(for: slot)
        hotkeyFields[slot]?.stringValue = "None"
        onHotkeyChanged?()
    }

    private func stopShortcutRecording() {
        if let slot = recordingSlot {
            hotkeyButtons[slot]?.title = "Record"
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }
        recordingSlot = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Tools Tab

    private func makeToolsTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        // ── Annotation Tools ─────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Annotation Tools"))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteA = NSTextField(labelWithString: "Hidden tools are removed from the bottom toolbar.")
        noteA.font = NSFont.systemFont(ofSize: 11)
        noteA.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteA)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let annotationTools: [(AnnotationTool, String)] = [
            (.pencil, "Pencil"), (.line, "Line"), (.arrow, "Arrow"),
            (.rectangle, "Rectangle"),
            (.ellipse, "Ellipse"), (.marker, "Marker"), (.text, "Text"),
            (.number, "Number / Counter"), (.pixelate, "Pixelate"),
            (.blur, "Blur"), (.loupe, "Magnify (Loupe)"), (.stamp, "Stamp / Emoji"), (.colorSampler, "Color Picker"), (.measure, "Measure"),
        ]
        let enabledTools = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]
        let toolsGrid = makeToggleGrid(items: annotationTools.map { (tag: $0.rawValue, label: $1) },
                                       defaultsKey: "enabledTools", enabledValues: enabledTools)
        stack.addArrangedSubview(toolsGrid)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Bottom Toolbar Actions ───────────────────────────
        stack.addArrangedSubview(sectionHeader("Bottom Toolbar Actions"))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteB = NSTextField(labelWithString: "Hidden actions are removed from the bottom toolbar.")
        noteB.font = NSFont.systemFont(ofSize: 11)
        noteB.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteB)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let bottomActionItems: [(tag: Int, label: String)] = [
            (1011, "Invert Colors"),
            (1013, "Adjust (Image Effects)"),
            (1004, "Beautify"),
            (1005, "Remove Background"),
        ]
        let enabledActions = UserDefaults.standard.array(forKey: "enabledActions") as? [Int]
        let bottomActionsGrid = makeToggleGrid(items: bottomActionItems,
                                               defaultsKey: "enabledActions", enabledValues: enabledActions)
        stack.addArrangedSubview(bottomActionsGrid)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Right Toolbar Actions ────────────────────────────
        stack.addArrangedSubview(sectionHeader("Right Toolbar Actions"))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteC = NSTextField(labelWithString: "Hidden actions are removed from the right toolbar.")
        noteC.font = NSFont.systemFont(ofSize: 11)
        noteC.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteC)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let rightActionItems: [(tag: Int, label: String)] = [
            (1001, "Upload"), (1002, "Pin (floating window)"),
            (1003, "OCR (extract text)"), (1006, "Auto-Redact sensitive data"),
            (1008, "Translate"),
            (1009, "Record screen"),
            (1010, "Scroll Capture"),
            (1012, "Share"),
        ]
        let rightActionsGrid = makeToggleGrid(items: rightActionItems,
                                              defaultsKey: "enabledActions", enabledValues: enabledActions)
        stack.addArrangedSubview(rightActionsGrid)

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])

        return scroll
    }

    // MARK: - Recording Tab

    private func makeRecordingTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        // ── Format ────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Output"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        recordingFormatPopup = NSPopUpButton()
        recordingFormatPopup.addItems(withTitles: ["MP4 (H.264)", "GIF"])
        recordingFormatPopup.target = self
        recordingFormatPopup.action = #selector(recordingFormatChanged(_:))
        stack.addArrangedSubview(labeledRow("Format:", controls: [recordingFormatPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        recordingFPSPopup = NSPopUpButton()
        recordingFPSPopup.addItems(withTitles: ["15 fps", "24 fps", "30 fps", "60 fps", "120 fps"])
        recordingFPSPopup.target = self
        recordingFPSPopup.action = #selector(recordingFPSChanged(_:))
        stack.addArrangedSubview(labeledRow("Frame rate:", controls: [recordingFPSPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        recSavePathField = NSTextField()
        recSavePathField.isEditable = false
        recSavePathField.isSelectable = false
        recSavePathField.lineBreakMode = .byTruncatingMiddle

        let recBrowseBtn = NSButton(title: "Browse…", target: self, action: #selector(browseRecSavePath(_:)))
        recBrowseBtn.bezelStyle = .rounded
        let recClearBtn = NSButton(title: "Clear", target: self, action: #selector(clearRecSavePath(_:)))
        recClearBtn.bezelStyle = .rounded

        stack.addArrangedSubview(labeledRow("Save folder:", controls: [recSavePathField, recBrowseBtn, recClearBtn]))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Behavior ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Behavior"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        recordingOnStopPopup = NSPopUpButton()
        recordingOnStopPopup.addItems(withTitles: ["Open editor", "Show in Finder"])
        recordingOnStopPopup.target = self
        recordingOnStopPopup.action = #selector(recordingOnStopChanged(_:))
        stack.addArrangedSubview(labeledRow("When done:", controls: [recordingOnStopPopup]))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Scroll Capture ────────────────────────────────────
        stack.addArrangedSubview(sectionHeader("Scroll Capture"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        scrollAutoScrollCheckbox = NSButton(checkboxWithTitle: "Auto-scroll (sends synthetic scroll events)",
                                            target: self, action: #selector(scrollAutoScrollChanged(_:)))
        stack.addArrangedSubview(scrollAutoScrollCheckbox)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollSpeedPopup = NSPopUpButton()
        scrollSpeedPopup.addItems(withTitles: ["Slow", "Medium", "Fast", "Very fast"])
        scrollSpeedPopup.target = self
        scrollSpeedPopup.action = #selector(scrollSpeedChanged(_:))
        stack.addArrangedSubview(labeledRow("Scroll speed:", controls: [scrollSpeedPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollMaxHeightField = NSTextField()
        scrollMaxHeightField.isEditable = false
        scrollMaxHeightField.isSelectable = false
        scrollMaxHeightField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        scrollMaxHeightField.translatesAutoresizingMaskIntoConstraints = false
        scrollMaxHeightField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        scrollMaxHeightStepper = NSStepper()
        scrollMaxHeightStepper.minValue = 0
        scrollMaxHeightStepper.maxValue = 100000
        scrollMaxHeightStepper.increment = 5000
        scrollMaxHeightStepper.valueWraps = false
        scrollMaxHeightStepper.target = self
        scrollMaxHeightStepper.action = #selector(scrollMaxHeightChanged(_:))

        let maxHeightNote = NSTextField(labelWithString: "px (0 = unlimited)")
        maxHeightNote.font = .systemFont(ofSize: 11)
        maxHeightNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(labeledRow("Max height:", controls: [scrollMaxHeightField, scrollMaxHeightStepper, maxHeightNote]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollFrozenDetectionCheckbox = NSButton(checkboxWithTitle: "Detect fixed/sticky headers",
                                                 target: self, action: #selector(scrollFrozenDetectionChanged(_:)))
        stack.addArrangedSubview(scrollFrozenDetectionCheckbox)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Spacer to absorb remaining height, keeping content pinned to top
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        stack.addArrangedSubview(spacer)

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: clipView.heightAnchor),
        ])

        return scroll
    }

    // MARK: - Uploads Tab

    private func makeUploadsTabView() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 16, right: 20)

        // ── Upload Provider ──
        stack.addArrangedSubview(sectionHeader("Upload Provider"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: ["imgbb (images only)", "Google Drive (images + videos)", "S3-Compatible (images + videos)"])
        let currentProvider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        switch currentProvider {
        case "gdrive": providerPopup.selectItem(at: 1)
        case "s3": providerPopup.selectItem(at: 2)
        default: providerPopup.selectItem(at: 0)
        }
        providerPopup.target = self
        providerPopup.action = #selector(uploadProviderChanged(_:))
        stack.addArrangedSubview(labeledRow("Provider:", controls: [providerPopup]))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── Google Drive ──
        stack.addArrangedSubview(sectionHeader("Google Drive"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        gdriveStatusLabel = NSTextField(labelWithString: "")
        gdriveStatusLabel.font = NSFont.systemFont(ofSize: 11)
        gdriveStatusLabel.textColor = .secondaryLabelColor
        updateGDriveStatus()

        gdriveSignInBtn = NSButton(title: "Sign In with Google", target: self, action: #selector(gdriveSignInTapped(_:)))
        gdriveSignInBtn.bezelStyle = .rounded
        updateGDriveButton()

        stack.addArrangedSubview(labeledRow("Account:", controls: [gdriveStatusLabel]))
        stack.addArrangedSubview(indented(gdriveSignInBtn))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let gdriveNote = NSTextField(wrappingLabelWithString: "Files are uploaded to a \"macshot\" folder in your Google Drive. Everything stays private — nothing is shared publicly.")
        gdriveNote.font = NSFont.systemFont(ofSize: 10)
        gdriveNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(gdriveNote))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── S3-Compatible ──
        stack.addArrangedSubview(sectionHeader("S3-Compatible Storage"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        s3EndpointField = NSTextField()
        s3EndpointField.placeholderString = "https://abc123.r2.cloudflarestorage.com"
        s3EndpointField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3EndpointField.stringValue = UserDefaults.standard.string(forKey: "s3Endpoint") ?? ""
        s3EndpointField.target = self
        s3EndpointField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow("Endpoint:", controls: [s3EndpointField]))

        s3RegionField = NSTextField()
        s3RegionField.placeholderString = "auto"
        s3RegionField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3RegionField.stringValue = UserDefaults.standard.string(forKey: "s3Region") ?? "auto"
        s3RegionField.target = self
        s3RegionField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow("Region:", controls: [s3RegionField]))

        s3BucketField = NSTextField()
        s3BucketField.placeholderString = "my-bucket"
        s3BucketField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3BucketField.stringValue = UserDefaults.standard.string(forKey: "s3Bucket") ?? ""
        s3BucketField.target = self
        s3BucketField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow("Bucket:", controls: [s3BucketField]))

        s3AccessKeyField = NSTextField()
        s3AccessKeyField.placeholderString = "AKIAIOSFODNN7EXAMPLE"
        s3AccessKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3AccessKeyField.stringValue = UserDefaults.standard.string(forKey: "s3AccessKeyID") ?? ""
        s3AccessKeyField.target = self
        s3AccessKeyField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow("Access Key:", controls: [s3AccessKeyField]))

        s3SecretKeyField = NSSecureTextField()
        s3SecretKeyField.placeholderString = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        s3SecretKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3SecretKeyField.stringValue = UserDefaults.standard.string(forKey: "s3SecretAccessKey") ?? ""
        s3SecretKeyField.target = self
        s3SecretKeyField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow("Secret Key:", controls: [s3SecretKeyField]))

        s3PublicURLField = NSTextField()
        s3PublicURLField.placeholderString = "https://cdn.example.com"
        s3PublicURLField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3PublicURLField.stringValue = UserDefaults.standard.string(forKey: "s3PublicURLBase") ?? ""
        s3PublicURLField.target = self
        s3PublicURLField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow("Public URL:", controls: [s3PublicURLField]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let publicURLNote = NSTextField(wrappingLabelWithString: "Base URL for public access. If empty, the S3 endpoint URL is used (may not be publicly accessible).")
        publicURLNote.font = NSFont.systemFont(ofSize: 10)
        publicURLNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(publicURLNote))

        s3PathPrefixField = NSTextField()
        s3PathPrefixField.placeholderString = "screenshots/"
        s3PathPrefixField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3PathPrefixField.stringValue = UserDefaults.standard.string(forKey: "s3PathPrefix") ?? ""
        s3PathPrefixField.target = self
        s3PathPrefixField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow("Path Prefix:", controls: [s3PathPrefixField]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        s3TestBtn = NSButton(title: "Test Connection", target: self, action: #selector(s3TestTapped(_:)))
        s3TestBtn.bezelStyle = .rounded

        s3StatusLabel = NSTextField(labelWithString: "")
        s3StatusLabel.font = NSFont.systemFont(ofSize: 11)
        s3StatusLabel.textColor = .secondaryLabelColor
        s3StatusLabel.lineBreakMode = .byTruncatingTail

        let testRow = NSStackView(views: [s3TestBtn, s3StatusLabel])
        testRow.orientation = .horizontal
        testRow.spacing = 8
        stack.addArrangedSubview(indented(testRow))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let s3Note = NSTextField(wrappingLabelWithString: "Works with AWS S3, Cloudflare R2, MinIO, DigitalOcean Spaces, Backblaze B2, and other S3-compatible services. Supports images and videos.")
        s3Note.font = NSFont.systemFont(ofSize: 10)
        s3Note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(s3Note))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── imgbb ──
        stack.addArrangedSubview(sectionHeader("imgbb"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        imgbbKeyField = NSTextField()
        imgbbKeyField.placeholderString = "Leave empty to use default"
        imgbbKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        imgbbKeyField.target = self
        imgbbKeyField.action = #selector(imgbbKeyChanged(_:))
        if let key = UserDefaults.standard.string(forKey: "imgbbAPIKey") {
            imgbbKeyField.stringValue = key
        }

        stack.addArrangedSubview(labeledRow("API key:", controls: [imgbbKeyField]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let imgbbNote = NSTextField(wrappingLabelWithString: "A shared key is included — get your own free key at imgbb.com/api if you hit rate limits. Images only (no video support).")
        imgbbNote.font = NSFont.systemFont(ofSize: 10)
        imgbbNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(imgbbNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Upload History ──
        stack.addArrangedSubview(sectionHeader("Upload History"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Placeholder for upload history rows
        let historyContainer = NSStackView()
        historyContainer.orientation = .vertical
        historyContainer.alignment = .leading
        historyContainer.spacing = 6
        historyContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(historyContainer)
        self.uploadsStack = historyContainer

        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
        ])

        return scroll
    }

    // MARK: - About Tab

    private func makeAboutTabView() -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 30),
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])

        // App icon
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 80).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 80).isActive = true
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(12, after: icon)

        // App name
        let name = NSTextField(labelWithString: "macshot")
        name.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        name.textColor = .labelColor
        stack.addArrangedSubview(name)

        // Version
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)
        stack.setCustomSpacing(20, after: versionLabel)

        // Description
        let desc = NSTextField(wrappingLabelWithString: "A free, open-source screenshot & screen recording tool for macOS.\nFully native — built with Swift and AppKit.")
        desc.font = NSFont.systemFont(ofSize: 13)
        desc.textColor = .labelColor
        desc.alignment = .center
        stack.addArrangedSubview(desc)
        stack.setCustomSpacing(20, after: desc)

        // Author
        let author = NSTextField(labelWithString: "Made by sw33tLie")
        author.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        author.textColor = .secondaryLabelColor
        stack.addArrangedSubview(author)
        stack.setCustomSpacing(6, after: author)

        // GitHub link
        let ghBtn = NSButton(title: "github.com/sw33tLie/macshot", target: self, action: #selector(openGitHub))
        ghBtn.bezelStyle = .inline
        ghBtn.isBordered = false
        ghBtn.attributedTitle = NSAttributedString(string: "github.com/sw33tLie/macshot", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        stack.addArrangedSubview(ghBtn)
        stack.setCustomSpacing(20, after: ghBtn)

        // License
        let license = NSTextField(labelWithString: "Licensed under the GPLv3")
        license.font = NSFont.systemFont(ofSize: 11)
        license.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(license)

        return container
    }

    private func updateGDriveStatus() {
        if GoogleDriveUploader.shared.isSignedIn {
            gdriveStatusLabel?.stringValue = GoogleDriveUploader.shared.userEmail ?? "Signed in"
            gdriveStatusLabel?.textColor = .labelColor
        } else {
            gdriveStatusLabel?.stringValue = "Not signed in"
            gdriveStatusLabel?.textColor = .secondaryLabelColor
        }
    }

    private func updateGDriveButton() {
        if GoogleDriveUploader.shared.isSignedIn {
            gdriveSignInBtn?.title = "Sign Out"
        } else {
            gdriveSignInBtn?.title = "Sign In with Google"
        }
    }

    @objc private func uploadProviderChanged(_ sender: NSPopUpButton) {
        let provider: String
        switch sender.indexOfSelectedItem {
        case 1: provider = "gdrive"
        case 2: provider = "s3"
        default: provider = "imgbb"
        }
        UserDefaults.standard.set(provider, forKey: "uploadProvider")
    }

    @objc private func gdriveSignInTapped(_ sender: NSButton) {
        if GoogleDriveUploader.shared.isSignedIn {
            GoogleDriveUploader.shared.signOut()
            updateGDriveStatus()
            updateGDriveButton()
        } else {
            GoogleDriveUploader.shared.signIn(from: window) { [weak self] success in
                guard let self = self, success else {
                    self?.updateGDriveStatus()
                    self?.updateGDriveButton()
                    return
                }
                self.window?.makeKeyAndOrderFront(nil)
                self.updateGDriveButton()
                // Fetch email then update status label
                GoogleDriveUploader.shared.fetchUserEmail { [weak self] in
                    self?.updateGDriveStatus()
                }
            }
        }
    }

    @objc private func s3FieldChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(s3EndpointField.stringValue, forKey: "s3Endpoint")
        UserDefaults.standard.set(s3RegionField.stringValue, forKey: "s3Region")
        UserDefaults.standard.set(s3BucketField.stringValue, forKey: "s3Bucket")
        UserDefaults.standard.set(s3AccessKeyField.stringValue, forKey: "s3AccessKeyID")
        UserDefaults.standard.set(s3SecretKeyField.stringValue, forKey: "s3SecretAccessKey")
        UserDefaults.standard.set(s3PublicURLField.stringValue, forKey: "s3PublicURLBase")
        UserDefaults.standard.set(s3PathPrefixField.stringValue, forKey: "s3PathPrefix")
    }

    @objc private func s3TestTapped(_ sender: NSButton) {
        // Save current field values first
        s3FieldChanged(s3EndpointField)

        guard S3Uploader.shared.isConfigured else {
            s3StatusLabel.stringValue = "Fill in endpoint, bucket, and credentials first"
            s3StatusLabel.textColor = .systemOrange
            return
        }

        s3TestBtn.isEnabled = false
        s3StatusLabel.stringValue = "Testing..."
        s3StatusLabel.textColor = .secondaryLabelColor

        // Upload a tiny test file
        let testData = Data("macshot connection test".utf8)
        let testKey = ".macshot_test_\(UUID().uuidString.prefix(8)).txt"
        S3Uploader.shared.upload(data: testData, filename: testKey, contentType: "text/plain") { [weak self] result in
            guard let self = self else { return }
            self.s3TestBtn.isEnabled = true
            switch result {
            case .success:
                self.s3StatusLabel.stringValue = "Connection successful!"
                self.s3StatusLabel.textColor = .systemGreen
            case .failure(let error):
                self.s3StatusLabel.stringValue = error.localizedDescription
                self.s3StatusLabel.textColor = .systemRed
            }
        }
    }

    private func reloadUploadsTab() {
        guard let stack = uploadsStack else { return }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }

        let uploads = ((UserDefaults.standard.array(forKey: "imgbbUploads") as? [[String: String]]) ?? [])
            .reversed() as [[String: String]]

        if uploads.isEmpty {
            let lbl = NSTextField(labelWithString: "No uploads yet.")
            lbl.font = NSFont.systemFont(ofSize: 13)
            lbl.textColor = .secondaryLabelColor
            lbl.alignment = .center
            lbl.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(lbl)
        } else {
            for (i, upload) in uploads.enumerated() {
                let row = makeUploadRow(index: uploads.count - i,
                                        link: upload["link"] ?? "",
                                        deleteURL: upload["deleteURL"] ?? "")
                stack.addArrangedSubview(row)
                // stretch row to fill stack width (accounting for edgeInsets 12+12)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
        }
    }

    private func makeUploadRow(index: Int, link: String, deleteURL: String) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        box.addSubview(inner)

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])

        inner.addArrangedSubview(urlRow(tag: "URL", value: link, copyKey: "link::\(link)"))
        inner.addArrangedSubview(urlRow(tag: "DEL", value: deleteURL, copyKey: "link::\(deleteURL)"))

        return box
    }

    private func urlRow(tag: String, value: String, copyKey: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let tagLbl = NSTextField(labelWithString: tag)
        tagLbl.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        tagLbl.textColor = .secondaryLabelColor
        tagLbl.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(labelWithString: value)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textColor = tag == "URL" ? .labelColor : .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let btn = NSButton(title: "Copy", target: self, action: #selector(copyUploadURL(_:)))
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 11)
        btn.identifier = NSUserInterfaceItemIdentifier(copyKey)
        btn.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(tagLbl)
        row.addSubview(field)
        row.addSubview(btn)

        NSLayoutConstraint.activate([
            tagLbl.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            tagLbl.widthAnchor.constraint(equalToConstant: 34),
            tagLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            btn.widthAnchor.constraint(equalToConstant: 52),
            btn.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: tagLbl.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    // MARK: - Layout helpers

    private func sectionHeader(_ text: String) -> NSTextField {
        let lbl = NSTextField(labelWithString: text.uppercased())
        lbl.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        return lbl
    }

    /// A horizontal row: right-aligned label on the left, controls on the right.
    private func labeledRow(_ labelText: String, controls: [NSView]) -> NSView {
        let lbl = NSTextField(labelWithString: labelText)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.alignment = .right
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let row = NSStackView(views: [lbl] + controls)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Indents a view to align with the control column.
    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 148).isActive = true  // 140 label + 8 spacing

        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// Two-column grid of checkboxes in a rounded box, fills parent width.
    private func makeToggleGrid(items: [(tag: Int, label: String)],
                                 defaultsKey: String,
                                 enabledValues: [Int]?) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor

        // Build rows of 2 columns using horizontal stack views inside a vertical stack
        let vStack = NSStackView()
        vStack.orientation = .vertical
        vStack.spacing = 0
        vStack.alignment = .leading
        vStack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(vStack)

        let pad: CGFloat = 8
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: box.topAnchor, constant: pad),
            vStack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad),
            vStack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
            vStack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad),
        ])

        let cols = 2
        let rows = Int(ceil(Double(items.count) / Double(cols)))
        // Fixed column width so all second-column items align vertically
        let colWidth: CGFloat = 200

        for row in 0..<rows {
            let hStack = NSStackView()
            hStack.orientation = .horizontal
            hStack.distribution = .fill
            hStack.spacing = 0
            hStack.translatesAutoresizingMaskIntoConstraints = false
            hStack.heightAnchor.constraint(equalToConstant: 28).isActive = true

            for col in 0..<cols {
                let idx = row * cols + col
                if idx < items.count {
                    let item = items[idx]
                    let isEnabled = enabledValues == nil || enabledValues!.contains(item.tag)
                    let cb = NSButton(checkboxWithTitle: item.label, target: self, action: #selector(toggleItemChanged(_:)))
                    cb.state = isEnabled ? .on : .off
                    cb.tag = item.tag
                    cb.identifier = NSUserInterfaceItemIdentifier(defaultsKey)
                    cb.translatesAutoresizingMaskIntoConstraints = false
                    cb.widthAnchor.constraint(equalToConstant: colWidth).isActive = true
                    hStack.addArrangedSubview(cb)
                } else {
                    let filler = NSView()
                    filler.translatesAutoresizingMaskIntoConstraints = false
                    filler.widthAnchor.constraint(equalToConstant: colWidth).isActive = true
                    hStack.addArrangedSubview(filler)
                }
            }
            vStack.addArrangedSubview(hStack)
        }

        return box
    }

    // MARK: - Load preferences

    private func loadPreferences() {
        // Load shortcut fields
        for slot in HotkeyManager.HotkeySlot.allCases {
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }

        savePathField.stringValue = SaveDirectoryAccess.displayPath

        let autoCopyOCR = UserDefaults.standard.object(forKey: "autoCopyOCRText") as? Bool ?? true
        autoCopyOCRCheckbox.state = autoCopyOCR ? .on : .off

        let copySound = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        copySoundCheckbox.state = copySound ? .on : .off

        rememberSelectionCheckbox.state = UserDefaults.standard.bool(forKey: "rememberLastSelection") ? .on : .off

        let rememberTool = UserDefaults.standard.object(forKey: "rememberLastTool") as? Bool ?? true
        rememberToolCheckbox.state = rememberTool ? .on : .off

        let thumbnail = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        thumbnailCheckbox.state = thumbnail ? .on : .off

        let autoDismiss = UserDefaults.standard.object(forKey: "thumbnailAutoDismiss") as? Int ?? 5
        thumbnailAutoDismissField.integerValue = autoDismiss
        thumbnailAutoDismissStepper.integerValue = autoDismiss

        let stacking = UserDefaults.standard.object(forKey: "thumbnailStacking") as? Bool ?? true
        thumbnailStackingPopup.selectItem(at: stacking ? 0 : 1)

        let launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        launchAtLoginCheckbox.state = launchAtLogin ? .on : .off

        hideMenuBarIconCheckbox.state = UserDefaults.standard.bool(forKey: "hideMenuBarIcon") ? .on : .off

        let snapGuides = UserDefaults.standard.object(forKey: "snapGuidesEnabled") as? Bool ?? true
        snapGuidesCheckbox.state = snapGuides ? .on : .off

        captureCursorCheckbox.state = UserDefaults.standard.bool(forKey: "captureCursor") ? .on : .off
        windowTitleCheckbox.state = UserDefaults.standard.bool(forKey: "useWindowTitleInFilename") ? .on : .off

        let historySize = UserDefaults.standard.object(forKey: "historySize") as? Int ?? 10
        historySizeField.integerValue = historySize
        historySizeStepper.integerValue = historySize

        // Migrate old bool setting to new int: 0=save, 1=copy, 2=both
        if let oldBool = UserDefaults.standard.object(forKey: "quickModeCopyToClipboard") as? Bool {
            let mode = oldBool ? 1 : 0
            // If old autoCopy was on + save mode, migrate to "both"
            let hadAutoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
            let migratedMode = (!oldBool && hadAutoCopy) ? 2 : mode
            UserDefaults.standard.set(migratedMode, forKey: "quickCaptureMode")
            UserDefaults.standard.removeObject(forKey: "quickModeCopyToClipboard")
            UserDefaults.standard.removeObject(forKey: "autoCopyToClipboard")
        }
        let quickMode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1
        quickModePopup.selectItem(at: quickMode)

        let format = ImageEncoder.format
        switch format {
        case .png:  imageFormatPopup.selectItem(at: 0)
        case .jpeg: imageFormatPopup.selectItem(at: 1)
        case .heic: imageFormatPopup.selectItem(at: 2)
        case .webp: imageFormatPopup.selectItem(at: 3)
        }

        let quality = Int(ImageEncoder.quality * 100)
        qualitySlider.integerValue = quality
        qualityLabel.stringValue = "\(quality)%"

        downscaleRetinaCheckbox.state = ImageEncoder.downscaleRetina ? .on : .off
        embedColorProfileCheckbox.state = ImageEncoder.embedColorProfile ? .on : .off

        updateQualityVisibility()

        imgbbKeyField.stringValue = UserDefaults.standard.string(forKey: "imgbbAPIKey") ?? ""

        // Recording
        let recFormat = UserDefaults.standard.string(forKey: "recordingFormat") ?? "mp4"
        recordingFormatPopup.selectItem(at: recFormat == "gif" ? 1 : 0)
        updateFPSForFormat()

        let onStop = UserDefaults.standard.string(forKey: "recordingOnStop") ?? "editor"
        recordingOnStopPopup.selectItem(at: onStop == "finder" ? 1 : 0)

        recSavePathField.stringValue = SaveDirectoryAccess.recordingDisplayPath

        // Scroll Capture
        let autoScroll = UserDefaults.standard.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        scrollAutoScrollCheckbox.state = autoScroll ? .on : .off
        let speed = UserDefaults.standard.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        scrollSpeedPopup.selectItem(at: max(0, min(3, speed - 1)))
        scrollSpeedPopup.isEnabled = autoScroll
        let maxH = UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? 20000
        scrollMaxHeightField.integerValue = maxH
        scrollMaxHeightStepper.integerValue = maxH
        let frozenDetect = UserDefaults.standard.object(forKey: "scrollFrozenDetection") as? Bool ?? true
        scrollFrozenDetectionCheckbox.state = frozenDetect ? .on : .off
    }

    private func updateQualityVisibility() {
        let hasQuality = imageFormatPopup.indexOfSelectedItem >= 1  // JPEG or HEIC
        qualitySlider.isEnabled = hasQuality
        qualityLabel.textColor = hasQuality ? .labelColor : .tertiaryLabelColor
        qualityRowLabel.textColor = hasQuality ? .labelColor : .tertiaryLabelColor
    }

    // MARK: - Actions

    @objc private func browseSavePath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            SaveDirectoryAccess.save(url: url)
            self?.savePathField.stringValue = url.path
        }
    }

    @objc private func autoCopyOCRChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "autoCopyOCRText")
    }
    @objc private func copySoundChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "playCopySound")
    }
    @objc private func rememberSelectionChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "rememberLastSelection")
    }
    @objc private func rememberToolChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "rememberLastTool")
    }
    @objc private func thumbnailChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showFloatingThumbnail")
    }
    @objc private func thumbnailAutoDismissChanged(_ sender: NSStepper) {
        thumbnailAutoDismissField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "thumbnailAutoDismiss")
    }
    @objc private func thumbnailStackingChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 0, forKey: "thumbnailStacking")
    }
    @objc private func quickModeChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "quickCaptureMode")
    }
    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/sw33tLie/macshot") { NSWorkspace.shared.open(url) }
    }
    @objc private func imageFormatChanged(_ sender: NSPopUpButton) {
        let formats = ["png", "jpeg", "heic", "webp"]
        UserDefaults.standard.set(formats[sender.indexOfSelectedItem], forKey: "imageFormat")
        updateQualityVisibility()
    }
    @objc private func qualityChanged(_ sender: NSSlider) {
        qualityLabel.stringValue = "\(sender.integerValue)%"
        UserDefaults.standard.set(Double(sender.integerValue) / 100.0, forKey: "imageQuality")
    }
    @objc private func downscaleRetinaChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "downscaleRetina")
    }
    @objc private func embedColorProfileChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "embedColorProfile")
    }
    @objc private func imgbbKeyChanged(_ sender: NSTextField) {
        let key = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { UserDefaults.standard.removeObject(forKey: "imgbbAPIKey") }
        else { UserDefaults.standard.set(key, forKey: "imgbbAPIKey") }
    }
    @objc private func historySizeChanged(_ sender: NSStepper) {
        historySizeField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "historySize")
        ScreenshotHistory.shared.pruneToMax()
    }
    @objc private func recordingFormatChanged(_ sender: NSPopUpButton) {
        let isGIF = sender.indexOfSelectedItem == 1
        UserDefaults.standard.set(isGIF ? "gif" : "mp4", forKey: "recordingFormat")
        updateFPSForFormat()
    }
    @objc private func recordingFPSChanged(_ sender: NSPopUpButton) {
        let isGIF = (UserDefaults.standard.string(forKey: "recordingFormat") ?? "mp4") == "gif"
        let fpsOptions = isGIF ? [5, 10, 15] : [15, 24, 30, 60, 120]
        let fps = fpsOptions[min(sender.indexOfSelectedItem, fpsOptions.count - 1)]
        UserDefaults.standard.set(fps, forKey: "recordingFPS")
    }
    private func updateFPSForFormat() {
        let isGIF = (UserDefaults.standard.string(forKey: "recordingFormat") ?? "mp4") == "gif"
        let currentFPS = UserDefaults.standard.integer(forKey: "recordingFPS")
        recordingFPSPopup.removeAllItems()
        if isGIF {
            recordingFPSPopup.addItems(withTitles: ["5 fps", "10 fps", "15 fps"])
            let gifOptions = [5, 10, 15]
            let cappedFPS = min(currentFPS > 0 ? currentFPS : 15, 15)
            let idx = gifOptions.firstIndex(of: cappedFPS) ?? 2
            recordingFPSPopup.selectItem(at: idx)
            UserDefaults.standard.set(gifOptions[idx], forKey: "recordingFPS")
        } else {
            recordingFPSPopup.addItems(withTitles: ["15 fps", "24 fps", "30 fps", "60 fps", "120 fps"])
            let mp4Options = [15, 24, 30, 60, 120]
            let idx = mp4Options.firstIndex(of: currentFPS) ?? 2
            recordingFPSPopup.selectItem(at: idx)
        }
    }
    @objc private func recordingOnStopChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1 ? "finder" : "editor", forKey: "recordingOnStop")
    }
    @objc private func browseRecSavePath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            SaveDirectoryAccess.saveRecordingDirectory(url: url)
            self?.recSavePathField.stringValue = url.path
        }
    }
    @objc private func clearRecSavePath(_ sender: NSButton) {
        SaveDirectoryAccess.clearRecordingDirectory()
        recSavePathField.stringValue = SaveDirectoryAccess.recordingDisplayPath
    }
    // MARK: - Scroll Capture actions
    @objc private func scrollAutoScrollChanged(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "scrollAutoScrollEnabled")
        scrollSpeedPopup.isEnabled = on
    }
    @objc private func scrollSpeedChanged(_ sender: NSPopUpButton) {
        // 0=Slow(1), 1=Medium(2), 2=Fast(3), 3=VeryFast(4)
        UserDefaults.standard.set(sender.indexOfSelectedItem + 1, forKey: "scrollAutoScrollSpeed")
    }
    @objc private func scrollMaxHeightChanged(_ sender: NSStepper) {
        scrollMaxHeightField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "scrollMaxHeight")
    }
    @objc private func scrollFrozenDetectionChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "scrollFrozenDetection")
    }
    @objc private func toggleItemChanged(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? "enabledTools"
        let allTools: [AnnotationTool] = [.pencil, .line, .arrow, .rectangle,
                                          .ellipse, .marker, .text, .number, .pixelate, .blur, .loupe, .stamp, .measure]
        let allActions: [Int] = [1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010]
        let defaultValues: [Int] = key == "enabledTools" ? allTools.map { $0.rawValue } : allActions
        var enabled = UserDefaults.standard.array(forKey: key) as? [Int] ?? defaultValues
        if sender.state == .on { if !enabled.contains(sender.tag) { enabled.append(sender.tag) } }
        else { enabled.removeAll { $0 == sender.tag } }
        UserDefaults.standard.set(enabled, forKey: key)
    }
    @objc private func copyUploadURL(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("link::") else { return }
        let url = String(id.dropFirst(6))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        let orig = sender.title
        sender.title = "✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { sender.title = orig }
    }
    @objc private func snapGuidesChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "snapGuidesEnabled")
    }
    @objc private func captureCursorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "captureCursor")
    }
    @objc private func windowTitleChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "useWindowTitleInFilename")
    }
    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                #if DEBUG
                print("Failed to update login item: \(error)")
                #endif
            }
        }
    }

    @objc private func hideMenuBarIconChanged(_ sender: NSButton) {
        let hidden = sender.state == .on
        UserDefaults.standard.set(hidden, forKey: "hideMenuBarIcon")
        (NSApp.delegate as? AppDelegate)?.setMenuBarIconVisible(!hidden)
    }

    // MARK: - NSTabViewDelegate

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        if tabViewItem?.identifier as? String == "uploads" {
            reloadUploadsTab()
        }
    }

    func showWindow() {
        loadPreferences()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Revert to accessory (no dock icon) if no other titled windows are open
        let hasOtherWindows = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if !hasOtherWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
