import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var overlayControllers: [OverlayWindowController] = []
    private var preferencesController: PreferencesWindowController?
    private var onboardingController: PermissionOnboardingController?
    private var pinControllers: [PinWindowController] = []
    private var thumbnailController: FloatingThumbnailController?
    private var ocrController: OCRResultController?
    private var historyMenu: NSMenu?
    private var isCapturing = false
    private var delayCountdownWindow: NSWindow?
    private var delayTimer: Timer?
    private var pendingDelaySelection: NSRect = .zero
    private var uploadToastController: UploadToastController?
    private var recordingEngine: RecordingEngine?
    private var recordingOverlayController: OverlayWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupMainMenu()
        setupStatusBar()
        registerHotkey()

        // Check screen recording permission. If not yet granted, show the
        // custom onboarding window instead of letting macOS throw its own dialogs.
        PermissionOnboardingController.checkPermissionSync { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                self.showOnboarding()
            }
        }
    }

    private func showOnboarding() {
        // If already open, just bring it to front
        if let existing = onboardingController {
            existing.show()
            return
        }
        let oc = PermissionOnboardingController()
        oc.onPermissionGranted = { [weak self] in
            self?.onboardingController = nil
        }
        onboardingController = oc
        oc.show()
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
            if let img = NSImage(named: "StatusBarIcon") {
                img.isTemplate = true
                img.size = NSSize(width: 26, height: 26)
                button.image = img
            } else {
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
                // Permission was revoked or never granted — show onboarding instead of a generic alert
                self.showOnboarding()
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
        controller.onDismiss = { [weak self] in
            self?.thumbnailController = nil
        }
        thumbnailController = controller
        controller.show()
    }

    // MARK: - Upload

    /// Public entry point used by DetachedEditorWindowController.
    func uploadImage(_ image: NSImage) {
        showUploadProgress(image: image)
    }

    /// Public entry point used by DetachedEditorWindowController.
    func showPin(image: NSImage) {
        let pin = PinWindowController(image: image)
        pin.delegate = self
        pin.show()
        pinControllers.append(pin)
    }

    private func showUploadProgress(image: NSImage) {
        uploadToastController?.dismiss()
        let toast = UploadToastController()
        uploadToastController = toast
        toast.onDismiss = { [weak self] in
            self?.uploadToastController = nil
        }
        toast.show(status: "Uploading...")

        ImageUploader.upload(image: image) { result in
            switch result {
            case .success(let uploadResult):
                // Copy link to clipboard
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(uploadResult.link, forType: .string)

                // Store delete URL in UserDefaults for future deletion
                var uploads = UserDefaults.standard.array(forKey: "imgbbUploads") as? [[String: String]] ?? []
                uploads.append([
                    "deleteURL": uploadResult.deleteURL,
                    "link": uploadResult.link,
                ])
                UserDefaults.standard.set(uploads, forKey: "imgbbUploads")

                toast.showSuccess(link: uploadResult.link, deleteURL: uploadResult.deleteURL)
            case .failure(let error):
                toast.showError(message: error.localizedDescription)
            }
        }
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

    func overlayDidRequestOCR(_ controller: OverlayWindowController, text: String, image: NSImage?) {
        dismissOverlays()
        ocrController?.close()
        let ocr = OCRResultController(text: text, image: image)
        ocrController = ocr
        ocr.show()
    }

    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage) {
        ScreenshotHistory.shared.add(image: image)
        dismissOverlays()
        showUploadProgress(image: image)
    }

    func overlayDidRequestDelayCapture(_ controller: OverlayWindowController, seconds: Int, selectionRect: NSRect) {
        pendingDelaySelection = selectionRect
        dismissOverlays()
        startDelayCountdown(seconds: seconds)
    }

    func overlayDidRequestStartRecording(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        let engine = RecordingEngine()
        engine.onProgress = { [weak controller] seconds in
            controller?.updateRecordingProgress(seconds: seconds)
        }
        engine.onCompletion = { [weak self] url, error in
            guard let self = self else { return }
            self.dismissOverlays()
            self.recordingEngine = nil
            self.recordingOverlayController = nil

            if let url = url {
                self.showRecordingCompletedToast(url: url)
            } else if let error = error {
                print("Recording failed: \(error.localizedDescription)")
            }
        }
        recordingEngine = engine
        recordingOverlayController = controller

        controller.setRecordingState(isRecording: true)
        engine.startRecording(rect: rect, screen: screen)
    }

    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {
        recordingEngine?.stopRecording()
    }

    private func showRecordingCompletedToast(url: URL) {
        let onStop = UserDefaults.standard.string(forKey: "recordingOnStop") ?? "finder"
        if onStop == "finder" {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        let size = NSSize(width: 320, height: 60)
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + 60
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating + 1
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = RecordingToastView(frame: NSRect(origin: .zero, size: size), url: url)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        // Auto-dismiss after 6 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak window] in
            window?.orderOut(nil)
        }
    }

    private func startDelayCountdown(seconds: Int) {
        // Create a floating countdown window centered on screen
        let size = NSSize(width: 120, height: 120)
        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let countdownView = CountdownView(frame: NSRect(origin: .zero, size: size))
        countdownView.remaining = seconds
        window.contentView = countdownView
        window.makeKeyAndOrderFront(nil)
        delayCountdownWindow = window

        var remaining = seconds
        delayTimer?.invalidate()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.delayTimer = nil
                self?.delayCountdownWindow?.orderOut(nil)
                self?.delayCountdownWindow = nil
                self?.performDelayedCapture()
            } else {
                countdownView.remaining = remaining
                countdownView.needsDisplay = true
            }
        }
    }

    private func performDelayedCapture() {
        let savedRect = pendingDelaySelection
        isCapturing = true

        ScreenCaptureManager.captureAllScreens { [weak self] captures in
            guard let self = self else { return }

            if captures.isEmpty {
                self.isCapturing = false
                return
            }

            for capture in captures {
                let controller = OverlayWindowController(capture: capture)
                controller.overlayDelegate = self
                controller.showOverlay()
                // Restore the selection region
                controller.applySelection(savedRect)
                self.overlayControllers.append(controller)
            }
        }
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
            item.image = ScreenshotHistory.shared.loadThumbnail(for: entry)
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
