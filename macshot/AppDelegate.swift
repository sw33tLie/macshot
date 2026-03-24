import Cocoa
import Carbon
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var updaterController: SPUStandardUpdaterController!
    private var overlayControllers: [OverlayWindowController] = []
    private var preferencesController: PreferencesWindowController?
    private var onboardingController: PermissionOnboardingController?
    private var pinControllers: [PinWindowController] = []
    private var thumbnailControllers: [FloatingThumbnailController] = []
    private var ocrController: OCRResultController?
    private var historyMenu: NSMenu?
    private var historyOverlayController: HistoryOverlayController?
    private var isCapturing = false
    private var delayCountdownWindow: NSWindow?
    private var delayTimer: Timer?
    private var pendingDelaySelection: NSRect = .zero
    private var uploadToastController: UploadToastController?
    private var recordingEngine: RecordingEngine?
    private var recordingOverlayController: OverlayWindowController?
    private var scrollCaptureController: ScrollCaptureController?
    /// The overlay controller whose selection is being scroll-captured.
    private var scrollCaptureOverlayController: OverlayWindowController?

    /// Shared capture sound — loaded once, reused everywhere.
    static let captureSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        setupMainMenu()
        setupStatusBar()
        registerHotkey()

        // Pre-warm CoreAudio so the first capture sound doesn't stall ~1s.
        if let sound = Self.captureSound {
            sound.volume = 0
            sound.play()
            sound.stop()
            sound.volume = 1
        }

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

        let captureAreaItem = NSMenuItem(title: "Capture Area", action: #selector(captureScreen), keyEquivalent: "")
        captureAreaItem.target = self
        captureAreaItem.toolTip = HotkeyManager.displayString(for: .captureArea)
        menu.addItem(captureAreaItem)

        let captureFullItem = NSMenuItem(title: "Capture Screen", action: #selector(captureFullScreen), keyEquivalent: "")
        captureFullItem.target = self
        captureFullItem.toolTip = HotkeyManager.displayString(for: .captureFullScreen)
        menu.addItem(captureFullItem)

        let recordAreaItem = NSMenuItem(title: "Record Area", action: #selector(recordArea), keyEquivalent: "")
        recordAreaItem.target = self
        recordAreaItem.toolTip = HotkeyManager.displayString(for: .recordArea)
        menu.addItem(recordAreaItem)

        let recordScreenItem = NSMenuItem(title: "Record Screen", action: #selector(recordFullScreen), keyEquivalent: "")
        recordScreenItem.target = self
        recordScreenItem.toolTip = HotkeyManager.displayString(for: .recordScreen)
        menu.addItem(recordScreenItem)

        menu.addItem(NSMenuItem.separator())

        // Recent Captures submenu
        let historyItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        let historySubmenu = NSMenu()
        historySubmenu.delegate = self
        historyItem.submenu = historySubmenu
        self.historyMenu = historySubmenu
        menu.addItem(historyItem)

        let historyOverlayItem = NSMenuItem(title: "Show History Panel", action: #selector(showHistoryOverlay), keyEquivalent: "")
        historyOverlayItem.target = self
        historyOverlayItem.toolTip = HotkeyManager.displayString(for: .historyOverlay)
        menu.addItem(historyOverlayItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

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
        HotkeyManager.shared.registerAll(
            captureArea: { [weak self] in
                DispatchQueue.main.async { self?.startCapture(fromMenu: false) }
            },
            captureFullScreen: { [weak self] in
                DispatchQueue.main.async { self?.captureFullScreen() }
            },
            recordArea: { [weak self] in
                DispatchQueue.main.async { self?.recordArea() }
            },
            recordScreen: { [weak self] in
                DispatchQueue.main.async { self?.recordFullScreen() }
            },
            historyOverlay: { [weak self] in
                DispatchQueue.main.async { self?.showHistoryOverlay() }
            }
        )
    }

    private var pendingRecordMode: Bool = false
    private var pendingFullScreen: Bool = false
    private var pendingFullScreenRecord: Bool = false

    // MARK: - Capture

    @objc private func captureScreen() {
        startCapture(fromMenu: true)
    }

    @objc private func captureFullScreen() {
        pendingFullScreen = true
        startCapture(fromMenu: true)
    }

    @objc private func showHistoryOverlay() {
        // Toggle: if already showing, dismiss
        if let existing = historyOverlayController {
            existing.dismiss()
            historyOverlayController = nil
            return
        }
        let controller = HistoryOverlayController()
        controller.onDismiss = { [weak self] in
            self?.historyOverlayController = nil
        }
        controller.show()
        historyOverlayController = controller
    }

    @objc private func recordArea() {
        pendingRecordMode = true
        startCapture(fromMenu: true)
    }

    @objc private func recordFullScreen() {
        pendingFullScreenRecord = true
        startCapture(fromMenu: true)
    }

    private func startCapture(fromMenu: Bool) {
        guard !isCapturing else { return }
        isCapturing = true

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

            NSApp.activate(ignoringOtherApps: true)

            for capture in captures {
                let controller = OverlayWindowController(capture: capture)
                controller.overlayDelegate = self
                if self.pendingRecordMode {
                    controller.setAutoRecordMode()
                }
                controller.showOverlay()
                if self.pendingFullScreen || self.pendingFullScreenRecord {
                    controller.applyFullScreenSelection()
                }
                if self.pendingFullScreenRecord {
                    controller.enterRecordingMode()
                }
                self.overlayControllers.append(controller)
            }
            self.pendingRecordMode = false
            if !self.pendingFullScreen && !self.pendingFullScreenRecord {
                self.restoreLastSelectionIfNeeded(controllers: self.overlayControllers)
            }
            self.pendingFullScreen = false
            self.pendingFullScreenRecord = false
        }
    }

    private func restoreLastSelectionIfNeeded(controllers: [OverlayWindowController]) {
        guard UserDefaults.standard.bool(forKey: "rememberLastSelection") else { return }
        guard let rectStr = UserDefaults.standard.string(forKey: "lastSelectionRect"),
              let screenStr = UserDefaults.standard.string(forKey: "lastSelectionScreenFrame") else { return }
        let savedRect = NSRectFromString(rectStr)
        let savedScreenFrame = NSRectFromString(screenStr)
        guard savedRect.width > 1, savedRect.height > 1 else { return }
        // Apply to the controller whose screen matches the saved screen frame
        for controller in controllers where controller.screen.frame == savedScreenFrame {
            controller.applySelection(savedRect)
            break
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

    func showFloatingThumbnail(image: NSImage) {
        let enabled = UserDefaults.standard.object(forKey: "showFloatingThumbnail") as? Bool ?? true
        guard enabled else { return }

        let stacking = UserDefaults.standard.object(forKey: "thumbnailStacking") as? Bool ?? true
        if !stacking {
            // Replace mode: dismiss all existing thumbnails
            thumbnailControllers.forEach { $0.dismiss() }
            thumbnailControllers.removeAll()
        }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame
        let padding: CGFloat = 16
        let gap: CGFloat = 8

        // Compute Y: stack above any existing thumbnails
        var yOrigin = screenFrame.minY + padding
        if let topController = thumbnailControllers.last {
            let topFrame = topController.windowFrame
            yOrigin = topFrame.maxY + gap
        }

        let controller = FloatingThumbnailController(image: image)
        controller.onDismiss = { [weak self] in
            self?.thumbnailControllers.removeAll { $0 === controller }
            self?.reflowThumbnails()
        }
        controller.onCopy = { [weak self] in
            guard let self = self else { return }
            let autoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
            if autoCopy { ImageEncoder.copyToClipboard(image) }
            self.playCopySound()
        }
        controller.onSave = { [weak self] in
            guard let self = self else { return }
            self.saveImageToFile(image)
        }
        controller.onPin = { [weak self] in
            guard let self = self else { return }
            ScreenshotHistory.shared.add(image: image)
            self.showPin(image: image)
            self.playCopySound()
        }
        controller.onEdit = {
            DetachedEditorWindowController.open(image: image)
        }
        controller.onUpload = { [weak self] in
            guard let self = self else { return }
            ScreenshotHistory.shared.add(image: image)
            self.showUploadProgress(image: image)
        }
        thumbnailControllers.append(controller)
        controller.show(atY: yOrigin)
    }

    private func reflowThumbnails() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let padding: CGFloat = 16
        let gap: CGFloat = 8
        var y = screen.visibleFrame.minY + padding
        for c in thumbnailControllers {
            let h = c.windowFrame.height  // height doesn't change, only Y moves
            c.moveTo(y: y)
            y += h + gap
        }
    }

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        Self.captureSound?.stop()
        Self.captureSound?.play()
    }

    private func saveImageToFile(_ image: NSImage) {
        guard let imageData = ImageEncoder.encode(image) else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ImageEncoder.utType]
        savePanel.nameFieldStringValue = "macshot_\(OverlayWindowController.formattedTimestamp()).\(ImageEncoder.fileExtension)"
        savePanel.directoryURL = SaveDirectoryAccess.directoryHint()
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                SaveDirectoryAccess.save(url: url.deletingLastPathComponent())
            }
        }
    }

    // MARK: - Upload

    func uploadImage(_ image: NSImage) {
        showUploadProgress(image: image)
    }

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

        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"

        if provider == "gdrive" && !GoogleDriveUploader.shared.isSignedIn {
            toast.showError(message: "Google Drive not signed in")
            return
        }

        if provider == "gdrive" {
            GoogleDriveUploader.shared.uploadImage(image) { result in
                switch result {
                case .success(let link):
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(link, forType: .string)
                    toast.showSuccess(link: link, deleteURL: "")
                case .failure(let error):
                    toast.showError(message: error.localizedDescription)
                }
            }
        } else {
            ImageUploader.upload(image: image) { result in
                switch result {
                case .success(let uploadResult):
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(uploadResult.link, forType: .string)

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

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

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
                VideoEditorWindowController.open(url: url)
            } else if let error = error {
                #if DEBUG
                print("Recording failed: \(error.localizedDescription)")
                #endif
            }
        }
        recordingEngine = engine
        recordingOverlayController = controller

        controller.setRecordingState(isRecording: true)
        engine.startRecording(rect: rect, screen: screen)
    }

    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {
        if let engine = recordingEngine {
            engine.stopRecording()
        } else {
            // Recording mode was entered but capture never started — just dismiss
            dismissOverlays()
        }
    }

    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        scrollCaptureOverlayController = controller

        // Tell the triggering overlay to enter scroll capture mode (red border, pass-through, minimal HUD)
        controller.setScrollCaptureState(isActive: true)

        // Other overlay controllers on other screens just stay visible and normal
        // (no action needed — the scroll event monitor catches global scroll events)

        let scc = ScrollCaptureController(captureRect: rect, screen: screen)
        scc.excludedWindowIDs = overlayControllers.map { $0.windowNumber }
        scrollCaptureController = scc

        scc.onStripAdded = { [weak self, weak controller] count in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(stripCount: count, pixelSize: scc.stitchedPixelSize)
        }
        scc.onSessionDone = { [weak self] finalImage in
            self?.handleScrollCaptureCompleted(finalImage: finalImage)
        }

        Task { await scc.startSession() }
    }

    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController) {
        scrollCaptureController?.stopSession()
        // onSessionDone fires asynchronously via handleScrollCaptureCompleted
    }

    private func handleScrollCaptureCompleted(finalImage: NSImage?) {
        scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
        scrollCaptureOverlayController = nil
        scrollCaptureController = nil

        dismissOverlays()

        guard let image = finalImage else { return }

        ScreenshotHistory.shared.add(image: image)
        let autoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
        if autoCopy { ImageEncoder.copyToClipboard(image) }
        playCopySound()
        showFloatingThumbnail(image: image)
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

            NSApp.activate(ignoringOtherApps: true)

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
            Self.captureSound?.stop()
            Self.captureSound?.play()
        }
    }

    @objc private func clearHistory() {
        ScreenshotHistory.shared.clear()
    }
}
