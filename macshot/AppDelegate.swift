import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var overlayControllers: [OverlayWindowController] = []
    private var preferencesController: PreferencesWindowController?
    private var pinControllers: [PinWindowController] = []
    private var thumbnailController: FloatingThumbnailController?
    private var ocrController: OCRResultController?
    private var historyMenu: NSMenu?
    private var isCapturing = false

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMainMenu()
        setupStatusBar()
        registerHotkey()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        HotkeyManager.shared.unregister()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Menu (required when no storyboard)

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About macshot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit macshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let symbolNames = ["camera.viewfinder", "camera.fill", "viewfinder"]
            var found = false
            for name in symbolNames {
                if let img = NSImage(systemSymbolName: name, accessibilityDescription: "macshot") {
                    img.isTemplate = true
                    button.image = img
                    found = true
                    break
                }
            }
            if !found {
                button.title = "macshot"
            }
        }

        let menu = NSMenu()

        let shortcutStr = HotkeyManager.shortcutDisplayString()
        let captureItem = NSMenuItem(title: "Capture Screen", action: #selector(captureScreen), keyEquivalent: "")
        captureItem.target = self
        captureItem.toolTip = shortcutStr
        menu.addItem(captureItem)

        menu.addItem(NSMenuItem.separator())

        // Recent Captures submenu
        let historyItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        let historySubmenu = NSMenu()
        historySubmenu.delegate = self
        historyItem.submenu = historySubmenu
        self.historyMenu = historySubmenu
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit macshot", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func refreshMenu() {
        guard let menu = statusItem.menu, let captureItem = menu.items.first else { return }
        captureItem.toolTip = HotkeyManager.shortcutDisplayString()
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        HotkeyManager.shared.register { [weak self] in
            DispatchQueue.main.async {
                self?.startCapture(fromMenu: false)
            }
        }
    }

    // MARK: - Capture

    @objc private func captureScreen() {
        startCapture(fromMenu: true)
    }

    private func startCapture(fromMenu: Bool) {
        guard !isCapturing else { return }
        isCapturing = true

        // Dismiss any existing thumbnail
        thumbnailController?.dismiss()
        thumbnailController = nil

        dismissOverlays()

        if fromMenu {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.performCapture()
            }
        } else {
            performCapture()
        }
    }

    private func performCapture() {
        ScreenCaptureManager.captureAllScreens { [weak self] captures in
            guard let self = self else { return }

            if captures.isEmpty {
                self.isCapturing = false

                let alert = NSAlert()
                alert.messageText = "Screen Recording Permission Required"
                alert.informativeText = "macshot needs screen recording permission.\n\n1. Open System Settings > Privacy & Security > Screen Recording\n2. Remove macshot from the list (toggle off or minus button)\n3. Re-add macshot and enable it\n4. Restart macshot"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")

                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                return
            }

            for capture in captures {
                let controller = OverlayWindowController(capture: capture)
                controller.overlayDelegate = self
                controller.showOverlay()
                self.overlayControllers.append(controller)
            }
        }
    }

    private func dismissOverlays() {
        autoreleasepool {
            for controller in overlayControllers {
                controller.dismiss()
            }
            overlayControllers.removeAll()
        }
        isCapturing = false
    }

    private func showFloatingThumbnail(image: NSImage) {
        let enabled = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        guard enabled else { return }

        thumbnailController?.dismiss()
        let controller = FloatingThumbnailController(image: image)
        thumbnailController = controller
        controller.show()
    }

    // MARK: - Preferences

    @objc private func openPreferences() {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
            preferencesController?.onHotkeyChanged = { [weak self] in
                self?.registerHotkey()
                self?.refreshMenu()
            }
        }
        preferencesController?.showWindow()
    }

    // MARK: - Quit

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - OverlayWindowControllerDelegate

extension AppDelegate: OverlayWindowControllerDelegate {
    func overlayDidCancel(_ controller: OverlayWindowController) {
        dismissOverlays()
    }

    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?) {
        dismissOverlays()
        if let image = capturedImage {
            ScreenshotHistory.shared.add(image: image)
            showFloatingThumbnail(image: image)
        }
    }

    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage) {
        ScreenshotHistory.shared.add(image: image)
        dismissOverlays()
        let pin = PinWindowController(image: image)
        pin.delegate = self
        pin.show()
        pinControllers.append(pin)
    }

    func overlayDidRequestOCR(_ controller: OverlayWindowController, text: String) {
        dismissOverlays()
        ocrController?.close()
        let ocr = OCRResultController(text: text)
        ocrController = ocr
        ocr.show()
    }
}

// MARK: - PinWindowControllerDelegate

extension AppDelegate: PinWindowControllerDelegate {
    func pinWindowDidClose(_ controller: PinWindowController) {
        pinControllers.removeAll { $0 === controller }
    }
}

// MARK: - NSMenuDelegate (Recent Captures)

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Only rebuild the history submenu, not the main status bar menu
        guard menu == historyMenu else { return }

        menu.removeAllItems()

        let entries = ScreenshotHistory.shared.entries
        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: "No recent captures", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
            return
        }

        for (i, entry) in entries.enumerated() {
            let title = "\(entry.pixelWidth) \u{00D7} \(entry.pixelHeight)  —  \(entry.timeAgoString)"
            let item = NSMenuItem(title: title, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.image = entry.thumbnail
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        clearItem.tag = 9000
        menu.addItem(clearItem)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        let index = sender.tag
        ScreenshotHistory.shared.copyEntry(at: index)

        // Play copy sound
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        if soundEnabled {
            let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.play()
            }
        }
    }

    @objc private func clearHistory() {
        ScreenshotHistory.shared.clear()
    }
}
