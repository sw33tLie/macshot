import Cocoa
import Carbon
import ServiceManagement

class PreferencesWindowController: NSWindowController {

    private var hotkeyField: NSTextField!
    private var hotkeyButton: NSButton!
    private var savePathField: NSTextField!
    private var autoCopyCheckbox: NSButton!
    private var copySoundCheckbox: NSButton!
    private var thumbnailCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var historySizeField: NSTextField!
    private var historySizeStepper: NSStepper!
    private var isRecordingHotkey = false
    private var localMonitor: Any?

    var onHotkeyChanged: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 385),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "macshot Preferences"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        setupUI()
        loadPreferences()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let padding: CGFloat = 20
        var y: CGFloat = 335

        // Hotkey
        let hotkeyLabel = NSTextField(labelWithString: "Global Shortcut:")
        hotkeyLabel.frame = NSRect(x: padding, y: y, width: 120, height: 22)
        contentView.addSubview(hotkeyLabel)

        hotkeyField = NSTextField(frame: NSRect(x: 150, y: y, width: 140, height: 22))
        hotkeyField.isEditable = false
        hotkeyField.isSelectable = false
        hotkeyField.alignment = .center
        hotkeyField.backgroundColor = NSColor(white: 0.95, alpha: 1)
        contentView.addSubview(hotkeyField)

        hotkeyButton = NSButton(title: "Record", target: self, action: #selector(recordHotkey(_:)))
        hotkeyButton.frame = NSRect(x: 300, y: y, width: 90, height: 24)
        hotkeyButton.bezelStyle = .rounded
        contentView.addSubview(hotkeyButton)

        y -= 45

        // Save path
        let saveLabel = NSTextField(labelWithString: "Save Folder:")
        saveLabel.frame = NSRect(x: padding, y: y, width: 120, height: 22)
        contentView.addSubview(saveLabel)

        savePathField = NSTextField(frame: NSRect(x: 150, y: y, width: 170, height: 22))
        savePathField.isEditable = false
        savePathField.isSelectable = false
        savePathField.lineBreakMode = .byTruncatingMiddle
        contentView.addSubview(savePathField)

        let browseButton = NSButton(title: "Browse...", target: self, action: #selector(browseSavePath(_:)))
        browseButton.frame = NSRect(x: 325, y: y, width: 70, height: 24)
        browseButton.bezelStyle = .rounded
        contentView.addSubview(browseButton)

        y -= 40

        // Auto-copy
        autoCopyCheckbox = NSButton(checkboxWithTitle: "Auto-copy to clipboard on confirm", target: self, action: #selector(autoCopyChanged(_:)))
        autoCopyCheckbox.frame = NSRect(x: padding, y: y, width: 300, height: 22)
        contentView.addSubview(autoCopyCheckbox)

        y -= 35

        // Copy sound
        copySoundCheckbox = NSButton(checkboxWithTitle: "Play sound on copy", target: self, action: #selector(copySoundChanged(_:)))
        copySoundCheckbox.frame = NSRect(x: padding, y: y, width: 300, height: 22)
        contentView.addSubview(copySoundCheckbox)

        y -= 35

        // Floating thumbnail
        thumbnailCheckbox = NSButton(checkboxWithTitle: "Show floating thumbnail after capture", target: self, action: #selector(thumbnailChanged(_:)))
        thumbnailCheckbox.frame = NSRect(x: padding, y: y, width: 300, height: 22)
        contentView.addSubview(thumbnailCheckbox)

        y -= 35

        // Launch at login
        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(launchAtLoginChanged(_:)))
        launchAtLoginCheckbox.frame = NSRect(x: padding, y: y, width: 300, height: 22)
        contentView.addSubview(launchAtLoginCheckbox)

        y -= 40

        // History size
        let historyLabel = NSTextField(labelWithString: "History size:")
        historyLabel.frame = NSRect(x: padding, y: y, width: 120, height: 22)
        contentView.addSubview(historyLabel)

        historySizeField = NSTextField(frame: NSRect(x: 150, y: y, width: 40, height: 22))
        historySizeField.isEditable = false
        historySizeField.isSelectable = false
        historySizeField.alignment = .center
        historySizeField.backgroundColor = NSColor(white: 0.95, alpha: 1)
        contentView.addSubview(historySizeField)

        historySizeStepper = NSStepper(frame: NSRect(x: 194, y: y, width: 19, height: 22))
        historySizeStepper.minValue = 0
        historySizeStepper.maxValue = 50
        historySizeStepper.increment = 1
        historySizeStepper.target = self
        historySizeStepper.action = #selector(historySizeChanged(_:))
        contentView.addSubview(historySizeStepper)

        let historyNote = NSTextField(labelWithString: "screenshots kept in memory (0 = off)")
        historyNote.frame = NSRect(x: 220, y: y, width: 200, height: 22)
        historyNote.font = NSFont.systemFont(ofSize: 11)
        historyNote.textColor = .secondaryLabelColor
        contentView.addSubview(historyNote)

        // Separator
        let separator = NSBox(frame: NSRect(x: padding, y: 40, width: 380, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)

        // Footer: Made by sw33tLie + GitHub link
        let madeBy = NSTextField(labelWithString: "Made by sw33tLie")
        madeBy.frame = NSRect(x: padding, y: 12, width: 110, height: 18)
        madeBy.font = NSFont.systemFont(ofSize: 11)
        madeBy.textColor = .secondaryLabelColor
        contentView.addSubview(madeBy)

        let linkButton = NSButton(frame: NSRect(x: 130, y: 10, width: 200, height: 20))
        linkButton.title = "github.com/sw33tLie/macshot"
        linkButton.bezelStyle = .inline
        linkButton.isBordered = false
        linkButton.font = NSFont.systemFont(ofSize: 11)
        linkButton.contentTintColor = .linkColor
        linkButton.target = self
        linkButton.action = #selector(openGitHub)
        // Underline the link text
        let linkAttrs = NSMutableAttributedString(string: linkButton.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        linkButton.attributedTitle = linkAttrs
        contentView.addSubview(linkButton)
    }

    private func loadPreferences() {
        hotkeyField.stringValue = HotkeyManager.shortcutDisplayString()

        if let savePath = UserDefaults.standard.string(forKey: "saveDirectory") {
            savePathField.stringValue = savePath
        } else {
            savePathField.stringValue = "~/Desktop"
        }

        let autoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
        autoCopyCheckbox.state = autoCopy ? .on : .off

        let copySound = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        copySoundCheckbox.state = copySound ? .on : .off

        let thumbnail = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        thumbnailCheckbox.state = thumbnail ? .on : .off

        let launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        launchAtLoginCheckbox.state = launchAtLogin ? .on : .off

        let historySize = UserDefaults.standard.object(forKey: "historySize") as? Int ?? 10
        historySizeField.integerValue = historySize
        historySizeStepper.integerValue = historySize
    }

    // MARK: - Actions

    @objc private func recordHotkey(_ sender: NSButton) {
        if isRecordingHotkey {
            stopRecording()
            return
        }

        isRecordingHotkey = true
        hotkeyButton.title = "Press keys..."
        hotkeyField.stringValue = "Waiting..."

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            let modifiers = event.modifierFlags
            var carbonMods: UInt32 = 0
            if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
            if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
            if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }

            // Require at least one modifier
            if carbonMods == 0 { return nil }

            let keyCode = UInt32(event.keyCode)

            UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
            UserDefaults.standard.set(Int(carbonMods), forKey: "hotkeyModifiers")

            self.hotkeyField.stringValue = HotkeyManager.modifierString(from: carbonMods) + HotkeyManager.keyString(from: keyCode)
            self.stopRecording()
            self.onHotkeyChanged?()

            return nil // consume the event
        }
    }

    private func stopRecording() {
        isRecordingHotkey = false
        hotkeyButton.title = "Record"
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    @objc private func browseSavePath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if let currentPath = UserDefaults.standard.string(forKey: "saveDirectory") {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
        }

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.path, forKey: "saveDirectory")
            self?.savePathField.stringValue = url.path
        }
    }

    @objc private func autoCopyChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "autoCopyToClipboard")
    }

    @objc private func copySoundChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "playCopySound")
    }

    @objc private func thumbnailChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "showFloatingThumbnail")
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/sw33tLie/macshot") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func historySizeChanged(_ sender: NSStepper) {
        let value = sender.integerValue
        historySizeField.integerValue = value
        UserDefaults.standard.set(value, forKey: "historySize")
        ScreenshotHistory.shared.pruneToMax()
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "launchAtLogin")

        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update login item: \(error)")
            }
        }
    }

    func showWindow() {
        loadPreferences()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
