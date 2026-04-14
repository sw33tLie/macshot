import Cocoa
import Carbon
import Sparkle
import UniformTypeIdentifiers
import AVFoundation
import WebP

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {

    private var statusItem: NSStatusItem!
    private var updaterController: SPUStandardUpdaterController!
    private var overlayControllers: [OverlayWindowController] = []
    private var settingsController: SettingsWindowController?
    private var onboardingController: PermissionOnboardingController?
    private var pinControllers: [PinWindowController] = []
    private var thumbnailControllers: [FloatingThumbnailController] = []
    private var ocrController: OCRResultController?
    private var historyMenu: NSMenu?
    private var historyOverlayController: HistoryOverlayController?
    private var isCapturing = false
    private var delayCountdownWindow: NSWindow?
    private var delayTimer: Timer?
    private var delayEscMonitor: Any?
    private var uploadToastController: UploadToastController?
    private var recordingEngine: RecordingEngine?
    private var audioMergeController: AudioMergeController?
    private var recordingOverlayController: OverlayWindowController?
    private var recordingHUDPanel: RecordingHUDPanel?
    private var recordingScreenRect: NSRect = .zero  // screen-space capture rect
    private var recordingScreen: NSScreen?
    private var mouseHighlightOverlay: MouseHighlightOverlay?
    private var keystrokeOverlay: KeystrokeOverlay?
    private var webcamOverlay: WebcamOverlay?
    private var selectionBorderOverlay: SelectionBorderOverlay?
    private var menuBarIconWasHidden: Bool = false  // restore after recording if user had it hidden
    private var scrollCaptureController: ScrollCaptureController?
    /// The overlay controller whose selection is being scroll-captured.
    private var scrollCaptureOverlayController: OverlayWindowController?
    private var scrollCapturePreviewPanel: ScrollCapturePreviewPanel?
    private var statusBarMenu: NSMenu?

    /// Shared capture sound — loaded once, reused everywhere.
    static let captureSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Prevent multiple instances — if already running, activate the existing one and quit
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sw33tlie.macshot.macshot"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            // Tell the existing instance to show its icon and open Settings
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.sw33tlie.macshot.showAndOpenPrefs"),
                object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        // Offer to move to /Applications if running from a DMG or translocated path
        promptToMoveToApplicationsIfNeeded()

        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        setupMainMenu()
        setupStatusBar()
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            setMenuBarIconVisible(false)
        }
        registerHotkey()
        // Pre-warm ScreenCaptureKit so the first capture isn't slow.
        // Cache persists until display configuration changes (monitor connect/disconnect).
        ScreenCaptureManager.registerDisplayChangeHandler()
        ScreenCaptureManager.prewarm()
        // Pre-warm Core Animation / Metal pipeline so the first fullscreen
        // overlay window doesn't stall ~500ms on CA::Transaction::commit.
        let warmup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        warmup.isOpaque = false
        warmup.backgroundColor = .clear
        warmup.orderFront(nil)
        warmup.orderOut(nil)
        // Pre-warm CoreAudio so the first capture sound doesn't stall ~1s.
        if let sound = Self.captureSound {
            sound.volume = 0
            sound.play()
            sound.stop()
            sound.volume = 1
        }

        // Listen for duplicate-launch notification to restore icon
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowAndOpenPrefs),
            name: .init("com.sw33tlie.macshot.showAndOpenPrefs"), object: nil
        )

        // Dismiss overlays when the user switches spaces
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        // Pin from history panel
        NotificationCenter.default.addObserver(
            self, selector: #selector(pinFromHistory(_:)),
            name: .init("macshot.pinFromHistory"), object: nil
        )

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-launching macshot while it's running: show the menu bar icon
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
            setMenuBarIconVisible(true)
        }
        // Only open settings if no windows are visible (e.g. pure menu-bar state).
        // If editor/video editor is already open, just bring the app to the front.
        if !flag {
            openSettings()
        }
        return false
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// If the app is running from a DMG volume or a translocated path,
    /// offer to move it to /Applications for proper operation (auto-updates,
    /// persistent preferences, no translocation issues).
    private func promptToMoveToApplicationsIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        let isOnDMG = bundlePath.hasPrefix("/Volumes/")
        let isTranslocated = bundlePath.contains("/AppTranslocation/")
        guard isOnDMG || isTranslocated else { return }
        guard !UserDefaults.standard.bool(forKey: "suppressMoveToApplications") else { return }

        let alert = NSAlert()
        alert.messageText = "Move to Applications folder?"
        alert.informativeText = "macshot is running from a disk image. Move it to your Applications folder for auto-updates and best experience."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "suppressMoveToApplications")
        }
        guard response == .alertFirstButtonReturn else { return }

        let dest = URL(fileURLWithPath: "/Applications/macshot.app")
        let src = URL(fileURLWithPath: bundlePath)
        do {
            // Remove old version if present
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            // Relaunch from /Applications
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", dest.path]
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "Could not move to Applications"
            errAlert.informativeText = "Please drag macshot to your Applications folder manually.\n\n\(error.localizedDescription)"
            errAlert.runModal()
        }
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
        applyNormalStatusBarIcon()
        rebuildStatusBarMenu()
    }

    private func applyNormalStatusBarIcon() {
        if let button = statusItem.button {
            if let img = NSImage(named: "StatusBarIcon") {
                img.isTemplate = true
                img.size = NSSize(width: 22, height: 22)
                button.image = img
            } else {
                button.title = "macshot"
            }
            // Use custom click handler so we can dismiss modals before showing the menu
            button.target = self
            button.action = #selector(statusBarIconClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            (button.cell as? NSButtonCell)?.highlightsBy = .pushInCellMask
        }
    }

    @objc private func statusBarIconClicked(_ sender: NSStatusBarButton) {
        // Pre-warm ScreenCaptureKit content while the user browses the menu
        ScreenCaptureManager.prewarm()

        if let modalWin = NSApp.modalWindow {
            // Modal is active — dismiss it, then show menu after it unwinds
            NSApp.stopModal()
            modalWin.close()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let menu = self.statusBarMenu else { return }
                // Show via the standard statusItem path so it looks native (no arrow)
                self.statusItem.menu = menu
                sender.performClick(nil)
                self.statusItem.menu = nil
            }
        } else {
            // No modal — show menu normally via standard NSStatusItem path
            guard let menu = statusBarMenu else { return }
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        }
    }

    private func rebuildStatusBarMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let captureAreaItem = NSMenuItem(title: L("Capture Area"), action: #selector(captureScreen), keyEquivalent: "")
        captureAreaItem.target = self
        captureAreaItem.image = NSImage(systemSymbolName: "crop", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .captureArea, to: captureAreaItem)
        menu.addItem(captureAreaItem)

        let captureFullItem = NSMenuItem(title: L("Capture Screen"), action: #selector(captureFullScreen), keyEquivalent: "")
        captureFullItem.target = self
        captureFullItem.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .captureFullScreen, to: captureFullItem)
        menu.addItem(captureFullItem)

        let captureOCRItem = NSMenuItem(title: L("Capture OCR"), action: #selector(captureOCR), keyEquivalent: "")
        captureOCRItem.target = self
        captureOCRItem.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .captureOCR, to: captureOCRItem)
        menu.addItem(captureOCRItem)

        let quickCaptureItem = NSMenuItem(title: L("Quick Capture"), action: #selector(quickCapture), keyEquivalent: "")
        quickCaptureItem.target = self
        quickCaptureItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .quickCapture, to: quickCaptureItem)
        menu.addItem(quickCaptureItem)

        let scrollCaptureItem = NSMenuItem(title: L("Scroll Capture"), action: #selector(scrollCapture), keyEquivalent: "")
        scrollCaptureItem.target = self
        scrollCaptureItem.image = NSImage(systemSymbolName: "scroll", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .scrollCapture, to: scrollCaptureItem)
        menu.addItem(scrollCaptureItem)

        // Capture Delay submenu
        let delayItem = NSMenuItem(title: L("Capture Delay"), action: nil, keyEquivalent: "")
        delayItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let delaySubmenu = NSMenu()
        delaySubmenu.autoenablesItems = false
        let currentDelay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        for seconds in [0, 3, 5, 10, 30] {
            let title = seconds == 0 ? L("None") : String(format: L("%d seconds"), seconds)
            let item = NSMenuItem(title: title, action: #selector(setDelaySeconds(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            item.state = seconds == currentDelay ? .on : .off
            delaySubmenu.addItem(item)
        }
        delayItem.submenu = delaySubmenu
        menu.addItem(delayItem)

        menu.addItem(NSMenuItem.separator())

        let recordAreaItem = NSMenuItem(title: L("Record Area"), action: #selector(recordArea), keyEquivalent: "")
        recordAreaItem.target = self
        recordAreaItem.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .recordArea, to: recordAreaItem)
        menu.addItem(recordAreaItem)

        let recordScreenItem = NSMenuItem(title: L("Record Screen"), action: #selector(recordFullScreen), keyEquivalent: "")
        recordScreenItem.target = self
        recordScreenItem.image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .recordScreen, to: recordScreenItem)
        menu.addItem(recordScreenItem)

        menu.addItem(NSMenuItem.separator())

        // Recent Captures submenu
        let historyItem = NSMenuItem(title: L("Recent Captures"), action: nil, keyEquivalent: "")
        historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let historySubmenu = NSMenu()
        historySubmenu.delegate = self
        historyItem.submenu = historySubmenu
        self.historyMenu = historySubmenu
        menu.addItem(historyItem)

        let historyOverlayItem = NSMenuItem(title: L("Show History Panel"), action: #selector(showHistoryOverlay), keyEquivalent: "")
        historyOverlayItem.target = self
        historyOverlayItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .historyOverlay, to: historyOverlayItem)
        menu.addItem(historyOverlayItem)

        menu.addItem(NSMenuItem.separator())

        let openImageItem = NSMenuItem(title: L("Open Image..."), action: #selector(openImageFromMenu), keyEquivalent: "")
        openImageItem.target = self
        openImageItem.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        menu.addItem(openImageItem)

        let pasteImageItem = NSMenuItem(title: L("Open from Clipboard"), action: #selector(openImageFromClipboard), keyEquivalent: "")
        pasteImageItem.target = self
        pasteImageItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .openFromClipboard, to: pasteImageItem)
        menu.addItem(pasteImageItem)

        menu.addItem(NSMenuItem.separator())

        let prefsItem = NSMenuItem(title: L("Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        prefsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        menu.addItem(prefsItem)

        let updateItem = NSMenuItem(title: L("Check for Updates..."), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L("Quit macshot"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusBarMenu = menu
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
            },
            captureOCR: { [weak self] in
                DispatchQueue.main.async { self?.captureOCR() }
            },
            quickCapture: { [weak self] in
                DispatchQueue.main.async { self?.quickCapture() }
            },
            scrollCapture: { [weak self] in
                DispatchQueue.main.async { self?.scrollCapture() }
            },
            openFromClipboard: { [weak self] in
                DispatchQueue.main.async { self?.openImageFromClipboard() }
            }
        )
    }

    private var pendingRecordMode: Bool = false
    private var pendingFullScreen: Bool = false
    private var pendingFullScreenRecord: Bool = false
    private var pendingFullScreenRecordAutoStart: Bool = false
    private var pendingOCRMode: Bool = false
    private var pendingQuickCaptureMode: Bool = false
    private var pendingScrollCaptureMode: Bool = false
    private var capturedWindowTitle: String?
    /// The app that was active before the overlay appeared — re-activated on dismiss.
    /// The app that was active before macshot showed its overlay.
    private var previousApp: NSRunningApplication?

    /// True when floating thumbnails or pin windows are visible.
    var hasVisibleFloatingPanels: Bool {
        !thumbnailControllers.isEmpty || !pinControllers.isEmpty
    }

    /// Call when a macshot window closes. If no titled windows remain,
    /// switches to accessory activation policy and returns focus to
    /// the previous app (or the next regular app in line).
    func returnFocusIfNeeded() {
        let appToActivate = previousApp
        previousApp = nil
        DispatchQueue.main.async { [weak self] in
            // Don't hide the app while a recording is in progress — the HUD
            // and selection border are non-titled panels that would be killed.
            if self?.recordingEngine != nil { return }
            let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            guard !hasVisibleWindows else { return }
            NSApp.setActivationPolicy(.accessory)
            if let prev = appToActivate, !prev.isTerminated,
               prev.bundleIdentifier != Bundle.main.bundleIdentifier {
                Self.activateApp(prev)
            } else {
                // No known previous app — yield focus to whatever is frontmost.
                // Avoid NSApp.hide(nil) which can suspend the Carbon event loop
                // and break global hotkeys until the app is reactivated.
                Self.activateApp(
                    NSWorkspace.shared.runningApplications.first {
                        $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                    } ?? NSWorkspace.shared.frontmostApplication ?? NSRunningApplication.current
                )
            }
        }
    }

    /// Activate another app using the modern cooperative activation API.
    static func activateApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }

    // MARK: - Capture

    @objc private func captureScreen() {
        startCapture(fromMenu: true)
    }

    @objc private func captureFullScreen() {
        pendingFullScreen = true
        startCapture(fromMenu: true)
    }

    @objc private func showHistoryOverlay() {
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

    @objc private func captureOCR() {
        pendingOCRMode = true
        startCapture(fromMenu: true)
    }

    @objc private func quickCapture() {
        pendingQuickCaptureMode = true
        startCapture(fromMenu: true)
    }

    @objc private func scrollCapture() {
        pendingScrollCaptureMode = true
        startCapture(fromMenu: true)
    }

    @objc private func recordArea() {
        pendingRecordMode = true
        startCapture(fromMenu: true)
    }

    @objc private func recordFullScreen() {
        pendingFullScreenRecord = true
        if UserDefaults.standard.integer(forKey: "captureDelaySeconds") > 0 {
            pendingFullScreenRecordAutoStart = true
        }
        startCapture(fromMenu: true)
    }

    @objc private func setDelaySeconds(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "captureDelaySeconds")
        // Update checkmarks
        if let menu = sender.menu {
            for item in menu.items {
                item.state = item.tag == sender.tag ? .on : .off
            }
        }
    }

    private func startCapture(fromMenu: Bool = false) {
        guard !isCapturing else { return }
        // Don't allow captures while recording
        guard recordingEngine == nil else { return }
        isCapturing = true

        // Kick off SCShareableContent enumeration early — the cache will be ready
        // by the time performCapture() needs it (covers hotkey path where menu wasn't opened)
        ScreenCaptureManager.prewarm()

        // When "remember last tool" is off, clear persisted effects/beautify
        // so new OverlayView instances start clean
        let rememberTool = UserDefaults.standard.object(forKey: "rememberLastTool") as? Bool ?? true
        if !rememberTool {
            UserDefaults.standard.removeObject(forKey: "effectsPreset")
            UserDefaults.standard.removeObject(forKey: "effectsBrightness")
            UserDefaults.standard.removeObject(forKey: "effectsContrast")
            UserDefaults.standard.removeObject(forKey: "effectsSaturation")
            UserDefaults.standard.removeObject(forKey: "effectsSharpness")
            UserDefaults.standard.set(false, forKey: "beautifyEnabled")
        }

        // Grab focused app and window title before overlay steals focus
        previousApp = NSWorkspace.shared.frontmostApplication
        capturedWindowTitle = Self.focusedWindowTitle()

        // Clean up stale overlays without consuming previousApp — we just set it.
        dismissOverlays(refocusPreviousApp: false)

        // Hide floating thumbnails and flush the window server composition
        // so they don't appear in the captured screenshot.
        for tc in thumbnailControllers { tc.hideWindow() }
        CATransaction.flush()

        let delay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        if delay > 0 {
            showPreCaptureCountdown(seconds: delay)
        } else {
            // Brief delay so the window server finishes compositing thumbnail
            // removal before the screenshot is taken.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.performCapture()
            }
        }
    }

    private func showPreCaptureCountdown(seconds: Int) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 140, height: 140)
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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let countdownView = CountdownView(frame: NSRect(origin: .zero, size: size))
        countdownView.remaining = seconds
        window.contentView = countdownView
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        delayCountdownWindow = window

        // Listen for Escape to cancel countdown — use both local and global monitors
        // Local catches keys when macshot is active; global catches when another app has focus
        delayEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelPreCaptureCountdown()
                return nil
            }
            return event
        }

        var remaining = seconds
        delayTimer?.invalidate()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.delayTimer = nil
                self?.delayCountdownWindow?.orderOut(nil)
                self?.delayCountdownWindow = nil
                self?.removeDelayEscMonitors()
                self?.performCapture()
            } else {
                countdownView.remaining = remaining
                countdownView.needsDisplay = true
            }
        }
    }

    private func removeDelayEscMonitors() {
        if let m = delayEscMonitor { NSEvent.removeMonitor(m); delayEscMonitor = nil }
    }

    private func cancelPreCaptureCountdown() {
        delayTimer?.invalidate()
        delayTimer = nil
        delayCountdownWindow?.orderOut(nil)
        delayCountdownWindow = nil
        removeDelayEscMonitors()
        isCapturing = false
        pendingRecordMode = false
        pendingFullScreen = false
        pendingFullScreenRecord = false
        pendingFullScreenRecordAutoStart = false
        pendingOCRMode = false
        pendingQuickCaptureMode = false
        pendingScrollCaptureMode = false
    }

    private func performCapture() {
        // Exclude thumbnail windows as a safety net — orderOut may not be
        // composited yet. Uses cached SCShareableContent (no slow re-fetch).
        let excludeIDs = thumbnailControllers.compactMap { $0.windowNumber }
        ScreenCaptureManager.captureAllScreens(excludingWindowNumbers: excludeIDs) { [weak self] captures in
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
                controller.capturedWindowTitle = self.capturedWindowTitle
                if self.pendingRecordMode {
                    controller.setAutoRecordMode()
                }
                if self.pendingOCRMode {
                    controller.setAutoOCRMode()
                }
                if self.pendingQuickCaptureMode {
                    controller.setAutoQuickSaveMode()
                }
                if self.pendingScrollCaptureMode {
                    controller.setAutoScrollCaptureMode()
                }
                controller.showOverlay()
                let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                let isMouseScreen = (capture.screen == mouseScreen) || (mouseScreen == nil && capture.screen == NSScreen.main)
                if (self.pendingFullScreen || self.pendingFullScreenRecord) && isMouseScreen {
                    controller.applyFullScreenSelection()
                }
                if self.pendingFullScreenRecord && isMouseScreen {
                    // Enter recording mode in the overlay (shows recording toolbar)
                    controller.enterRecordingMode()
                    if self.pendingFullScreenRecordAutoStart {
                        controller.autoStartRecording()
                    }
                }
                self.overlayControllers.append(controller)
            }

            CATransaction.flush()
            NSApp.activate(ignoringOtherApps: true)

            self.pendingRecordMode = false
            self.pendingFullScreenRecordAutoStart = false
            self.pendingOCRMode = false
            self.pendingQuickCaptureMode = false
            self.pendingScrollCaptureMode = false
            if !self.pendingFullScreen && !self.pendingFullScreenRecord {
                self.restoreLastSelectionIfNeeded(controllers: self.overlayControllers)
            }
            self.pendingFullScreen = false
            self.pendingFullScreenRecord = false
        }
    }

    /// Returns the title of the frontmost window via CGWindowList (requires Screen Recording permission).
    private static func focusedWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            return name
        }
        return nil
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

    @objc private func handleShowAndOpenPrefs() {
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            UserDefaults.standard.set(false, forKey: "hideMenuBarIcon")
            setMenuBarIconVisible(true)
        }
        openSettings()
    }

    @objc private func spaceDidChange() {
        guard !overlayControllers.isEmpty else { return }
        dismissOverlays()
    }

    private func dismissOverlays(refocusPreviousApp: Bool = true) {
        autoreleasepool {
            for controller in overlayControllers {
                controller.dismiss()
            }
            overlayControllers.removeAll()
        }
        isCapturing = false
        // Restore hidden thumbnails
        for tc in thumbnailControllers { tc.showWindow() }
        if refocusPreviousApp {
            returnFocusIfNeeded()
        }
    }

    func showFloatingThumbnail(image: NSImage, annotationData: CaptureAnnotationData? = nil, historyEntryID: String? = nil) {
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
        controller.historyEntryID = historyEntryID
        controller.onDismiss = { [weak self] in
            self?.thumbnailControllers.removeAll { $0 === controller }
            self?.reflowThumbnails()
        }
        controller.onCopy = { [weak self] in
            guard let self = self else { return }
            ImageEncoder.copyToClipboard(image)
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
            if let data = annotationData {
                DetachedEditorWindowController.open(image: data.rawImage, annotations: data.annotations, historyEntryID: historyEntryID)
            } else {
                // Image already has beautify/effects baked in — disable to avoid double-applying
                DetachedEditorWindowController.open(image: image, historyEntryID: historyEntryID, disableBeautify: true)
            }
        }
        controller.onUpload = { [weak self] in
            guard let self = self else { return }
            ScreenshotHistory.shared.add(image: image)
            self.showUploadProgress(image: image)
        }
        controller.onCloseAll = { [weak self] in
            guard let self = self else { return }
            let all = self.thumbnailControllers
            self.thumbnailControllers.removeAll()
            for c in all { c.dismiss() }
        }
        controller.onSaveAll = { [weak self] in
            self?.saveAllThumbnailsToFolder()
        }
        thumbnailControllers.append(controller)
        controller.show(atY: yOrigin)
    }

    private func saveAllThumbnailsToFolder() {
        let images = thumbnailControllers.map { $0.image }
        guard !images.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose a folder to save \(images.count) screenshot\(images.count == 1 ? "" : "s")"
        panel.level = .floating

        panel.begin { [weak self] response in
            guard response == .OK, let dirURL = panel.url else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

            DispatchQueue.global(qos: .userInitiated).async {
                for (i, image) in images.enumerated() {
                    guard let data = ImageEncoder.encode(image) else { continue }
                    let timestamp = formatter.string(from: Date())
                    let filename = "Screenshot \(timestamp)-\(i + 1).\(ImageEncoder.fileExtension)"
                    let fileURL = dirURL.appendingPathComponent(filename)
                    try? data.write(to: fileURL)
                }
                DispatchQueue.main.async {
                    self?.playCopySound()
                    let all = self?.thumbnailControllers ?? []
                    self?.thumbnailControllers.removeAll()
                    for c in all { c.dismiss() }
                }
            }
        }
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

    /// Update a floating thumbnail's image if it matches the given history entry.
    func refreshThumbnail(for entryID: String, image: NSImage) {
        for tc in thumbnailControllers where tc.historyEntryID == entryID {
            tc.updateImage(image)
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

    @objc private func pinFromHistory(_ notification: Notification) {
        guard let image = notification.object as? NSImage else { return }
        showPin(image: image)
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

        if provider == "s3" && !S3Uploader.shared.isConfigured {
            toast.showError(message: "S3 not configured — check Settings")
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
        } else if provider == "s3" {
            S3Uploader.shared.onProgress = { fraction in
                toast.updateProgress(fraction)
            }
            S3Uploader.shared.uploadImage(image) { result in
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

    // MARK: - Open Image

    @objc private func openImageFromMenu() {
        openImageWithPanel()
    }

    @objc private func openImageFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard), image.isValid,
              image.size.width > 0, image.size.height > 0 else {
            let alert = NSAlert()
            alert.messageText = L("No Image on Clipboard")
            alert.informativeText = L("Copy an image to the clipboard first, then try again.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: L("OK"))
            alert.runModal()
            return
        }
        DetachedEditorWindowController.open(image: image)
    }

    private func openImageWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic, .webP, .image]
        panel.message = "Choose an image to open in macshot editor"

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                self.openImageFile(url: url)
            }
        }
    }

    private func openImageFile(url: URL) {
        let image: NSImage
        if url.pathExtension.lowercased() == "webp",
           let data = try? Data(contentsOf: url),
           let decoded = try? WebPDecoder().decode(toNSImage: data, options: WebPDecoderOptions()) {
            image = decoded
        } else if let loaded = NSImage(contentsOf: url) {
            image = loaded
        } else {
            return
        }
        DetachedEditorWindowController.open(image: image)
    }

    /// Handle files opened via Finder "Open With", drag-to-dock, or command line.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "macshot" {
                handleURLSchemeAction(url)
                continue
            }
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic", "heif", "webp", "icns"]
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            openImageFile(url: url)
        }
    }

    /// Handle macshot:// URL scheme actions from external tools (Raycast, Alfred, etc.).
    /// Usage: `open macshot://capture`, `open macshot://ocr`, etc.
    private func handleURLSchemeAction(_ url: URL) {
        guard let action = url.host else { return }
        switch action {
        case "capture":             captureScreen()
        case "capture-fullscreen":  captureFullScreen()
        case "quick-capture":       quickCapture()
        case "ocr":                 captureOCR()
        case "record":              recordArea()
        case "record-fullscreen":   recordFullScreen()
        case "scroll-capture":      scrollCapture()
        case "history":             showHistoryOverlay()
        case "settings":            openSettings()
        case "stop-recording":      stopRecording()
        case "open":
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let path = components.queryItems?.first(where: { $0.name == "file" })?.value {
                openImageFile(url: URL(fileURLWithPath: path))
            }
        default: break
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
            settingsController?.onHotkeyChanged = { [weak self] in
                self?.registerHotkey()
                self?.rebuildStatusBarMenu()
            }
        }
        settingsController?.showWindow()
    }

    // MARK: - Quit

    @objc private func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: "betaUpdatesEnabled") ? ["beta"] : []
    }
}

// MARK: - OverlayWindowControllerDelegate

extension AppDelegate: OverlayWindowControllerDelegate {
    func overlayDidCancel(_ controller: OverlayWindowController) {
        // If the user cancels while in recording setup (before capture started),
        // just dismiss. If recording is actively capturing, stop it.
        if controller === recordingOverlayController, let engine = recordingEngine {
            engine.stopRecording()
            // stopRecordingUI() will be called by onCompletion callback
        }
        dismissOverlays()

        // Focus is returned to the previous app by dismissOverlays() above.
    }

    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?) {
        dismissOverlays()
        if let image = capturedImage {
            ScreenshotHistory.shared.add(
                image: image,
                rawImage: annotationData?.rawImage,
                annotations: annotationData?.annotations)
            // The entry just added is at index 0
            let entryID = ScreenshotHistory.shared.entries.first?.id
            // Defer thumbnail to next runloop cycle so overlay teardown completes first
            // and the main thread is free for the next capture trigger
            let annData = annotationData
            DispatchQueue.main.async { [weak self] in
                self?.showFloatingThumbnail(image: image, annotationData: annData, historyEntryID: entryID)
            }

            // "Also open in Editor" preference — open with history entry ID so Done saves back
            if UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") {
                if let data = annotationData {
                    DetachedEditorWindowController.open(image: data.rawImage, annotations: data.annotations, historyEntryID: entryID)
                } else {
                    DetachedEditorWindowController.open(image: image, historyEntryID: entryID, disableBeautify: true)
                }
            }
        }
    }

    private func stitchCrossScreenCapture(primary: OverlayWindowController, others: [OverlayWindowController]) -> NSImage? {
        let primaryOrigin = primary.screen.frame.origin
        let primarySelRect = primary.selectionRect
        // Global selection rect
        let globalRect = NSRect(x: primarySelRect.origin.x + primaryOrigin.x,
                                y: primarySelRect.origin.y + primaryOrigin.y,
                                width: primarySelRect.width, height: primarySelRect.height)

        // Determine scale from primary screen
        let scale: CGFloat
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = primary.screen.backingScaleFactor
        }

        let pixelW = Int(globalRect.width * scale)
        let pixelH = Int(globalRect.height * scale)
        // Use the source image's color space to avoid expensive conversion
        let cs: CGColorSpace
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srcCS = cg.colorSpace {
            cs = srcCS
        } else {
            cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        guard let cgCtx = CGContext(data: nil, width: pixelW, height: pixelH,
                                     bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                                     space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        cgCtx.scaleBy(x: scale, y: scale)

        // Draw each screen's contribution
        let allControllers = [primary] + others
        for controller in allControllers {
            guard let screenshot = controller.screenshotImage else { continue }
            let screenFrame = controller.screen.frame
            // Where this screen sits relative to the global selection rect
            let drawX = screenFrame.origin.x - globalRect.origin.x
            let drawY = screenFrame.origin.y - globalRect.origin.y
            let drawRect = NSRect(x: drawX, y: drawY, width: screenFrame.width, height: screenFrame.height)

            cgCtx.saveGState()
            // Clip to only the portion within our output bounds
            cgCtx.clip(to: CGRect(x: 0, y: 0, width: globalRect.width, height: globalRect.height))
            let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            cgCtx.restoreGState()
        }

        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: globalRect.size)
    }

    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage) {
        ScreenshotHistory.shared.add(image: image)
        let appToRefocus = previousApp
        dismissOverlays(refocusPreviousApp: false)
        let pin = PinWindowController(image: image)
        pin.delegate = self
        pin.show()
        pinControllers.append(pin)
        // Return focus to previous app — pin stays visible (hidesOnDeactivate=false, orderFrontRegardless)
        if let app = appToRefocus, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.async { AppDelegate.activateApp(app) }
        }
    }

    func overlayDidRequestOCR(_ controller: OverlayWindowController, text: String, image: NSImage?) {
        // OCR action: 0 = window + copy (default), 1 = window only, 2 = copy only
        let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
        let shouldCopy = ocrAction == 0 || ocrAction == 2
        let shouldShowWindow = ocrAction == 0 || ocrAction == 1
        dismissOverlays(refocusPreviousApp: !shouldShowWindow)

        if shouldCopy && !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        if shouldShowWindow {
            ocrController?.close()
            let ocr = OCRResultController(text: text, image: image)
            ocrController = ocr
            ocr.show()
        }
    }

    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage) {
        ScreenshotHistory.shared.add(image: image)
        let appToRefocus = previousApp
        dismissOverlays(refocusPreviousApp: false)
        showUploadProgress(image: image)
        // Return focus — upload toast stays visible (hidesOnDeactivate=false)
        if let app = appToRefocus, !app.isTerminated, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.async { AppDelegate.activateApp(app) }
        }
    }

    func overlayDidRequestStartRecording(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        recordingScreenRect = rect
        recordingScreen = screen

        // Capture session overrides before dismissing overlays (which destroys the overlay view)
        let fpsOverride = controller.sessionRecordingFPS
        let onStopOverride = controller.sessionRecordingOnStop
        let delayOverride = controller.sessionRecordingDelay
        let hideHUD = controller.sessionHideRecordingHUD ?? UserDefaults.standard.bool(forKey: "hideRecordingHUD")

        // Detach webcam preview before dismissing overlays so we can reuse the live session
        let existingWebcam = controller.detachWebcamPreview()

        // Use the same focus return path as normal screenshot confirm:
        // dismissOverlays with refocus → returnFocusIfNeeded → NSApp.hide(nil).
        // This reliably transfers focus AND mouse event routing.
        // Then create recording UI on the next run loop — all non-activating
        // panels, so they appear without stealing focus back.
        dismissOverlays()  // refocusPreviousApp: true (default) — handles focus
        previousApp = nil

        let delay = delayOverride ?? UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if delay > 0 {
                existingWebcam?.stopPreview()
                existingWebcam?.close()
                self.startRecordingCountdown(seconds: delay, rect: rect, screen: screen,
                                        fpsOverride: fpsOverride,
                                        onStopOverride: onStopOverride)
            } else {
                self.beginRecording(rect: rect, screen: screen,
                               fpsOverride: fpsOverride,
                               onStopOverride: onStopOverride,
                               existingWebcam: existingWebcam,
                               hideHUD: hideHUD)
            }
        }
    }

    private func startRecordingCountdown(seconds: Int, rect: NSRect, screen: NSScreen,
                                          fpsOverride: Int?,
                                          onStopOverride: String?) {
        let size = NSSize(width: 140, height: 140)
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2
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

        // Show selection border during countdown so user sees what area will be recorded
        let border = SelectionBorderOverlay(screen: screen)
        border.setSelectionRect(rect)
        border.orderFrontRegardless()
        selectionBorderOverlay = border

        // Escape to cancel
        delayEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.cancelRecordingCountdown()
                return nil
            }
            return event
        }

        var remaining = seconds
        delayTimer?.invalidate()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.delayTimer = nil
                self?.delayCountdownWindow?.orderOut(nil)
                self?.delayCountdownWindow = nil
                self?.removeDelayEscMonitors()
                self?.beginRecording(rect: rect, screen: screen,
                                     fpsOverride: fpsOverride,
                                     onStopOverride: onStopOverride)
            } else {
                countdownView.remaining = remaining
                countdownView.needsDisplay = true
            }
        }
    }

    private func cancelRecordingCountdown() {
        delayTimer?.invalidate()
        delayTimer = nil
        delayCountdownWindow?.orderOut(nil)
        delayCountdownWindow = nil
        selectionBorderOverlay?.close()
        selectionBorderOverlay = nil
        removeDelayEscMonitors()
    }

    private func beginRecording(rect: NSRect, screen: NSScreen,
                                 fpsOverride: Int?,
                                 onStopOverride: String?,
                                 existingWebcam: WebcamOverlay? = nil,
                                 hideHUD: Bool = false) {
        let engine = RecordingEngine()
        engine.onProgress = { [weak self] seconds in
            self?.updateRecordingHUD(seconds: seconds)
        }
        // Capture audio settings before recording starts (they may change during)
        let hadSystemAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio")
        let hadMicAudio = UserDefaults.standard.bool(forKey: "recordMicAudio")

        engine.onCompletion = { [weak self] url, error in
            guard let self = self else { return }
            self.stopRecordingUI()

            if let url = url {
                let deliverRecording: (URL) -> Void = { [weak self] finalURL in
                    guard let self = self else { return }
                    let onStop = onStopOverride ?? UserDefaults.standard.string(forKey: "recordingOnStop") ?? "editor"
                    switch onStop {
                    case "finder":
                        NSWorkspace.shared.activateFileViewerSelecting([finalURL])
                    case "clipboard":
                        self.copyRecordingToClipboard(url: finalURL)
                    default:
                        VideoEditorWindowController.open(url: finalURL)
                    }
                }

                // Offer audio merge when both mic + system audio were recorded
                if hadSystemAudio && hadMicAudio {
                    let merger = AudioMergeController()
                    self.audioMergeController = merger
                    merger.show(url: url) { [weak self] finalURL in
                        self?.audioMergeController = nil
                        deliverRecording(finalURL)
                    }
                } else {
                    deliverRecording(url)
                }
            } else if let error = error {
                #if DEBUG
                print("Recording failed: \(error.localizedDescription)")
                #endif
            }
        }
        recordingEngine = engine

        // Always show selection border so user knows what area is being recorded
        // (may already exist from countdown — recreate to be safe)
        selectionBorderOverlay?.close()
        let border = SelectionBorderOverlay(screen: screen)
        border.setSelectionRect(rect)
        border.orderFrontRegardless()
        selectionBorderOverlay = border

        if !hideHUD {
            // Show the floating timer HUD
            let hud = RecordingHUDPanel()
            hud.update(elapsedSeconds: 0)
            hud.positionOnScreen(relativeTo: rect, screen: screen)
            hud.onStopRecording = { [weak self] in
                self?.stopRecording()
            }
            hud.onPauseRecording = { [weak self] in
                self?.recordingEngine?.pauseRecording()
            }
            hud.onResumeRecording = { [weak self] in
                self?.recordingEngine?.resumeRecording()
            }
            hud.orderFrontRegardless()
            recordingHUDPanel = hud

            engine.onPauseChanged = { [weak self] paused in
                self?.recordingHUDPanel?.setPaused(paused)
            }
        }

        // Start mouse highlight overlay if enabled (requires Input Monitoring permission)
        if UserDefaults.standard.bool(forKey: "recordMouseHighlight") && CGPreflightListenEventAccess() {
            let overlay = MouseHighlightOverlay(screen: screen)
            overlay.orderFrontRegardless()
            overlay.startMonitoring()
            mouseHighlightOverlay = overlay
        }

        // Start keystroke overlay if enabled
        if UserDefaults.standard.bool(forKey: "recordKeystroke") && KeystrokeOverlay.hasInputMonitoringPermission {
            let overlay = KeystrokeOverlay(screen: screen)
            overlay.setRecordingRect(rect)
            overlay.orderFrontRegardless()
            overlay.startMonitoring()
            keystrokeOverlay = overlay
        }

        // Start webcam overlay if enabled — reuse existing session to avoid camera restart flash
        if UserDefaults.standard.bool(forKey: "recordWebcam") &&
           AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            if let existing = existingWebcam {
                // Reuse the live preview — just lock it in place
                existing.setDraggable(false)
                existing.orderFrontRegardless()
                webcamOverlay = existing
            } else {
                let overlay = WebcamOverlay(screen: screen)
                let position = WebcamPosition(rawValue: UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight") ?? .bottomRight
                let wcSize = WebcamSize(rawValue: UserDefaults.standard.string(forKey: "webcamSize") ?? "medium") ?? .medium
                let shape = WebcamShape(rawValue: UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") ?? .circle
                overlay.configure(position: position, size: wcSize, shape: shape, recordingRect: rect)
                overlay.startPreview(deviceUID: UserDefaults.standard.string(forKey: "selectedCameraDeviceUID"))
                overlay.setDraggable(false)
                overlay.orderFrontRegardless()
                webcamOverlay = overlay
            }
        } else {
            // Webcam not enabled — clean up any detached preview
            existingWebcam?.stopPreview()
            existingWebcam?.close()
        }

        // Turn menu bar icon into a stop button (ensure it's visible even if user hid it)
        enterRecordingMenuBarMode()

        // Collect window IDs of UI chrome to exclude from the recording
        // (selection border + HUD). Webcam, mouse highlight, and keystroke
        // overlays are intentionally captured.
        var excludeIDs: [CGWindowID] = []
        if let w = selectionBorderOverlay { excludeIDs.append(CGWindowID(w.windowNumber)) }
        if let w = recordingHUDPanel { excludeIDs.append(CGWindowID(w.windowNumber)) }

        // Start recording
        engine.startRecording(rect: rect, screen: screen, fpsOverride: fpsOverride, excludeWindowNumbers: excludeIDs)
    }

    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {
        if let engine = recordingEngine {
            engine.stopRecording()
        } else {
            // Recording mode was entered but capture never started — just dismiss
            dismissOverlays()
        }
    }

    // MARK: - Recording UI

    @objc private func stopRecording() {
        guard let engine = recordingEngine else { return }
        engine.stopRecording()
    }

    private func updateRecordingHUD(seconds: Int) {
        recordingHUDPanel?.update(elapsedSeconds: seconds)
        if let screen = recordingScreen, !(recordingHUDPanel?.userHasDragged ?? false) {
            recordingHUDPanel?.positionOnScreen(relativeTo: recordingScreenRect, screen: screen)
        }
    }

    private func enterRecordingMenuBarMode() {
        menuBarIconWasHidden = UserDefaults.standard.bool(forKey: "hideMenuBarIcon")
        if menuBarIconWasHidden {
            setMenuBarIconVisible(true)
        }
        // Replace menu with a single stop action, change icon to stop symbol
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")
            button.image?.isTemplate = true
            button.image?.size = NSSize(width: 22, height: 22)
        }
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(stopRecording)
    }

    private func exitRecordingMenuBarMode() {
        applyNormalStatusBarIcon()
        rebuildStatusBarMenu()

        // Hide icon again if user had it hidden before recording
        if menuBarIconWasHidden {
            setMenuBarIconVisible(false)
            menuBarIconWasHidden = false
        }
    }

    private func copyRecordingToClipboard(url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let ext = url.pathExtension.lowercased()
        if ext == "gif", let data = try? Data(contentsOf: url) {
            // Write raw GIF data so apps can render the animation inline
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            // Also add file URL for Finder compatibility
            item.setString(url.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        } else {
            // MP4: write file URL (apps like Slack/Discord accept file drops)
            pasteboard.writeObjects([url as NSURL])
        }
        playCopySound()
    }

    private func stopRecordingUI() {
        recordingHUDPanel?.close()
        recordingHUDPanel = nil
        selectionBorderOverlay?.close()
        selectionBorderOverlay = nil
        mouseHighlightOverlay?.stopMonitoring()
        mouseHighlightOverlay?.close()
        mouseHighlightOverlay = nil
        keystrokeOverlay?.stopMonitoring()
        keystrokeOverlay?.close()
        keystrokeOverlay = nil
        webcamOverlay?.stopPreview()
        webcamOverlay?.close()
        webcamOverlay = nil
        recordingEngine = nil
        recordingOverlayController = nil
        recordingScreenRect = .zero
        recordingScreen = nil
        exitRecordingMenuBarMode()
    }

    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {
        if !AXIsProcessTrusted() {
            dismissOverlays()
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            let alert = NSAlert()
            alert.messageText = L("Accessibility Access Required")
            alert.informativeText = L("macshot needs Accessibility permission for scroll capture. Please grant access in System Settings, then try again.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Open Settings"))
            alert.addButton(withTitle: L("Cancel"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        scrollCaptureOverlayController = controller

        let scc = ScrollCaptureController(captureRect: rect, screen: screen)
        scc.excludedWindowIDs = overlayControllers.map { $0.windowNumber }
        scrollCaptureController = scc

        // Read max height for the overlay HUD progress bar
        let maxH = UserDefaults.standard.object(forKey: "scrollMaxHeight") as? Int ?? 30000

        // Tell the triggering overlay to enter scroll capture mode
        controller.setScrollCaptureState(isActive: true, maxHeight: maxH)

        // Create live preview panel if there's space beside the capture region
        let overlayLevel = 257  // matches overlay window level
        if let previewPanel = ScrollCapturePreviewPanel(captureRect: rect, screen: screen, overlayLevel: overlayLevel) {
            previewPanel.orderFront(nil)
            scrollCapturePreviewPanel = previewPanel
        }

        scc.onStripAdded = { [weak self, weak controller] count in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(
                stripCount: count, pixelSize: scc.stitchedPixelSize,
                autoScrolling: scc.autoScrollActive)
        }
        scc.onPreviewUpdated = { [weak self] image in
            self?.scrollCapturePreviewPanel?.updatePreview(image: image)
        }
        scc.onAutoScrollStarted = { [weak self, weak controller] in
            guard let self = self, let scc = self.scrollCaptureController else { return }
            controller?.updateScrollCaptureProgress(
                stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
                autoScrolling: true)
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

    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController) {
        dismissOverlays()
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        let alert = NSAlert()
        alert.messageText = L("Accessibility Access Required")
        alert.informativeText = L("macshot needs Accessibility permission to show keystrokes during recording. Please grant access in System Settings, then try again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func overlayDidRequestInputMonitoringPermission(_ controller: OverlayWindowController) {
        dismissOverlays()
        KeystrokeOverlay.requestInputMonitoringPermission()
        let alert = NSAlert()
        alert.messageText = L("Input Monitoring Required")
        alert.informativeText = L("macshot needs Input Monitoring permission to show keystrokes during recording. Please grant access in System Settings, then try again.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController) {
        guard let scc = scrollCaptureController else { return }

        // If turning on, check Accessibility permission first
        if !scc.autoScrollActive {
            if !AXIsProcessTrusted() {
                // Cancel session without delivering a result, then dismiss overlays
                scc.cancelSession()
                scrollCaptureController = nil
                scrollCapturePreviewPanel?.close()
                scrollCapturePreviewPanel = nil
                scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
                scrollCaptureOverlayController = nil
                dismissOverlays()

                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
                let alert = NSAlert()
                alert.messageText = L("Accessibility Access Required")
                alert.informativeText = L("macshot needs Accessibility permission to auto-scroll other apps. Please grant access in System Settings, then try again.")
                alert.alertStyle = .warning
                alert.addButton(withTitle: L("Open Settings"))
                alert.addButton(withTitle: L("Cancel"))
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                return
            }
        }

        scc.toggleAutoScroll()
        let autoScrolling = scc.isActive && scc.autoScrollActive
        controller.updateScrollCaptureProgress(
            stripCount: scc.stripCount, pixelSize: scc.stitchedPixelSize,
            autoScrolling: autoScrolling)
    }

    func overlayDidBeginSelection(_ controller: OverlayWindowController) {
        for other in overlayControllers where other !== controller {
            other.clearSelection()
            other.setRemoteSelection(.zero)
        }
    }

    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        for other in overlayControllers where other !== controller {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: globalRect.origin.x - otherOrigin.x,
                                   y: globalRect.origin.y - otherOrigin.y,
                                   width: globalRect.width, height: globalRect.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Update the primary screen's actual selection
        guard let primary = overlayControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else { return }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(x: globalRect.origin.x - primaryOrigin.x,
                                  y: globalRect.origin.y - primaryOrigin.y,
                                  width: globalRect.width, height: globalRect.height)
        primary.applySelection(primaryLocal)

        // Update other secondary screens (not the caller — it manages its own remoteSelectionRect during drag)
        for other in overlayControllers where other !== controller && other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: globalRect.origin.x - otherOrigin.x,
                                   y: globalRect.origin.y - otherOrigin.y,
                                   width: globalRect.width, height: globalRect.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect) {
        // Final sync after remote resize — update primary, re-sync ALL secondaries, transfer focus
        guard let primary = overlayControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else { return }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(x: globalRect.origin.x - primaryOrigin.x,
                                  y: globalRect.origin.y - primaryOrigin.y,
                                  width: globalRect.width, height: globalRect.height)
        primary.applySelection(primaryLocal)
        primary.makeKey()

        // Re-sync ALL secondary screens (including the caller) from the primary's authoritative rect
        let primarySel = primary.selectionRect
        let primaryGlobal = NSRect(x: primarySel.origin.x + primaryOrigin.x,
                                   y: primarySel.origin.y + primaryOrigin.y,
                                   width: primarySel.width, height: primarySel.height)
        for other in overlayControllers where other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: primaryGlobal.origin.x - otherOrigin.x,
                                   y: primaryGlobal.origin.y - otherOrigin.y,
                                   width: primaryGlobal.width, height: primaryGlobal.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage? {
        let others = overlayControllers.filter { $0 !== controller && $0.remoteSelectionRect.width >= 1 && $0.remoteSelectionRect.height >= 1 }
        guard !others.isEmpty else { return nil }
        return stitchCrossScreenCapture(primary: controller, others: others)
    }

    func overlayDidChangeWindowSnapState(_ controller: OverlayWindowController) {
        // Notify all other overlays to redraw (for multi-monitor setups)
        // When window snap state changes via Tab key, all overlays need to update
        // their helper text to show the new ON/OFF state
        for other in overlayControllers where other !== controller {
            other.triggerRedraw()
        }
    }

    private func handleScrollCaptureCompleted(finalImage: NSImage?) {
        scrollCapturePreviewPanel?.close()
        scrollCapturePreviewPanel = nil
        scrollCaptureOverlayController?.setScrollCaptureState(isActive: false)
        scrollCaptureOverlayController = nil
        scrollCaptureController = nil

        dismissOverlays()

        guard let image = finalImage else { return }

        ScreenshotHistory.shared.add(image: image)
        let entryID = ScreenshotHistory.shared.entries.first?.id
        // quickCaptureMode: 0=save, 1=copy, 2=both, 3=do nothing (thumbnail only)
        let mode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1
        if mode == 1 || mode == 2 {
            ImageEncoder.copyToClipboard(image)
        }
        if mode == 0 || mode == 2 {
            saveImageToFile(image)
        }
        playCopySound()
        showFloatingThumbnail(image: image)

        if UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") {
            DetachedEditorWindowController.open(image: image, historyEntryID: entryID)
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
            let emptyItem = NSMenuItem(title: L("No recent captures"), action: nil, keyEquivalent: "")
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

        let clearItem = NSMenuItem(title: L("Clear History"), action: #selector(clearHistory), keyEquivalent: "")
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
        confirmClearHistory()
    }

    /// Show a confirmation dialog before clearing all history. Reused by history panel trash button.
    func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = L("Clear History?")
        alert.informativeText = L("This will permanently delete all screenshots from history.")
        alert.addButton(withTitle: L("Clear All"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenshotHistory.shared.clear()
        }
    }
}
