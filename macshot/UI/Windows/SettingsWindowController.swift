import Cocoa
import Carbon
import ServiceManagement
import ScreenCaptureKit

/// Settings window that intercepts Cmd+Q to close itself instead of quitting the app.
private class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.keyCode == 12 {  // Q
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {

    // MARK: - Toolbar tab definitions
    private struct TabDef {
        let id: String
        let label: String
        let symbolName: String
        let legacyImageName: String  // fallback for older macOS if needed
    }
    private static let tabDefs: [TabDef] = [
        TabDef(id: "general",   label: "General",   symbolName: "gearshape",                 legacyImageName: NSImage.preferencesGeneralName),
        TabDef(id: "capture",   label: "Capture",   symbolName: "camera.viewfinder",         legacyImageName: NSImage.preferencesGeneralName),
        TabDef(id: "shortcuts", label: "Shortcuts", symbolName: "keyboard",                  legacyImageName: NSImage.preferencesGeneralName),
        TabDef(id: "tools",     label: "Tools",     symbolName: "paintbrush",                legacyImageName: NSImage.preferencesGeneralName),
        TabDef(id: "recording", label: "Recording", symbolName: "record.circle",             legacyImageName: NSImage.preferencesGeneralName),
        TabDef(id: "uploads",   label: "Uploads",   symbolName: "icloud.and.arrow.up",       legacyImageName: NSImage.preferencesGeneralName),
        TabDef(id: "about",     label: "About",     symbolName: "info.circle",               legacyImageName: NSImage.preferencesGeneralName),
    ]

    private var tabContentContainer: NSView!
    private var tabContentViews: [String: NSView] = [:]
    private var currentTabID: String = "general"


    private var hotkeyFields: [HotkeyManager.HotkeySlot: NSTextField] = [:]
    private var hotkeyButtons: [HotkeyManager.HotkeySlot: NSButton] = [:]
    private var recordingSlot: HotkeyManager.HotkeySlot?
    private var toolShortcutFields: [ToolShortcutManager.Action: NSTextField] = [:]
    private var toolShortcutButtons: [ToolShortcutManager.Action: NSButton] = [:]
    private var recordingToolAction: ToolShortcutManager.Action?
    private var savePathField: NSTextField!
    private var ocrActionPopup: NSPopUpButton!
    private var copySoundCheckbox: NSButton!
    // rememberSelectionCheckbox removed — selection is always saved for "Capture Last Area"
    private var rememberToolCheckbox: NSButton!
    private var thumbnailCheckbox: NSButton!
    private var thumbnailAutoDismissStepper: NSStepper!
    private var thumbnailAutoDismissField: NSTextField!
    private var thumbnailStackingPopup: NSPopUpButton!
    private var historyUnlimitedCheckbox: NSButton!
    private var thumbnailScaleLabel: NSTextField!
    private var launchAtLoginCheckbox: NSButton!
    private var hideMenuBarIconCheckbox: NSButton!
    private var historySizeField: NSTextField!
    private var historySizeStepper: NSStepper!
    private var snapGuidesCheckbox: NSButton!
    private var captureCursorCheckbox: NSButton!
    private var windowTitleCheckbox: NSButton!
    private var autoUpdateCheckbox: NSButton!
    private var betaUpdateCheckbox: NSButton!
    private var accentColorWell: NSColorWell!
    private var iconColorWell: NSColorWell!
    private var bgColorWell: NSColorWell!
    private var themePresetPopup: NSPopUpButton!
    private var quickModePopup: NSPopUpButton!
    private var quickCaptureOpenEditorCheckbox: NSButton!
    private var imageFormatPopup: NSPopUpButton!
    private var qualitySlider: NSSlider!
    private var qualityLabel: NSTextField!
    private var qualityRowLabel: NSTextField!
    private var downscaleRetinaCheckbox: NSButton!
    // embedColorProfileCheckbox removed — native color profile is always embedded
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
    private var recordingFPSPopup: NSPopUpButton!
    private var recordingOnStopPopup: NSPopUpButton!
    private var recSavePathField: NSTextField!
    // Webcam controls
    private var webcamPositionPopup: NSPopUpButton!
    private var webcamSizePopup: NSPopUpButton!
    private var webcamShapePopup: NSPopUpButton!
    // Scroll capture controls
    private var scrollAutoScrollCheckbox: NSButton!
    private var scrollSpeedPopup: NSPopUpButton!
    private var scrollMaxHeightField: NSTextField!
    private var scrollMaxHeightStepper: NSStepper!
    private var scrollFrozenDetectionCheckbox: NSButton!
    private var languagePopup: NSPopUpButton!

    var onHotkeyChanged: (() -> Void)?

    init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("macshot Settings")
        window.center()
        window.isReleasedWhenClosed = false
        // Window is non-resizable (no .resizable in styleMask), so content size
        // is locked. We also set the content size explicitly after the toolbar
        // is installed (in setupUI) to override NSToolbar's auto-sizing.
        super.init(window: window)
        window.delegate = self
        setupUI()
        loadSettings()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Top-level layout

    private func setupUI() {
        guard let window = window, let cv = window.contentView else { return }

        // Toolbar (preference style — icon + label, Shottr-like)
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier("general")
        // Re-apply content size after toolbar install, since NSToolbar can
        // resize the window to fit its items.
        window.setContentSize(NSSize(width: 560, height: 520))

        // Build all tab content views up front (preserves existing behavior — nothing lazy-created)
        tabContentViews["general"]   = makeGeneralTabView()
        tabContentViews["capture"]   = makeCaptureTabView()
        tabContentViews["shortcuts"] = makeShortcutsTabView()
        tabContentViews["tools"]     = makeToolsTabView()
        tabContentViews["recording"] = makeRecordingTabView()
        tabContentViews["uploads"]   = makeUploadsTabView()
        tabContentViews["about"]     = makeAboutTabView()

        // Container that swaps content views
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        tabContentContainer = container

        // Footer separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        // Footer labels
        let madeBy = NSTextField(labelWithString: "\(L("Made by")) sw33tLie")
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

        cv.addSubview(container)
        cv.addSubview(sep)
        cv.addSubview(footerStack)

        NSLayoutConstraint.activate([
            // Content container fills above the footer
            container.topAnchor.constraint(equalTo: cv.topAnchor),
            container.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: sep.topAnchor),

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

        // Show initial tab
        showTab(id: "general")
    }

    private func showTab(id: String) {
        guard let container = tabContentContainer, let view = tabContentViews[id] else { return }
        // Remove existing content
        for sub in container.subviews { sub.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        currentTabID = id
        window?.title = "\(L("macshot Settings")) — \(L(Self.tabDefs.first(where: { $0.id == id })?.label ?? ""))"
        if id == "uploads" {
            reloadUploadsTab()
        }
    }

    @objc private func toolbarTabSelected(_ sender: NSToolbarItem) {
        showTab(id: sender.itemIdentifier.rawValue)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return Self.tabDefs.map { NSToolbarItem.Identifier($0.id) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let def = Self.tabDefs.first(where: { $0.id == itemIdentifier.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = L(def.label)
        item.paletteLabel = L(def.label)
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: def.symbolName, accessibilityDescription: def.label)
        } else {
            item.image = NSImage(named: def.legacyImageName)
        }
        item.target = self
        item.action = #selector(toolbarTabSelected(_:))
        return item
    }

    // MARK: - General Tab

    /// NSStackView subclass with flipped coordinates so content pins to the top
    /// of its scroll view (default AppKit origin is bottom-left, which would
    /// push short content to the bottom of a tall clip view).
    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    /// Small SF Symbol icon that reports hover enter/exit via callback. Used for
    /// hover-to-show info popovers next to settings controls.
    fileprivate final class HoverPopoverIconView: NSImageView {
        /// Called with (the view, true) on hover enter and (view, false) on exit.
        var onHover: ((NSView, Bool) -> Void)?
        private var trackingArea: NSTrackingArea?

        init(image: NSImage?, tintColor: NSColor, toolTip: String?) {
            super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            self.image = image
            self.contentTintColor = tintColor
            self.toolTip = toolTip
            self.imageScaling = .scaleProportionallyDown
            self.translatesAutoresizingMaskIntoConstraints = false
            self.widthAnchor.constraint(equalToConstant: 16).isActive = true
            self.heightAnchor.constraint(equalToConstant: 16).isActive = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(self, true) }
        override func mouseExited(with event: NSEvent)  { onHover?(self, false) }
    }

    /// Creates a scrollable vertical stack matching the layout used by all settings tabs.
    private func makeSettingsScrollStack() -> (NSScrollView, NSStackView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        return (scroll, stack)
    }

    /// Finalizes a settings tab by wiring the stack into the scroll view.
    private func finalizeSettingsStack(scroll: NSScrollView, stack: NSStackView) {
        let clipView = scroll.contentView
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clipView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            // no bottom constraint — stack grows to fit content, scroll handles overflow
        ])
    }

    private func makeGeneralTabView() -> NSView {
        let (scroll, stack) = makeSettingsScrollStack()

        // ── Language ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Language")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        languagePopup = NSPopUpButton()
        for lang in LanguageManager.availableLanguages {
            languagePopup.addItem(withTitle: lang.name)
        }
        let currentLang = LanguageManager.shared.currentLanguage
        if let idx = LanguageManager.availableLanguages.firstIndex(where: { $0.code == currentLang }) {
            languagePopup.selectItem(at: idx)
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Language:"), controls: [languagePopup]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let langNote = NSTextField(wrappingLabelWithString: L("Restart the app to fully apply the new language."))
        langNote.font = NSFont.systemFont(ofSize: 10)
        langNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(langNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Application ──────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Application")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: L("Launch at login"), target: self, action: #selector(launchAtLoginChanged(_:)))
        stack.addArrangedSubview(indented(launchAtLoginCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        hideMenuBarIconCheckbox = NSButton(checkboxWithTitle: L("Hide menu bar icon"), target: self, action: #selector(hideMenuBarIconChanged(_:)))
        stack.addArrangedSubview(indented(hideMenuBarIconCheckbox))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let hideNote = NSTextField(wrappingLabelWithString: L("Hotkeys still work. To show the icon again, re-launch macshot."))
        hideNote.font = NSFont.systemFont(ofSize: 10)
        hideNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(hideNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        let urlSchemeCheckbox = NSButton(checkboxWithTitle: "Enable macshot:// URL scheme", target: self, action: #selector(urlSchemeChanged(_:)))
        urlSchemeCheckbox.state = (UserDefaults.standard.object(forKey: "urlSchemeEnabled") as? Bool ?? true) ? .on : .off

        let urlSchemeInfoIcon = HoverPopoverIconView(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("URL scheme info")),
            tintColor: .secondaryLabelColor,
            toolTip: L("Show supported URL scheme commands")
        )
        urlSchemeInfoIcon.onHover = { [weak self] sourceView, shown in
            if shown { self?.showURLSchemeInfoPopover(near: sourceView) }
            // On exit, do nothing — the popover is .transient, so clicking
            // anywhere outside it closes it. This lets the user move into the
            // popover to read/copy without it vanishing.
        }

        let urlSchemeRow = NSStackView(views: [urlSchemeCheckbox, urlSchemeInfoIcon])
        urlSchemeRow.orientation = .horizontal
        urlSchemeRow.spacing = 4
        urlSchemeRow.alignment = .centerY
        stack.addArrangedSubview(indented(urlSchemeRow))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        autoUpdateCheckbox = NSButton(checkboxWithTitle: L("Check for updates automatically"), target: self, action: #selector(autoUpdateChanged(_:)))
        stack.addArrangedSubview(indented(autoUpdateCheckbox))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        betaUpdateCheckbox = NSButton(checkboxWithTitle: L("Check for beta updates"), target: self, action: #selector(betaUpdateChanged(_:)))
        stack.addArrangedSubview(indented(betaUpdateCheckbox))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Appearance ───────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Appearance")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Theme preset dropdown
        themePresetPopup = NSPopUpButton()
        for preset in ThemePreset.all {
            themePresetPopup.addItem(withTitle: L(preset.name))
        }
        themePresetPopup.addItem(withTitle: L("Custom"))
        themePresetPopup.target = self
        themePresetPopup.action = #selector(themePresetChanged(_:))
        stack.addArrangedSubview(indented(labeledRow(L("Theme:"), controls: [themePresetPopup])))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // Three color wells in a single row with labels underneath
        accentColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        accentColorWell.color = ToolbarLayout.accentColor
        accentColorWell.target = self
        accentColorWell.action = #selector(accentColorChanged(_:))

        iconColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        iconColorWell.color = ToolbarLayout.iconColor
        iconColorWell.target = self
        iconColorWell.action = #selector(iconColorChanged(_:))

        bgColorWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 32))
        bgColorWell.color = ToolbarLayout.bgColor
        bgColorWell.target = self
        bgColorWell.action = #selector(bgColorChanged(_:))

        let accentCol = makeColorColumn(well: accentColorWell, caption: L("Accent"))
        let iconCol   = makeColorColumn(well: iconColorWell,   caption: L("Icon"))
        let bgCol     = makeColorColumn(well: bgColorWell,     caption: L("Background"))

        let colorsRow = NSStackView(views: [accentCol, iconCol, bgCol])
        colorsRow.orientation = .horizontal
        colorsRow.alignment = .top
        colorsRow.spacing = 20
        stack.addArrangedSubview(indented(colorsRow))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // Sync preset popup to current colors
        updateThemePresetSelection()

        finalizeSettingsStack(scroll: scroll, stack: stack)
        return scroll
    }

    // MARK: - Capture Tab

    private func makeCaptureTabView() -> NSView {
        let (scroll, stack) = makeSettingsScrollStack()

        // ── Capture ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Capture")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Enter key action
        quickModePopup = NSPopUpButton()
        quickModePopup.addItems(withTitles: [L("Save to file"), L("Copy to clipboard"), L("Save + copy to clipboard"), L("Do nothing")])
        quickModePopup.target = self
        quickModePopup.action = #selector(quickModeChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Enter / Quick Capture:"), controls: [quickModePopup]))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        quickCaptureOpenEditorCheckbox = NSButton(checkboxWithTitle: L("Also open in Editor"), target: self, action: #selector(quickCaptureOpenEditorChanged(_:)))
        stack.addArrangedSubview(indented(quickCaptureOpenEditorCheckbox))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // OCR action dropdown
        ocrActionPopup = NSPopUpButton()
        ocrActionPopup.addItems(withTitles: [
            L("Show window + copy to clipboard"),
            L("Show window only"),
            L("Copy to clipboard only"),
        ])
        ocrActionPopup.target = self
        ocrActionPopup.action = #selector(ocrActionChanged(_:))

        stack.addArrangedSubview(labeledRow(L("OCR Capture:"), controls: [ocrActionPopup]))
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        // Checkboxes
        copySoundCheckbox = NSButton(checkboxWithTitle: L("Play sound on capture"), target: self, action: #selector(copySoundChanged(_:)))
        rememberToolCheckbox = NSButton(checkboxWithTitle: L("Remember last selected tool"), target: self, action: #selector(rememberToolChanged(_:)))
        thumbnailCheckbox = NSButton(checkboxWithTitle: L("Show floating thumbnail after capture"), target: self, action: #selector(thumbnailChanged(_:)))
        snapGuidesCheckbox = NSButton(checkboxWithTitle: L("Show snap alignment guides"), target: self, action: #selector(snapGuidesChanged(_:)))
        captureCursorCheckbox = NSButton(checkboxWithTitle: L("Capture mouse cursor in screenshot"), target: self, action: #selector(captureCursorChanged(_:)))
        windowTitleCheckbox = NSButton(checkboxWithTitle: L("Use window title in saved filename"), target: self, action: #selector(windowTitleChanged(_:)))

        for cb in [copySoundCheckbox!, rememberToolCheckbox!, thumbnailCheckbox!] {
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

        let dismissNote = NSTextField(labelWithString: L("sec (0 = never)"))
        dismissNote.font = NSFont.systemFont(ofSize: 11)
        dismissNote.textColor = .secondaryLabelColor

        stack.addArrangedSubview(indented(labeledRow(L("  Dismiss after:"), controls: [thumbnailAutoDismissField!, thumbnailAutoDismissStepper!, dismissNote])))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Thumbnail stacking popup
        thumbnailStackingPopup = NSPopUpButton()
        thumbnailStackingPopup.addItems(withTitles: [L("Stack (keep all)"), L("Replace (show only latest)")])
        thumbnailStackingPopup.target = self
        thumbnailStackingPopup.action = #selector(thumbnailStackingChanged(_:))

        stack.addArrangedSubview(indented(labeledRow(L("  Multiple previews:"), controls: [thumbnailStackingPopup!])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let sizeSlider = NSSlider(value: UserDefaults.standard.object(forKey: "thumbnailScale") as? Double ?? 1.0,
                                   minValue: 0.5, maxValue: 2.0, target: self, action: #selector(thumbnailScaleChanged(_:)))
        sizeSlider.controlSize = .small
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        thumbnailScaleLabel = NSTextField(labelWithString: scalePercentString(sizeSlider.doubleValue))
        thumbnailScaleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        thumbnailScaleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(labeledRow(L("  Preview size:"), controls: [sizeSlider, thumbnailScaleLabel])))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(snapGuidesCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(captureCursorCheckbox))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        stack.addArrangedSubview(indented(windowTitleCheckbox))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Output ───────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Output")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Save folder
        savePathField = NSTextField()
        savePathField.isEditable = false
        savePathField.isSelectable = false
        savePathField.lineBreakMode = .byTruncatingMiddle

        let browseBtn = NSButton(title: L("Browse…"), target: self, action: #selector(browseSavePath(_:)))
        browseBtn.bezelStyle = .rounded

        stack.addArrangedSubview(labeledRow(L("Save folder:"), controls: [savePathField, browseBtn]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Image format
        imageFormatPopup = NSPopUpButton()
        imageFormatPopup.addItems(withTitles: ["PNG", "JPEG", "HEIC", "WebP"])
        imageFormatPopup.target = self
        imageFormatPopup.action = #selector(imageFormatChanged(_:))

        stack.addArrangedSubview(labeledRow(L("Image format:"), controls: [imageFormatPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        // Quality (applies to JPEG and HEIC)
        qualitySlider = NSSlider()
        qualitySlider.minValue = 10
        qualitySlider.maxValue = 100
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged(_:))
        qualitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true

        qualityLabel = NSTextField(labelWithString: String(format: L("%d%%"), 85))
        qualityLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        qualityRowLabel = NSTextField(labelWithString: L("Quality:"))
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
        downscaleRetinaCheckbox = NSButton(checkboxWithTitle: L("Save at standard resolution (1x)"), target: self, action: #selector(downscaleRetinaChanged(_:)))
        stack.addArrangedSubview(indented(downscaleRetinaCheckbox))
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)

        let downscaleNote = NSTextField(labelWithString: L("Halves dimensions on Retina displays, ~4x smaller files"))
        downscaleNote.font = NSFont.systemFont(ofSize: 10)
        downscaleNote.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(indented(downscaleNote))
        stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)

        // Color profile is always embedded (native display profile) — no toggle needed.

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

        historyUnlimitedCheckbox = NSButton(checkboxWithTitle: L("Unlimited"), target: self, action: #selector(historyUnlimitedChanged(_:)))
        historyUnlimitedCheckbox.font = NSFont.systemFont(ofSize: 11)

        let histNote = NSTextField(labelWithString: L("(0 = off)"))
        histNote.font = NSFont.systemFont(ofSize: 11)
        histNote.textColor = .secondaryLabelColor

        stack.addArrangedSubview(labeledRow(L("History size:"), controls: [historySizeField, historySizeStepper, histNote, historyUnlimitedCheckbox]))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Translation ──────────────────────────────────────
        if TranslationService.appleTranslationAvailable {
            stack.addArrangedSubview(sectionHeader(L("Translation")))
            stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

            let translationProviderPopup = NSPopUpButton()
            translationProviderPopup.addItems(withTitles: [
                L("Apple (on-device)"),
                L("Google Translate"),
            ])
            translationProviderPopup.selectItem(at: TranslationService.provider == .apple ? 0 : 1)
            translationProviderPopup.target = self
            translationProviderPopup.action = #selector(translationProviderChanged(_:))
            stack.addArrangedSubview(labeledRow(L("Engine:"), controls: [translationProviderPopup]))
            stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

            let providerNote = NSTextField(wrappingLabelWithString: L("Apple translation is faster and works offline. Google Translate supports more languages."))
            providerNote.font = NSFont.systemFont(ofSize: 10)
            providerNote.textColor = .secondaryLabelColor
            stack.addArrangedSubview(indented(providerNote))
            stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

            let downloadLink = NSButton(title: L("Download language packs in System Settings…"), target: self, action: #selector(openTranslationSettings))
            downloadLink.bezelStyle = .inline
            downloadLink.isBordered = false
            downloadLink.contentTintColor = .linkColor
            downloadLink.font = NSFont.systemFont(ofSize: 10)
            stack.addArrangedSubview(indented(downloadLink))
            stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        }

        finalizeSettingsStack(scroll: scroll, stack: stack)
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

        stack.addArrangedSubview(sectionHeader(L("Keyboard Shortcuts")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        for slot in HotkeyManager.HotkeySlot.allCases {
            let field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.stringValue = HotkeyManager.displayString(for: slot)

            let btn = NSButton(title: L("Set"), target: self, action: #selector(recordShortcut(_:)))
            btn.bezelStyle = .rounded
            btn.tag = slot.rawValue

            let clearBtn = NSButton(title: "", target: self, action: #selector(clearShortcut(_:)))
            clearBtn.bezelStyle = .inline
            clearBtn.isBordered = false
            clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("None"))
            clearBtn.contentTintColor = .secondaryLabelColor
            clearBtn.imagePosition = .imageOnly
            clearBtn.tag = slot.rawValue
            clearBtn.toolTip = L("None")
            clearBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let resetBtn = NSButton(title: "", target: self, action: #selector(resetShortcut(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.isBordered = false
            resetBtn.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: L("Reset to default"))
            resetBtn.contentTintColor = .secondaryLabelColor
            resetBtn.imagePosition = .imageOnly
            resetBtn.tag = slot.rawValue
            resetBtn.toolTip = L("Reset to default")
            resetBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            hotkeyFields[slot] = field
            hotkeyButtons[slot] = btn

            stack.addArrangedSubview(labeledRow("\(slot.label):", controls: [field, btn, clearBtn, resetBtn]))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }

        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let note = NSTextField(wrappingLabelWithString: L("Click \"Set\" and press a key combination with at least one modifier (⌘, ⌥, ⌃, ⇧) to set a shortcut."))
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(note))

        // ── Overlay / Editor Tool Shortcuts ──────────────────
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(sectionHeader(L("Overlay / Editor Shortcuts")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        for action in ToolShortcutManager.Action.allCases {
            let field = NSTextField()
            field.isEditable = false
            field.isSelectable = false
            field.alignment = .center
            field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.stringValue = ToolShortcutManager.displayString(for: action)

            let btn = NSButton(title: L("Set"), target: self, action: #selector(recordToolShortcut(_:)))
            btn.bezelStyle = .rounded
            btn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!

            let clearBtn = NSButton(title: "", target: self, action: #selector(clearToolShortcut(_:)))
            clearBtn.bezelStyle = .inline
            clearBtn.isBordered = false
            clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("None"))
            clearBtn.contentTintColor = .secondaryLabelColor
            clearBtn.imagePosition = .imageOnly
            clearBtn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!
            clearBtn.toolTip = L("None")
            clearBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let resetBtn = NSButton(title: "", target: self, action: #selector(resetToolShortcut(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.isBordered = false
            resetBtn.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle.fill", accessibilityDescription: L("Reset to default"))
            resetBtn.contentTintColor = .secondaryLabelColor
            resetBtn.imagePosition = .imageOnly
            resetBtn.tag = ToolShortcutManager.Action.allCases.firstIndex(of: action)!
            resetBtn.toolTip = L("Reset to default")
            resetBtn.widthAnchor.constraint(equalToConstant: 20).isActive = true

            toolShortcutFields[action] = field
            toolShortcutButtons[action] = btn

            stack.addArrangedSubview(labeledRow("\(action.label):", controls: [field, btn, clearBtn, resetBtn]))
            stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        }

        let toolNote = NSTextField(wrappingLabelWithString: L("Press a single key to assign it as the shortcut for that tool. These work when the overlay or editor is active."))
        toolNote.font = NSFont.systemFont(ofSize: 10)
        toolNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(toolNote))

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
        // Stop any previous recording (global or tool)
        stopShortcutRecording()
        stopToolShortcutRecording()

        recordingSlot = slot
        sender.title = L("Press keys...")
        hotkeyFields[slot]?.stringValue = L("Waiting...")

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags
            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift)   { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option)  { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
            let keyCode = UInt32(event.keyCode)
            if carbonMods == 0 && !HotkeyManager.isFunctionKey(keyCode) { return nil }
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
        hotkeyFields[slot]?.stringValue = L("None")
        onHotkeyChanged?()
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let slot = HotkeyManager.HotkeySlot(rawValue: sender.tag) else { return }
        stopShortcutRecording()
        HotkeyManager.saveHotkey(for: slot, keyCode: slot.defaultKeyCode, modifiers: slot.defaultModifiers)
        hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        onHotkeyChanged?()
    }

    private func stopShortcutRecording() {
        if let slot = recordingSlot {
            hotkeyButtons[slot]?.title = L("Set")
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }
        recordingSlot = nil
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    // MARK: - Overlay Tool Shortcuts

    @objc private func recordToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]

        // If already recording this action, stop
        if recordingToolAction == action {
            stopToolShortcutRecording()
            return
        }
        // Stop any other recording (global or tool)
        stopShortcutRecording()
        stopToolShortcutRecording()

        recordingToolAction = action
        sender.title = L("Press...")
        toolShortcutFields[action]?.stringValue = "…"

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Only accept single keys without modifiers (or allow Escape to cancel)
            if event.keyCode == 53 { // Escape — cancel
                self.stopToolShortcutRecording()
                return nil
            }
            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  !event.modifierFlags.contains(.control),
                  let char = event.charactersIgnoringModifiers?.lowercased(),
                  char.count == 1 else { return nil }

            ToolShortcutManager.setKey(char, for: action)
            self.toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            self.stopToolShortcutRecording()
            return nil
        }
    }

    @objc private func clearToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]
        stopToolShortcutRecording()
        ToolShortcutManager.setKey("", for: action)
        toolShortcutFields[action]?.stringValue = L("None")
    }

    @objc private func resetToolShortcut(_ sender: NSButton) {
        let allActions = ToolShortcutManager.Action.allCases
        guard sender.tag >= 0, sender.tag < allActions.count else { return }
        let action = allActions[sender.tag]
        stopToolShortcutRecording()
        ToolShortcutManager.setKey(action.defaultKey, for: action)
        toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
    }

    private func stopToolShortcutRecording() {
        if let action = recordingToolAction {
            toolShortcutFields[action]?.stringValue = ToolShortcutManager.displayString(for: action)
            toolShortcutButtons[action]?.title = L("Set")
        }
        recordingToolAction = nil
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
        stack.addArrangedSubview(sectionHeader(L("Annotation Tools")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteA = NSTextField(labelWithString: L("Hidden tools are removed from the bottom toolbar."))
        noteA.font = NSFont.systemFont(ofSize: 11)
        noteA.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteA)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let annotationTools: [(AnnotationTool, String)] = [
            (.pencil, L("Pencil")), (.line, L("Line")), (.arrow, L("Arrow")),
            (.rectangle, L("Rectangle")),
            (.ellipse, L("Ellipse")), (.marker, L("Marker")), (.text, L("Text")),
            (.number, L("Number / Counter")), (.pixelate, L("Censor")),
            (.loupe, L("Magnify (Loupe)")), (.stamp, L("Stamp / Emoji")), (.colorSampler, L("Color Picker")), (.measure, L("Measure")),
        ]
        let enabledTools = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]
        let toolsGrid = makeToggleGrid(items: annotationTools.map { (tag: $0.rawValue, label: $1) },
                                       defaultsKey: "enabledTools", enabledValues: enabledTools)
        stack.addArrangedSubview(toolsGrid)
        toolsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Bottom Toolbar Actions ───────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Bottom Toolbar Actions")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteB = NSTextField(labelWithString: L("Hidden actions are removed from the bottom toolbar."))
        noteB.font = NSFont.systemFont(ofSize: 11)
        noteB.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteB)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let bottomActionItems: [(tag: Int, label: String)] = [
            (1011, L("Invert Colors")),
            (1013, L("Adjust (Image Effects)")),
            (1004, L("Beautify")),
            (1005, L("Remove Background")),
        ]
        let enabledActions = UserDefaults.standard.array(forKey: "enabledActions") as? [Int]
        let bottomActionsGrid = makeToggleGrid(items: bottomActionItems,
                                               defaultsKey: "enabledActions", enabledValues: enabledActions)
        stack.addArrangedSubview(bottomActionsGrid)
        bottomActionsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Right Toolbar Actions ────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Right Toolbar Actions")))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let noteC = NSTextField(labelWithString: L("Hidden actions are removed from the right toolbar."))
        noteC.font = NSFont.systemFont(ofSize: 11)
        noteC.textColor = .secondaryLabelColor
        stack.addArrangedSubview(noteC)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        let rightActionItems: [(tag: Int, label: String)] = [
            (1001, L("Upload")), (1002, L("Pin (floating window)")),
            (1003, L("OCR (extract text)")), (1006, L("Auto-Redact sensitive data")),
            (1008, L("Translate")),
            (1009, L("Record screen")),
            (1010, L("Scroll Capture")),
            (1012, L("Share")),
        ]
        let rightActionsGrid = makeToggleGrid(items: rightActionItems,
                                              defaultsKey: "enabledActions", enabledValues: enabledActions)
        stack.addArrangedSubview(rightActionsGrid)
        rightActionsGrid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

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

        // ── Output ────────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Output")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        recordingFPSPopup = NSPopUpButton()
        recordingFPSPopup.addItems(withTitles: [L("15 fps"), L("24 fps"), L("30 fps"), L("60 fps"), L("120 fps")])
        recordingFPSPopup.target = self
        recordingFPSPopup.action = #selector(recordingFPSChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Frame rate:"), controls: [recordingFPSPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        recSavePathField = NSTextField()
        recSavePathField.isEditable = false
        recSavePathField.isSelectable = false
        recSavePathField.lineBreakMode = .byTruncatingMiddle

        let recBrowseBtn = NSButton(title: L("Browse…"), target: self, action: #selector(browseRecSavePath(_:)))
        recBrowseBtn.bezelStyle = .rounded
        let recClearBtn = NSButton(title: L("Clear"), target: self, action: #selector(clearRecSavePath(_:)))
        recClearBtn.bezelStyle = .rounded

        stack.addArrangedSubview(labeledRow(L("Save folder:"), controls: [recSavePathField, recBrowseBtn, recClearBtn]))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Behavior ──────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Behavior")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        recordingOnStopPopup = NSPopUpButton()
        recordingOnStopPopup.addItems(withTitles: [L("Open editor"), L("Show in Finder"), L("Copy to clipboard")])
        recordingOnStopPopup.target = self
        recordingOnStopPopup.action = #selector(recordingOnStopChanged(_:))
        stack.addArrangedSubview(labeledRow(L("When done:"), controls: [recordingOnStopPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        let hideHUDCheckbox = NSButton(checkboxWithTitle: L("Hide recording controls"), target: self, action: #selector(hideRecordingHUDChanged(_:)))
        hideHUDCheckbox.state = UserDefaults.standard.bool(forKey: "hideRecordingHUD") ? .on : .off
        stack.addArrangedSubview(indented(hideHUDCheckbox))

        let hideHUDNote = NSTextField(labelWithString: L("Stop recording from the menu bar icon instead."))
        hideHUDNote.font = NSFont.systemFont(ofSize: 10)
        hideHUDNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(hideHUDNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Webcam ───────────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Webcam")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        webcamPositionPopup = NSPopUpButton()
        webcamPositionPopup.addItems(withTitles: [L("Bottom Right"), L("Bottom Left"), L("Top Right"), L("Top Left")])
        webcamPositionPopup.target = self
        webcamPositionPopup.action = #selector(webcamPositionChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Position:"), controls: [webcamPositionPopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        webcamSizePopup = NSPopUpButton()
        webcamSizePopup.addItems(withTitles: [L("Small"), L("Medium"), L("Large")])
        webcamSizePopup.target = self
        webcamSizePopup.action = #selector(webcamSizeChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Size:"), controls: [webcamSizePopup]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        webcamShapePopup = NSPopUpButton()
        webcamShapePopup.addItems(withTitles: [L("Circle"), L("Rounded Rectangle")])
        webcamShapePopup.target = self
        webcamShapePopup.action = #selector(webcamShapeChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Shape:"), controls: [webcamShapePopup]))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Scroll Capture ────────────────────────────────────
        stack.addArrangedSubview(sectionHeader(L("Scroll Capture")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        scrollAutoScrollCheckbox = NSButton(checkboxWithTitle: L("Auto-scroll (sends synthetic scroll events)"),
                                            target: self, action: #selector(scrollAutoScrollChanged(_:)))
        stack.addArrangedSubview(scrollAutoScrollCheckbox)
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollSpeedPopup = NSPopUpButton()
        scrollSpeedPopup.addItems(withTitles: [L("Slow"), L("Medium"), L("Fast"), L("Very fast")])
        scrollSpeedPopup.target = self
        scrollSpeedPopup.action = #selector(scrollSpeedChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Scroll speed:"), controls: [scrollSpeedPopup]))
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

        let maxHeightNote = NSTextField(labelWithString: L("px (0 = unlimited)"))
        maxHeightNote.font = .systemFont(ofSize: 11)
        maxHeightNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(labeledRow(L("Max height:"), controls: [scrollMaxHeightField, scrollMaxHeightStepper, maxHeightNote]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        scrollFrozenDetectionCheckbox = NSButton(checkboxWithTitle: L("Detect fixed/sticky headers"),
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
        stack.addArrangedSubview(sectionHeader(L("Upload Provider")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: [L("imgbb (images only)"), L("Google Drive (images + videos)"), L("S3-Compatible (images + videos)")])
        let currentProvider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        switch currentProvider {
        case "gdrive": providerPopup.selectItem(at: 1)
        case "s3": providerPopup.selectItem(at: 2)
        default: providerPopup.selectItem(at: 0)
        }
        providerPopup.target = self
        providerPopup.action = #selector(uploadProviderChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Provider:"), controls: [providerPopup]))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── Google Drive ──
        stack.addArrangedSubview(sectionHeader(L("Google Drive")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        gdriveStatusLabel = NSTextField(labelWithString: "")
        gdriveStatusLabel.font = NSFont.systemFont(ofSize: 11)
        gdriveStatusLabel.textColor = .secondaryLabelColor
        updateGDriveStatus()

        gdriveSignInBtn = NSButton(title: L("Sign In with Google"), target: self, action: #selector(gdriveSignInTapped(_:)))
        gdriveSignInBtn.bezelStyle = .rounded
        updateGDriveButton()

        stack.addArrangedSubview(labeledRow(L("Account:"), controls: [gdriveStatusLabel]))
        stack.addArrangedSubview(indented(gdriveSignInBtn))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let gdriveNote = NSTextField(wrappingLabelWithString: L("Files are uploaded to a \"macshot\" folder in your Google Drive. Everything stays private — nothing is shared publicly."))
        gdriveNote.font = NSFont.systemFont(ofSize: 10)
        gdriveNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(gdriveNote))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── S3-Compatible ──
        stack.addArrangedSubview(sectionHeader(L("S3-Compatible Storage")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        s3EndpointField = NSTextField()
        s3EndpointField.placeholderString = "https://abc123.r2.cloudflarestorage.com"
        s3EndpointField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3EndpointField.stringValue = UserDefaults.standard.string(forKey: "s3Endpoint") ?? ""
        s3EndpointField.target = self
        s3EndpointField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Endpoint:"), controls: [s3EndpointField]))

        s3RegionField = NSTextField()
        s3RegionField.placeholderString = "auto"
        s3RegionField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3RegionField.stringValue = UserDefaults.standard.string(forKey: "s3Region") ?? "auto"
        s3RegionField.target = self
        s3RegionField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Region:"), controls: [s3RegionField]))

        s3BucketField = NSTextField()
        s3BucketField.placeholderString = "my-bucket"
        s3BucketField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3BucketField.stringValue = UserDefaults.standard.string(forKey: "s3Bucket") ?? ""
        s3BucketField.target = self
        s3BucketField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Bucket:"), controls: [s3BucketField]))

        s3AccessKeyField = NSTextField()
        s3AccessKeyField.placeholderString = "AKIAIOSFODNN7EXAMPLE"
        s3AccessKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3AccessKeyField.stringValue = UserDefaults.standard.string(forKey: "s3AccessKeyID") ?? ""
        s3AccessKeyField.target = self
        s3AccessKeyField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Access Key:"), controls: [s3AccessKeyField]))

        s3SecretKeyField = NSSecureTextField()
        s3SecretKeyField.placeholderString = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        s3SecretKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3SecretKeyField.stringValue = UserDefaults.standard.string(forKey: "s3SecretAccessKey") ?? ""
        s3SecretKeyField.target = self
        s3SecretKeyField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Secret Key:"), controls: [s3SecretKeyField]))

        s3PublicURLField = NSTextField()
        s3PublicURLField.placeholderString = "https://cdn.example.com"
        s3PublicURLField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3PublicURLField.stringValue = UserDefaults.standard.string(forKey: "s3PublicURLBase") ?? ""
        s3PublicURLField.target = self
        s3PublicURLField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Public URL:"), controls: [s3PublicURLField]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let publicURLNote = NSTextField(wrappingLabelWithString: L("Base URL for public access. If empty, the S3 endpoint URL is used (may not be publicly accessible)."))
        publicURLNote.font = NSFont.systemFont(ofSize: 10)
        publicURLNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(publicURLNote))

        s3PathPrefixField = NSTextField()
        s3PathPrefixField.placeholderString = "screenshots/"
        s3PathPrefixField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        s3PathPrefixField.stringValue = UserDefaults.standard.string(forKey: "s3PathPrefix") ?? ""
        s3PathPrefixField.target = self
        s3PathPrefixField.action = #selector(s3FieldChanged(_:))
        stack.addArrangedSubview(labeledRow(L("Path Prefix:"), controls: [s3PathPrefixField]))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)

        s3TestBtn = NSButton(title: L("Test Connection"), target: self, action: #selector(s3TestTapped(_:)))
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

        let s3Note = NSTextField(wrappingLabelWithString: L("Works with AWS S3, Cloudflare R2, MinIO, DigitalOcean Spaces, Backblaze B2, and other S3-compatible services. Supports images and videos."))
        s3Note.font = NSFont.systemFont(ofSize: 10)
        s3Note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(s3Note))
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)

        // ── imgbb ──
        stack.addArrangedSubview(sectionHeader("imgbb"))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        imgbbKeyField = NSTextField()
        imgbbKeyField.placeholderString = L("Leave empty to use default")
        imgbbKeyField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        imgbbKeyField.target = self
        imgbbKeyField.action = #selector(imgbbKeyChanged(_:))
        if let key = UserDefaults.standard.string(forKey: "imgbbAPIKey") {
            imgbbKeyField.stringValue = key
        }

        stack.addArrangedSubview(labeledRow(L("API key:"), controls: [imgbbKeyField]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        let imgbbNote = NSTextField(wrappingLabelWithString: L("A shared key is included — get your own free key at imgbb.com/api if you hit rate limits. Images only (no video support)."))
        imgbbNote.font = NSFont.systemFont(ofSize: 10)
        imgbbNote.textColor = .secondaryLabelColor
        stack.addArrangedSubview(indented(imgbbNote))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        // ── Upload History ──
        stack.addArrangedSubview(sectionHeader(L("Upload History")))
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last!)

        // Placeholder for upload history rows
        let historyContainer = NSStackView()
        historyContainer.orientation = .vertical
        historyContainer.alignment = .width
        historyContainer.spacing = 6
        historyContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(historyContainer)
        // Stretch to full stack width
        historyContainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
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
        let versionLabel = NSTextField(labelWithString: String(format: L("Version %@ (%@)"), version, build))
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)
        stack.setCustomSpacing(20, after: versionLabel)

        // Description
        let desc = NSTextField(wrappingLabelWithString: L("A free, open-source screenshot & screen recording tool for macOS.\nFully native — built with Swift and AppKit."))
        desc.font = NSFont.systemFont(ofSize: 13)
        desc.textColor = .labelColor
        desc.alignment = .center
        stack.addArrangedSubview(desc)
        stack.setCustomSpacing(20, after: desc)

        // License
        let license = NSTextField(labelWithString: L("Licensed under the GPLv3"))
        license.font = NSFont.systemFont(ofSize: 11)
        license.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(license)
        stack.setCustomSpacing(20, after: license)

        // Screen Info (debug) — gathers display & capture metadata, copies to clipboard
        let screenInfoBtn = NSButton(title: L("Copy Screen Info"), target: self, action: #selector(copyScreenInfo))
        screenInfoBtn.bezelStyle = .rounded
        screenInfoBtn.font = NSFont.systemFont(ofSize: 11)
        screenInfoBtn.tag = 9999  // tag for lookup in action handler
        stack.addArrangedSubview(screenInfoBtn)

        let screenInfoHint = NSTextField(labelWithString: L("Copies display and capture diagnostics to clipboard"))
        screenInfoHint.font = NSFont.systemFont(ofSize: 10)
        screenInfoHint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(screenInfoHint)

        return container
    }

    @objc private func copyScreenInfo() {
        if #available(macOS 14.0, *) {
            Task { @MainActor in
                var lines: [String] = []
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                lines.append("macshot \(version) (\(build))")
                lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                lines.append("")
                lines.append("=== NSScreen Info ===")
                for (i, screen) in NSScreen.screens.enumerated() {
                    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
                    let cs = screen.colorSpace?.cgColorSpace
                    // CGDisplayCopyColorSpace reads the display ICC profile directly,
                    // bypassing NSScreen — helps diagnose DisplayLink/driver issues.
                    let cgCS = CGDisplayCopyColorSpace(id)
                    lines.append("Screen \(i): \(screen.localizedName) (ID: \(id))")
                    lines.append("  frame: \(screen.frame)")
                    lines.append("  backingScale: \(screen.backingScaleFactor)")
                    lines.append("  NSScreen.colorSpace: \(cs?.name as String? ?? "nil")")
                    lines.append("  CGDisplayCopyColorSpace: \(cgCS.name as String? ?? "nil")")
                    lines.append("  cs model: \(cs?.model.rawValue ?? -1)")
                    lines.append("")
                }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    lines.append("=== ScreenCaptureKit Capture Info ===")
                    for display in content.displays {
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        let config = SCStreamConfiguration()
                        config.width = display.width
                        config.height = display.height
                        config.captureResolution = .best
                        config.colorSpaceName = CGColorSpace.sRGB as CFString
                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                            lines.append("Display \(display.displayID) (\(display.width)x\(display.height)):")
                            lines.append("  CGImage size: \(img.width)x\(img.height)")
                            lines.append("  bitsPerComponent: \(img.bitsPerComponent)")
                            lines.append("  bitsPerPixel: \(img.bitsPerPixel)")
                            lines.append("  bytesPerRow: \(img.bytesPerRow)")
                            lines.append("  bitmapInfo: \(img.bitmapInfo.rawValue)")
                            lines.append("  alphaInfo: \(img.alphaInfo.rawValue)")
                            lines.append("  colorSpace: \(img.colorSpace?.name as String? ?? "nil")")
                            lines.append("  cs model: \(img.colorSpace?.model.rawValue ?? -1)")
                            lines.append("")
                        }
                    }
                } catch {
                    lines.append("Capture error: \(error.localizedDescription)")
                }
                let result = lines.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                // Flash the button title to confirm
                if let btn = self.window?.contentView?.viewWithTag(9999) as? NSButton {
                    btn.title = L("Copied!")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { btn.title = L("Copy Screen Info") }
                }
            }
        }
    }

    private func updateGDriveStatus() {
        if GoogleDriveUploader.shared.isSignedIn {
            gdriveStatusLabel?.stringValue = GoogleDriveUploader.shared.userEmail ?? L("Signed in")
            gdriveStatusLabel?.textColor = .labelColor
        } else {
            gdriveStatusLabel?.stringValue = L("Not signed in")
            gdriveStatusLabel?.textColor = .secondaryLabelColor
        }
    }

    private func updateGDriveButton() {
        if GoogleDriveUploader.shared.isSignedIn {
            gdriveSignInBtn?.title = L("Sign Out")
        } else {
            gdriveSignInBtn?.title = L("Sign In with Google")
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
            s3StatusLabel.stringValue = L("Fill in endpoint, bucket, and credentials first")
            s3StatusLabel.textColor = .systemOrange
            return
        }

        s3TestBtn.isEnabled = false
        s3StatusLabel.stringValue = L("Testing...")
        s3StatusLabel.textColor = .secondaryLabelColor

        // Upload a tiny test file
        let testData = Data("macshot connection test".utf8)
        let testKey = ".macshot_test_\(UUID().uuidString.prefix(8)).txt"
        S3Uploader.shared.upload(data: testData, filename: testKey, contentType: "text/plain") { [weak self] result in
            guard let self = self else { return }
            self.s3TestBtn.isEnabled = true
            switch result {
            case .success:
                self.s3StatusLabel.stringValue = L("Connection successful!")
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
            let lbl = NSTextField(labelWithString: L("No uploads yet."))
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

        let btn = NSButton(title: L("Copy"), target: self, action: #selector(copyUploadURL(_:)))
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

        for row in 0..<rows {
            let hStack = NSStackView()
            hStack.orientation = .horizontal
            hStack.distribution = .fillEqually
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
                    hStack.addArrangedSubview(cb)
                } else {
                    let filler = NSView()
                    filler.translatesAutoresizingMaskIntoConstraints = false
                    hStack.addArrangedSubview(filler)
                }
            }
            vStack.addArrangedSubview(hStack)
            // Stretch row to fill the vStack's width (must be after addArrangedSubview
            // so both views share a common ancestor)
            hStack.widthAnchor.constraint(equalTo: vStack.widthAnchor).isActive = true
        }

        return box
    }

    // MARK: - Load settings

    private func loadSettings() {
        // Load shortcut fields
        for slot in HotkeyManager.HotkeySlot.allCases {
            hotkeyFields[slot]?.stringValue = HotkeyManager.displayString(for: slot)
        }

        savePathField.stringValue = SaveDirectoryAccess.displayPath

        // Migrate legacy bool to new int setting
        if UserDefaults.standard.object(forKey: "ocrAction") == nil {
            let legacyAutoCopy = UserDefaults.standard.object(forKey: "autoCopyOCRText") as? Bool ?? true
            UserDefaults.standard.set(legacyAutoCopy ? 0 : 1, forKey: "ocrAction")
        }
        ocrActionPopup.selectItem(at: UserDefaults.standard.integer(forKey: "ocrAction"))

        let copySound = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        copySoundCheckbox.state = copySound ? .on : .off

        // rememberSelectionCheckbox removed

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

        let autoUpdate = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        autoUpdateCheckbox.state = autoUpdate ? .on : .off

        betaUpdateCheckbox.state = UserDefaults.standard.bool(forKey: "betaUpdatesEnabled") ? .on : .off

        accentColorWell.color = ToolbarLayout.accentColor
        iconColorWell.color = ToolbarLayout.iconColor
        bgColorWell.color = ToolbarLayout.bgColor

        let historySize = UserDefaults.standard.object(forKey: "historySize") as? Int ?? 10
        historySizeField.integerValue = historySize
        historySizeStepper.integerValue = historySize
        historyUnlimitedCheckbox.state = UserDefaults.standard.bool(forKey: "historyUnlimited") ? .on : .off
        updateHistoryControlsEnabled()

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
        quickCaptureOpenEditorCheckbox.state = UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") ? .on : .off

        let format = ImageEncoder.format
        switch format {
        case .png:  imageFormatPopup.selectItem(at: 0)
        case .jpeg: imageFormatPopup.selectItem(at: 1)
        case .heic: imageFormatPopup.selectItem(at: 2)
        case .webp: imageFormatPopup.selectItem(at: 3)
        }

        let quality = Int(ImageEncoder.quality * 100)
        qualitySlider.integerValue = quality
        qualityLabel.stringValue = String(format: L("%d%%"), quality)

        downscaleRetinaCheckbox.state = ImageEncoder.downscaleRetina ? .on : .off
        updateQualityVisibility()

        imgbbKeyField.stringValue = UserDefaults.standard.string(forKey: "imgbbAPIKey") ?? ""

        // Recording
        let recFPS = UserDefaults.standard.integer(forKey: "recordingFPS")
        let mp4Options = [15, 24, 30, 60, 120]
        let fpsIdx = mp4Options.firstIndex(of: recFPS) ?? 2
        recordingFPSPopup.selectItem(at: fpsIdx)

        let onStop = UserDefaults.standard.string(forKey: "recordingOnStop") ?? "editor"
        switch onStop {
        case "finder": recordingOnStopPopup.selectItem(at: 1)
        case "clipboard": recordingOnStopPopup.selectItem(at: 2)
        default: recordingOnStopPopup.selectItem(at: 0)
        }

        recSavePathField.stringValue = SaveDirectoryAccess.recordingDisplayPath

        // Webcam
        let webcamPos = UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight"
        switch webcamPos {
        case "bottomRight": webcamPositionPopup.selectItem(at: 0)
        case "bottomLeft": webcamPositionPopup.selectItem(at: 1)
        case "topRight": webcamPositionPopup.selectItem(at: 2)
        case "topLeft": webcamPositionPopup.selectItem(at: 3)
        default: webcamPositionPopup.selectItem(at: 0)
        }

        let webcamSize = UserDefaults.standard.string(forKey: "webcamSize") ?? "medium"
        switch webcamSize {
        case "small": webcamSizePopup.selectItem(at: 0)
        case "medium": webcamSizePopup.selectItem(at: 1)
        case "large": webcamSizePopup.selectItem(at: 2)
        default: webcamSizePopup.selectItem(at: 1)
        }

        webcamShapePopup.selectItem(at: (UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") == "roundedRect" ? 1 : 0)

        // Scroll Capture
        let autoScroll = UserDefaults.standard.object(forKey: "scrollAutoScrollEnabled") as? Bool ?? false
        scrollAutoScrollCheckbox.state = autoScroll ? .on : .off
        let speed = UserDefaults.standard.object(forKey: "scrollAutoScrollSpeed") as? Int ?? 3
        scrollSpeedPopup.selectItem(at: max(0, min(3, speed - 1)))
        scrollSpeedPopup.isEnabled = autoScroll
        let maxH = UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? 30000
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

    @objc private func ocrActionChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "ocrAction")
    }
    @objc private func copySoundChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "playCopySound")
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
    @objc private func thumbnailScaleChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.doubleValue, forKey: "thumbnailScale")
        thumbnailScaleLabel?.stringValue = scalePercentString(sender.doubleValue)
    }

    private func scalePercentString(_ scale: Double) -> String {
        "\(Int(round(scale * 100)))%"
    }

    @objc private func thumbnailStackingChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 0, forKey: "thumbnailStacking")
    }
    @objc private func quickModeChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem, forKey: "quickCaptureMode")
    }
    @objc private func quickCaptureOpenEditorChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "quickCaptureOpenEditor")
    }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let languages = LanguageManager.availableLanguages
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < languages.count else { return }
        LanguageManager.shared.currentLanguage = languages[idx].code
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
        qualityLabel.stringValue = String(format: L("%d%%"), sender.integerValue)
        UserDefaults.standard.set(Double(sender.integerValue) / 100.0, forKey: "imageQuality")
    }
    @objc private func downscaleRetinaChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "downscaleRetina")
    }
    @objc private func imgbbKeyChanged(_ sender: NSTextField) {
        let key = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { UserDefaults.standard.removeObject(forKey: "imgbbAPIKey") }
        else { UserDefaults.standard.set(key, forKey: "imgbbAPIKey") }
    }
    @objc private func historySizeChanged(_ sender: NSStepper) {
        historySizeField.integerValue = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "historySize")
        UserDefaults.standard.set(false, forKey: "historyUnlimited")
        historyUnlimitedCheckbox.state = .off
        updateHistoryControlsEnabled()
        ScreenshotHistory.shared.pruneToMax()
    }

    @objc private func historyUnlimitedChanged(_ sender: NSButton) {
        let unlimited = sender.state == .on
        UserDefaults.standard.set(unlimited, forKey: "historyUnlimited")
        updateHistoryControlsEnabled()
    }

    private func updateHistoryControlsEnabled() {
        let unlimited = UserDefaults.standard.bool(forKey: "historyUnlimited")
        historySizeField.alphaValue = unlimited ? 0.35 : 1.0
        historySizeStepper.isEnabled = !unlimited
    }
    @objc private func recordingFPSChanged(_ sender: NSPopUpButton) {
        let fpsOptions = [15, 24, 30, 60, 120]
        let fps = fpsOptions[min(sender.indexOfSelectedItem, fpsOptions.count - 1)]
        UserDefaults.standard.set(fps, forKey: "recordingFPS")
    }
    @objc private func recordingOnStopChanged(_ sender: NSPopUpButton) {
        let values = ["editor", "finder", "clipboard"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "recordingOnStop")
    }
    @objc private func hideRecordingHUDChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "hideRecordingHUD")
    }

    @objc private func webcamPositionChanged(_ sender: NSPopUpButton) {
        let values = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "webcamPosition")
    }

    @objc private func webcamSizeChanged(_ sender: NSPopUpButton) {
        let values = ["small", "medium", "large"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "webcamSize")
    }

    @objc private func webcamShapeChanged(_ sender: NSPopUpButton) {
        let values = ["circle", "roundedRect"]
        UserDefaults.standard.set(values[sender.indexOfSelectedItem], forKey: "webcamShape")
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
                                          .ellipse, .marker, .text, .number, .pixelate, .loupe, .stamp, .measure]
        let allActions: [Int] = [1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010]
        let defaultValues: [Int] = key == "enabledTools" ? allTools.map { $0.rawValue } : allActions
        var enabled = UserDefaults.standard.array(forKey: key) as? [Int] ?? defaultValues
        if sender.state == .on { if !enabled.contains(sender.tag) { enabled.append(sender.tag) } }
        else { enabled.removeAll { $0 == sender.tag } }
        UserDefaults.standard.set(enabled, forKey: key)
    }
    @objc private func accentColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveAccentColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    @objc private func iconColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveIconColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    @objc private func bgColorChanged(_ sender: NSColorWell) {
        ToolbarLayout.saveBgColor(sender.color)
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }
    // MARK: - Theme presets

    private struct ThemePreset {
        let name: String
        let accent: NSColor
        let icon: NSColor
        let bg: NSColor

        static let all: [ThemePreset] = [
            ThemePreset(name: "Default",
                        accent: ToolbarLayout.defaultAccentColor,
                        icon:   ToolbarLayout.defaultIconColor,
                        bg:     ToolbarLayout.defaultBgColor),
            ThemePreset(name: "Classic",
                        accent: NSColor(calibratedRed: 0.00, green: 0.48, blue: 1.00, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(white: 0.12, alpha: 1.0)),
            ThemePreset(name: "Ocean",
                        accent: NSColor(calibratedRed: 0.20, green: 0.70, blue: 0.75, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.18, alpha: 1.0)),
            ThemePreset(name: "Sunset",
                        accent: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.20, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(calibratedRed: 0.15, green: 0.10, blue: 0.12, alpha: 1.0)),
            ThemePreset(name: "Forest",
                        accent: NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.45, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.10, alpha: 1.0)),
            ThemePreset(name: "Mono",
                        accent: NSColor(white: 0.85, alpha: 1.0),
                        icon:   .white,
                        bg:     NSColor(white: 0.10, alpha: 1.0)),
        ]
    }

    private func makeColorColumn(well: NSColorWell, caption: String) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let col = NSStackView(views: [well, label])
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        return col
    }

    @objc private func themePresetChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx < ThemePreset.all.count else { return } // "Custom" — no-op
        applyThemePreset(ThemePreset.all[idx])
    }

    private func applyThemePreset(_ preset: ThemePreset) {
        ToolbarLayout.saveAccentColor(preset.accent)
        ToolbarLayout.saveIconColor(preset.icon)
        ToolbarLayout.saveBgColor(preset.bg)
        accentColorWell.color = preset.accent
        iconColorWell.color = preset.icon
        bgColorWell.color = preset.bg
        notifyToolbarColorChange()
        updateThemePresetSelection()
    }

    private func updateThemePresetSelection() {
        guard let popup = themePresetPopup else { return }
        let current = (ToolbarLayout.accentColor, ToolbarLayout.iconColor, ToolbarLayout.bgColor)
        for (i, preset) in ThemePreset.all.enumerated() {
            if colorsClose(current.0, preset.accent) &&
               colorsClose(current.1, preset.icon) &&
               colorsClose(current.2, preset.bg) {
                popup.selectItem(at: i)
                return
            }
        }
        // No match — select "Custom" (the last item)
        popup.selectItem(at: ThemePreset.all.count)
    }

    /// Compare two NSColors in sRGB with a small tolerance (color picker rounding).
    private func colorsClose(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return false }
        let tol: CGFloat = 0.01
        return abs(x.redComponent - y.redComponent) < tol
            && abs(x.greenComponent - y.greenComponent) < tol
            && abs(x.blueComponent - y.blueComponent) < tol
            && abs(x.alphaComponent - y.alphaComponent) < tol
    }
    private func notifyToolbarColorChange() {
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
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

    @objc private func urlSchemeChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "urlSchemeEnabled")
    }

    fileprivate var urlSchemeInfoPopover: NSPopover?

    fileprivate func showURLSchemeInfoPopover(near sourceView: NSView) {
        if let existing = urlSchemeInfoPopover, existing.isShown { return }

        let commands: [(String, String)] = [
            ("macshot://capture",             L("Start area capture")),
            ("macshot://capture-fullscreen",  L("Capture the full screen")),
            ("macshot://capture-last",        L("Re-capture the last selected area")),
            ("macshot://quick-capture",       L("Quick capture (uses your Enter action)")),
            ("macshot://ocr",                 L("Capture area and extract text")),
            ("macshot://record",              L("Start area recording")),
            ("macshot://record-fullscreen",   L("Start full-screen recording")),
            ("macshot://stop-recording",      L("Stop the current recording")),
            ("macshot://scroll-capture",      L("Start scroll capture")),
            ("macshot://history",             L("Open the recent captures overlay")),
            ("macshot://settings",            L("Open this settings window")),
            ("macshot://open?file=/path.png", L("Open an image file in the editor")),
        ]

        let title = NSTextField(labelWithString: L("Supported URL Scheme Commands"))
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: L("Trigger macshot from Raycast, Alfred, Shortcuts, or any tool that opens URLs."))
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 440
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        // NSGridView for perfect column alignment — each row's cmd column and
        // desc column line up precisely regardless of text width.
        let grid = NSGridView(numberOfColumns: 2, rows: commands.count)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        for (i, entry) in commands.enumerated() {
            let cmdLabel = NSTextField(labelWithString: entry.0)
            cmdLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            cmdLabel.textColor = .labelColor
            cmdLabel.isSelectable = true

            let descLabel = NSTextField(labelWithString: entry.1)
            descLabel.font = NSFont.systemFont(ofSize: 11)
            descLabel.textColor = .secondaryLabelColor

            grid.cell(atColumnIndex: 0, rowIndex: i).contentView = cmdLabel
            grid.cell(atColumnIndex: 1, rowIndex: i).contentView = descLabel
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)
        container.addSubview(subtitle)
        container.addSubview(grid)

        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),

            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -pad),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        ])

        let vc = NSViewController()
        vc.view = container

        // Compute fitting size for the popover
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.contentSize = fitting
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        urlSchemeInfoPopover = popover
    }

    @objc private func hideMenuBarIconChanged(_ sender: NSButton) {
        let hidden = sender.state == .on
        UserDefaults.standard.set(hidden, forKey: "hideMenuBarIcon")
        (NSApp.delegate as? AppDelegate)?.setMenuBarIconVisible(!hidden)
    }

    @objc private func autoUpdateChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "SUEnableAutomaticChecks")
    }

    @objc private func betaUpdateChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "betaUpdatesEnabled")
    }

    @objc private func translationProviderChanged(_ sender: NSPopUpButton) {
        TranslationService.provider = sender.indexOfSelectedItem == 0 ? .apple : .google
    }

    @objc private func openTranslationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization.Settings.extension?Translation") {
            NSWorkspace.shared.open(url)
        }
    }

    func showWindow() {
        loadSettings()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}
