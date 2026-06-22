import Cocoa
import Carbon
import Sparkle
import UniformTypeIdentifiers
import AVFoundation
import Vision
import WebP

enum CaptureMenuItemID: String, CaseIterable {
    case captureArea = "captureArea"
    case captureScreen = "captureScreen"
    case captureOCR = "captureOCR"
    case quickCapture = "quickCapture"
    case captureLastArea = "captureLastArea"
    case scrollCapture = "scrollCapture"

    static let userDefaultsKey = "captureMenuItemOrder"
    static let defaultOrder: [CaptureMenuItemID] = [
        .captureArea,
        .captureScreen,
        .captureOCR,
        .quickCapture,
        .captureLastArea,
        .scrollCapture,
    ]

    var title: String {
        switch self {
        case .captureArea: return L("Capture Area")
        case .captureScreen: return L("Capture Screen")
        case .captureOCR: return L("Capture OCR & QR")
        case .quickCapture: return L("Quick Capture")
        case .captureLastArea: return L("Capture Last Area")
        case .scrollCapture: return L("Scroll Capture")
        }
    }

    var symbolName: String {
        switch self {
        case .captureArea: return "crop"
        case .captureScreen: return "desktopcomputer"
        case .captureOCR: return "text.viewfinder"
        case .quickCapture: return "square.and.arrow.down"
        case .captureLastArea: return "arrow.counterclockwise.circle"
        case .scrollCapture: return "scroll"
        }
    }

    var hotkeySlot: HotkeyManager.HotkeySlot {
        switch self {
        case .captureArea: return .captureArea
        case .captureScreen: return .captureFullScreen
        case .captureOCR: return .captureOCR
        case .quickCapture: return .quickCapture
        case .captureLastArea: return .captureLastArea
        case .scrollCapture: return .scrollCapture
        }
    }

    static func orderedItems(defaults: UserDefaults = .standard) -> [CaptureMenuItemID] {
        let saved = defaults.stringArray(forKey: userDefaultsKey) ?? []
        var result: [CaptureMenuItemID] = []
        for rawValue in saved {
            guard let item = CaptureMenuItemID(rawValue: rawValue), !result.contains(item) else { continue }
            result.append(item)
        }
        for item in defaultOrder where !result.contains(item) {
            result.append(item)
        }
        return result
    }

    static func saveOrder(_ items: [CaptureMenuItemID], defaults: UserDefaults = .standard) {
        let sanitized = items.filter { defaultOrder.contains($0) }
        let completed = sanitized + defaultOrder.filter { !sanitized.contains($0) }
        defaults.set(completed.map(\.rawValue), forKey: userDefaultsKey)
    }

    static func resetOrder(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: userDefaultsKey)
    }
}

import os.log

private let timingLog = OSLog(subsystem: "com.sw33tlie.macshot.macshot", category: "capture-timing")

// MARK: - Signal-safe diagnostic logging

/// Async-signal-safe write(2)-only log fd for Jetsam/SIGTERM diagnostics.
/// Opened at launch in `AppDelegate.setupSignalHandlers()` and written to
/// by `sigtermHandler` when the system sends SIGTERM before SIGKILL.
private var macshotSignalLogFd: Int32 = -1

/// Async-signal-safe SIGTERM handler. Writes a one-line diagnostic to the
/// pre-opened `macshotSignalLogFd`, then resets the handler to default and
/// re-raises so `applicationWillTerminate` runs the normal cleanup path.
private let sigtermHandler: @convention(c) (Int32) -> Void = { _ in
    guard macshotSignalLogFd >= 0 else {
        signal(SIGTERM, SIG_DFL)
        return
    }
    // Only async-signal-safe operations below.
    let msg: StaticString = "SIGTERM received — likely Jetsam memory-pressure kill\n"
    _ = write(macshotSignalLogFd, msg.utf8Start, msg.utf8CodeUnitCount)
    _ = close(macshotSignalLogFd)
    macshotSignalLogFd = -1
    // Re-raise with default handler so applicationWillTerminate runs.
    signal(SIGTERM, SIG_DFL)
    kill(getpid(), SIGTERM)
}

private final class CaptureTimingTrace: @unchecked Sendable {
    private struct Entry {
        let label: String
        let elapsed: TimeInterval
        let delta: TimeInterval
        let thread: String
    }

    private let lock = NSLock()
    private let startTime: CFAbsoluteTime
    private var lastTime: CFAbsoluteTime
    private var entries: [Entry] = []

    init(startAbsoluteTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        self.startTime = startAbsoluteTime
        self.lastTime = startAbsoluteTime
        os_log("=== TRACE START ===", log: timingLog, type: .info)
    }

    func mark(_ label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let entry = Entry(
            label: label,
            elapsed: now - startTime,
            delta: now - lastTime,
            thread: Thread.isMainThread ? "main" : "bg")
        entries.append(entry)
        lastTime = now
        lock.unlock()
        os_log("%{public}.1fms (+%{public}.1f) [%{public}@] %{public}@",
               log: timingLog, type: .info,
               entry.elapsed * 1000, entry.delta * 1000, entry.thread, label)
    }

    func measure<T>(_ label: String, _ work: () -> T) -> T {
        mark("\(label) begin")
        let result = work()
        mark("\(label) end")
        return result
    }

    func report(finalLabel: String) -> String {
        mark(finalLabel)

        lock.lock()
        let snapshot = entries
        lock.unlock()

        let total = snapshot.last?.elapsed ?? 0
        var lines: [String] = []
        lines.append("macshot capture timing — total: \(Self.format(total))")
        lines.append("")
        lines.append(" elapsed    delta  thread  event")
        lines.append("-----------------------------------------------")
        for entry in snapshot {
            lines.append(String(
                format: "%8.1f  %7.1f  %-6@  %@",
                entry.elapsed * 1000,
                entry.delta * 1000,
                entry.thread as NSString,
                entry.label as NSString))
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ interval: TimeInterval) -> String {
        String(format: "%.1f ms", interval * 1000)
    }
}

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
    private var captureSessionID: UInt = 0
    private var captureTimingTrace: CaptureTimingTrace?
    /// App Nap suppression assertion. Held for the app's lifetime so global
    /// hotkeys respond instantly instead of paying a wake-up penalty when
    /// macshot has been idle. Use the idle-sleep-safe variant: plain
    /// `.userInitiated` creates a `PreventUserIdleSystemSleep` assertion and
    /// keeps Macs awake indefinitely.
    private var appNapAssertion: NSObjectProtocol?

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

        // Disable App Nap. macshot is LSUIElement with no visible windows
        // when idle, so macOS can add wake-up latency to global hotkey
        // captures. The "allowing idle system sleep" variant keeps the
        // responsiveness hint without creating a PreventUserIdleSystemSleep
        // assertion that blocks normal sleep.
        appNapAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Global hotkey responsiveness")

        // Open a signal-safe log fd and register the SIGTERM handler.
        // When macOS Jetsam kills the process, any SIGTERM sent before
        // SIGKILL is captured here, and the re-raise ensures
        // applicationWillTerminate also fires — giving us two diagnostic
        // traces to distinguish Jetsam kills from normal termination.
        setupSignalHandlers()

        // Offer to move to /Applications if running from a DMG or translocated path
        promptToMoveToApplicationsIfNeeded()

        migrateFilenameTemplateIfNeeded()

        // Touch the clipboard tmp dir early so it adopts any leftover file
        // BEFORE the sweep runs — otherwise the sweeper might delete the
        // leftover while the adoption code was about to claim it, and we'd
        // end up with a stale `currentClipboardFileURL` pointing at nothing.
        _ = ImageEncoder.clipboardTmpDirectory

        // Reclaim disk from stale tmp leftovers (cancelled recordings,
        // legacy clipboard PNGs, share-sheet scratch). Runs off the main
        // thread so it can't delay launch.
        LaunchCleanup.runAll()

        // Force-init the history singleton so its launch-time orphan
        // prune runs even if the user doesn't take a screenshot this
        // session. Without this, the prune only fires the first time
        // something references ScreenshotHistory.shared.
        _ = ScreenshotHistory.shared

        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        // Disable silent update downloads — updates should only apply
        // via explicit user action ("Check for Updates..." / Install),
        // so an automatic update can't be mistaken for a silent crash.
        updaterController.updater.automaticallyDownloadsUpdates = false
        setupMainMenu()
        setupStatusBar()
        if UserDefaults.standard.bool(forKey: "hideMenuBarIcon") {
            setMenuBarIconVisible(false)
        }
        registerHotkey()
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
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
            if granted {
                self.prewarmCapturePath()
            } else {
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
            self?.prewarmCapturePath()
        }
        onboardingController = oc
        oc.show()
    }

    private func prewarmCapturePath() {
        // Warm the SCShareableContent cache (cheap, async).
        ScreenCaptureManager.prewarm()
        // Build (or rebuild) the per-screen overlay controller pool. Each
        // controller owns a permanent NSPanel; on hotkey we reuse it rather
        // than creating fresh. This is what keeps captures fast — WindowServer
        // caches composition state per-window, and reused windows stay hot.
        rebuildOverlayPool()
    }

    /// Persistent per-screen overlay controller pool. Held for the app's
    /// lifetime so each panel's CGSWindow stays alive in WindowServer.
    /// Rebuilt on screen-config change.
    private var overlayControllerPool: [ObjectIdentifier: OverlayWindowController] = [:]

    private func rebuildOverlayPool() {
        // Tear down stale controllers (screens removed, etc.) before rebuilding.
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        for screen in NSScreen.screens {
            let controller = OverlayWindowController(screen: screen)
            overlayControllerPool[ObjectIdentifier(screen)] = controller
            // Warm the panel: brief invisible orderFront so WindowServer
            // allocates the surface + composes one frame. This is what the
            // first real capture would otherwise pay.
            controller.warmPanel()
        }
    }

    private func pooledController(for screen: NSScreen) -> OverlayWindowController {
        if let existing = overlayControllerPool[ObjectIdentifier(screen)] {
            return existing
        }
        // New screen showed up between prewarms — create on demand.
        let controller = OverlayWindowController(screen: screen)
        overlayControllerPool[ObjectIdentifier(screen)] = controller
        controller.warmPanel()
        return controller
    }

    @objc private func systemDidWake() {
        guard !isCapturing, recordingEngine == nil else { return }
        prewarmCapturePath()
    }

    @objc private func screenParametersDidChange() {
        guard !isCapturing, recordingEngine == nil else { return }
        prewarmCapturePath()
    }

    /// Captured at the very start of every hotkey callback (before main thread
    /// dispatch hop). Lets the trace include runloop wake-up delay that
    /// happens BEFORE startCapture runs.
    var pendingCaptureEntryTime: CFAbsoluteTime?

    private func makeCaptureTimingTrace() -> CaptureTimingTrace? {
        let start = pendingCaptureEntryTime ?? CFAbsoluteTimeGetCurrent()
        pendingCaptureEntryTime = nil
        // Always-on while we hunt the cold-hotkey latency bug.
        return CaptureTimingTrace(startAbsoluteTime: start)
    }

    private func measureCaptureTiming<T>(_ label: String, _ work: () -> T) -> T {
        if let trace = captureTimingTrace {
            return trace.measure(label, work)
        }
        return work()
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

    /// Dock menu shown on right-click of the Dock icon.
    ///
    /// macOS only auto-populates the Dock menu's window list for document-based
    /// apps (apps using `NSDocumentController`). Our editor windows aren't
    /// documents, so we build the list ourselves: each visible titled window
    /// gets an entry that brings that specific window forward when clicked.
    /// Without this users only see "Show All Windows" and can't jump directly
    /// to a particular editor session.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let windows = NSApp.windows.filter {
            $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
        }
        guard !windows.isEmpty else { return nil }
        let menu = NSMenu()
        // Sort by title so the menu order is stable across dock-menu openings.
        for window in windows.sorted(by: { $0.title < $1.title }) {
            let item = NSMenuItem(
                title: window.title.isEmpty ? L("Untitled") : window.title,
                action: #selector(activateWindowFromDockMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = window
            if window.isMiniaturized {
                // Visual cue so users know clicking will also de-minimize.
                item.state = .mixed
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func activateWindowFromDockMenu(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One-shot migration from the legacy `useWindowTitleInFilename` checkbox
    /// to the new `filenameTemplate` string. Runs once — seeds the template
    /// from the old bool then clears the legacy key.
    private func migrateFilenameTemplateIfNeeded() {
        let d = UserDefaults.standard
        guard d.object(forKey: FilenameFormatter.userDefaultsKey) == nil else { return }
        let hadWindowTitle = d.bool(forKey: "useWindowTitleInFilename")
        let template = hadWindowTitle
            ? "Screenshot {date} at {time} — {window}"
            : FilenameFormatter.defaultTemplate
        d.set(template, forKey: FilenameFormatter.userDefaultsKey)
        d.removeObject(forKey: "useWindowTitleInFilename")
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
        os_log(.fault, log: timingLog, "macshot terminating — thermalState=%d", ProcessInfo.processInfo.thermalState.rawValue)
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
        HotkeyManager.shared.unregister()
        if macshotSignalLogFd >= 0 {
            close(macshotSignalLogFd)
            macshotSignalLogFd = -1
        }
    }

    // MARK: - Signal Handlers

    /// Opens a write-only log fd and registers the SIGTERM handler.
    /// The fd is used by the signal handler (which can only call
    /// async-signal-safe functions; os_log is NOT safe in that context).
    private func setupSignalHandlers() {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/macshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logPath = logDir.appendingPathComponent("termination.log")
        macshotSignalLogFd = open(logPath.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        signal(SIGTERM, sigtermHandler)
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

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyNormalStatusBarIcon()
        rebuildStatusBarMenu()
    }

    // User-customizable menu bar icon (see Settings → General → Appearance).
    // Mode is "default" (bundled StatusBarIcon asset) or "symbol" (a user-chosen SF Symbol).
    static let statusBarIconModeKey = "statusBarIconMode"
    static let statusBarIconSymbolNameKey = "statusBarIconSymbolName"

    private func applyNormalStatusBarIcon() {
        if let button = statusItem.button {
            applyPreferredIconImage(to: button)
            // Use the NATIVE status-item menu (no custom click action). Showing
            // the menu by synthesizing a click from the button's mouse-down
            // action re-enters AppKit's mouse-tracking loop and can hang the main
            // thread (which also kills the global hotkey). The menu's delegate
            // handles modal dismissal + prewarm in menuWillOpen instead.
            button.target = nil
            button.action = nil
            statusItem.menu = statusBarMenu
        }
    }

    /// Sets the button image/title from the user's icon preference. "symbol" mode renders
    /// the chosen SF Symbol as a 22pt template image; anything else — including an empty or
    /// invalid symbol name — falls back to the bundled icon so the item is never blank.
    private func applyPreferredIconImage(to button: NSStatusBarButton) {
        let mode = UserDefaults.standard.string(forKey: Self.statusBarIconModeKey) ?? "default"
        let symbolName = UserDefaults.standard.string(forKey: Self.statusBarIconSymbolNameKey) ?? ""

        if mode == "symbol", !symbolName.isEmpty,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "macshot") {
            symbol.isTemplate = true
            symbol.size = NSSize(width: 22, height: 22)
            button.image = symbol
            button.title = ""
        } else if let img = NSImage(named: "StatusBarIcon") {
            img.isTemplate = true
            img.size = NSSize(width: 22, height: 22)
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "macshot"
        }
    }

    /// Re-applies the menu bar icon to reflect the user's current preference. Invoked live
    /// from Settings so changes take effect without a relaunch. No-op while recording — the
    /// recording state owns the icon then and restores the preferred one when it ends.
    func refreshStatusBarIcon() {
        guard recordingEngine == nil, let button = statusItem.button else { return }
        applyPreferredIconImage(to: button)
    }

    private func rebuildStatusBarMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for itemID in CaptureMenuItemID.orderedItems() {
            menu.addItem(makeCaptureMenuItem(itemID))
        }

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

        let openVideoItem = NSMenuItem(title: L("Open Video..."), action: #selector(openVideoFromMenu), keyEquivalent: "")
        openVideoItem.target = self
        openVideoItem.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        menu.addItem(openVideoItem)

        let pasteImageItem = NSMenuItem(title: L("Open from Clipboard"), action: #selector(openImageFromClipboard), keyEquivalent: "")
        pasteImageItem.target = self
        pasteImageItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: .openFromClipboard, to: pasteImageItem)
        menu.addItem(pasteImageItem)

        let pinClipboardTitle = L("Pin from Clipboard")
        let pinClipboardItem = NSMenuItem(title: pinClipboardTitle, action: #selector(pinFromClipboard), keyEquivalent: "")
        pinClipboardItem.target = self
        pinClipboardItem.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: pinClipboardTitle)
        HotkeyManager.applyMenuShortcut(for: .pinFromClipboard, to: pinClipboardItem)
        menu.addItem(pinClipboardItem)

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

        menu.delegate = self  // menuWillOpen dismisses any modal + prewarms capture
        statusBarMenu = menu
        // Re-attach to the status item unless we're in recording mode (which owns
        // the icon and uses a custom stop action with no menu).
        if recordingEngine == nil {
            statusItem?.menu = menu
        }
    }

    private func makeCaptureMenuItem(_ itemID: CaptureMenuItemID) -> NSMenuItem {
        let action: Selector
        switch itemID {
        case .captureArea: action = #selector(captureScreen)
        case .captureScreen: action = #selector(captureFullScreen)
        case .captureOCR: action = #selector(captureOCR)
        case .quickCapture: action = #selector(quickCapture)
        case .captureLastArea: action = #selector(captureLastArea)
        case .scrollCapture: action = #selector(scrollCapture)
        }

        let item = NSMenuItem(title: itemID.title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: itemID.symbolName, accessibilityDescription: nil)
        HotkeyManager.applyMenuShortcut(for: itemID.hotkeySlot, to: item)
        return item
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        // Stamp entry time at the very FIRST instruction of each callback so
        // any runloop wake-up cost before startCapture is attributed.
        let stamp: () -> Void = { [weak self] in
            let now = CFAbsoluteTimeGetCurrent()
            self?.pendingCaptureEntryTime = now
            os_log("HOTKEY CALLBACK FIRED at abs=%{public}.6f", log: timingLog, type: .info, now)
        }
        HotkeyManager.shared.registerAll(
            captureArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureScreenFromHotkey))
            },
            captureFullScreen: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureFullScreenFromHotkey))
            },
            recordArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.recordAreaFromHotkey))
            },
            recordScreen: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.recordFullScreenFromHotkey))
            },
            historyOverlay: { [weak self] in
                DispatchQueue.main.async { self?.showHistoryOverlay() }
            },
            captureOCR: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureOCRFromHotkey))
            },
            quickCapture: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.quickCaptureFromHotkey))
            },
            scrollCapture: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.scrollCaptureFromHotkey))
            },
            openFromClipboard: { [weak self] in
                DispatchQueue.main.async { self?.openImageFromClipboard() }
            },
            captureLastArea: { [weak self] in
                stamp()
                self?.perform(#selector(AppDelegate.captureLastAreaFromHotkey))
            },
            pinFromClipboard: { [weak self] in
                DispatchQueue.main.async { self?.pinFromClipboard() }
            },
            clearHistory: { [weak self] in
                DispatchQueue.main.async { self?.clearHistorySilently() }
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

    /// Titled macshot windows (editors, preferences, Sparkle, etc.) that were
    /// visible when capture started. We `orderOut` them so `NSApp.activate`
    /// during capture can't drag them in front of the user's frontmost app,
    /// then `orderFront` them when the overlay dismisses. Kept in the order
    /// they appeared so restoring preserves relative z-order.
    private var stashedBackgroundWindows: [NSWindow] = []

    /// True when floating thumbnails or pin windows are visible.
    var hasVisibleFloatingPanels: Bool {
        !thumbnailControllers.isEmpty || !pinControllers.isEmpty
    }

    /// Call when a macshot window closes. If no titled windows remain,
    /// switches to accessory activation policy and returns focus to
    /// the previous app (or the next regular app in line).
    func returnFocusIfNeeded() {
        captureTimingTrace?.mark("returnFocusIfNeeded entered")
        let appToActivate = previousApp
        previousApp = nil
        DispatchQueue.main.async { [weak self] in
            // Don't hide the app while a recording is in progress — the HUD
            // and selection border are non-titled panels that would be killed.
            if self?.recordingEngine != nil { return }
            let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            // Windows we hid for the screenshot count as "visible" for
            // activation-policy purposes — they're coming back as soon as
            // the previous app regains focus, so we mustn't downgrade.
            let hasStashedWindows = !(self?.stashedBackgroundWindows.isEmpty ?? true)
            guard !hasVisibleWindows else { return }
            if !hasStashedWindows {
                NSApp.setActivationPolicy(.accessory)
            }
            if let prev = appToActivate, !prev.isTerminated,
               prev.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.captureTimingTrace?.mark("activate previous app")
                Self.activateApp(prev)
            } else {
                // No known previous app — yield focus to whatever is frontmost.
                // Avoid NSApp.hide(nil) which can suspend the Carbon event loop
                // and break global hotkeys until the app is reactivated.
                self?.captureTimingTrace?.mark("activate fallback app")
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
        beginCaptureArea(fromMenu: true)
    }

    @objc private func captureScreenFromHotkey() {
        beginCaptureArea(fromMenu: false)
    }

    private func beginCaptureArea(fromMenu: Bool) {
        startCapture(fromMenu: fromMenu)
    }

    @objc private func captureFullScreen() {
        beginCaptureFullScreen(fromMenu: true)
    }

    @objc private func captureFullScreenFromHotkey() {
        beginCaptureFullScreen(fromMenu: false)
    }

    private func beginCaptureFullScreen(fromMenu: Bool) {
        pendingFullScreen = true
        startCapture(fromMenu: fromMenu)
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
        beginCaptureOCR(fromMenu: true)
    }

    @objc private func captureOCRFromHotkey() {
        beginCaptureOCR(fromMenu: false)
    }

    private func beginCaptureOCR(fromMenu: Bool) {
        pendingOCRMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func quickCapture() {
        beginQuickCapture(fromMenu: true)
    }

    @objc private func quickCaptureFromHotkey() {
        beginQuickCapture(fromMenu: false)
    }

    private func beginQuickCapture(fromMenu: Bool) {
        pendingQuickCaptureMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func scrollCapture() {
        beginScrollCapture(fromMenu: true)
    }

    @objc private func scrollCaptureFromHotkey() {
        beginScrollCapture(fromMenu: false)
    }

    private func beginScrollCapture(fromMenu: Bool) {
        pendingScrollCaptureMode = true
        startCapture(fromMenu: fromMenu)
    }

    /// Open the capture overlay with the last selection area pre-applied.
    /// If no previous selection exists, falls back to a normal capture.
    @objc private func captureLastArea() {
        beginCaptureLastArea(fromMenu: true)
    }

    @objc private func captureLastAreaFromHotkey() {
        beginCaptureLastArea(fromMenu: false)
    }

    private func beginCaptureLastArea(fromMenu: Bool) {
        pendingRestoreLastArea = true
        startCapture(fromMenu: fromMenu)
    }
    private var pendingRestoreLastArea: Bool = false

    @objc private func recordArea() {
        beginRecordArea(fromMenu: true)
    }

    @objc private func recordAreaFromHotkey() {
        beginRecordArea(fromMenu: false)
    }

    private func beginRecordArea(fromMenu: Bool) {
        pendingRecordMode = true
        startCapture(fromMenu: fromMenu)
    }

    @objc private func recordFullScreen() {
        beginRecordFullScreen(fromMenu: true)
    }

    @objc private func recordFullScreenFromHotkey() {
        beginRecordFullScreen(fromMenu: false)
    }

    private func beginRecordFullScreen(fromMenu: Bool) {
        pendingFullScreenRecord = true
        if UserDefaults.standard.integer(forKey: "captureDelaySeconds") > 0 {
            pendingFullScreenRecordAutoStart = true
        }
        startCapture(fromMenu: fromMenu)
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
        let trace = makeCaptureTimingTrace()
        captureTimingTrace = trace
        trace?.mark("startCapture entered fromMenu=\(fromMenu)")
        isCapturing = true
        captureSessionID &+= 1
        let sessionID = captureSessionID
        trace?.mark("capture session created id=\(sessionID)")
        previousApp = NSWorkspace.shared.frontmostApplication
        trace?.mark("frontmost application captured")
        capturedWindowTitle = nil
        let focusedWindowPID = previousApp?.processIdentifier
        resolveFocusedWindowTitleAsync(for: focusedWindowPID, sessionID: sessionID)

        // When "remember last tool" is off, clear persisted effects/beautify
        // so new OverlayView instances start clean.
        let rememberTool = UserDefaults.standard.object(forKey: "rememberLastTool") as? Bool ?? true
        if !rememberTool {
            OverlayView.resetRememberedTool()
            UserDefaults.standard.removeObject(forKey: "effectsPreset")
            UserDefaults.standard.removeObject(forKey: "effectsBrightness")
            UserDefaults.standard.removeObject(forKey: "effectsContrast")
            UserDefaults.standard.removeObject(forKey: "effectsSaturation")
            UserDefaults.standard.removeObject(forKey: "effectsSharpness")
            UserDefaults.standard.set(false, forKey: "beautifyEnabled")
        }

        // Clean up stale overlays without consuming previousApp — we just set it.
        measureCaptureTiming("dismiss stale overlays") {
            dismissOverlays(refocusPreviousApp: false)
        }
        isCapturing = true

        // Hide non-overlay titled windows so they don't end up in the screenshot.
        // Restored in dismissOverlays once capture is over.
        measureCaptureTiming("stash background windows") {
            stashBackgroundWindows()
        }

        // Hide floating thumbnails so they don't appear in the captured image.
        measureCaptureTiming("hide thumbnails before capture") {
            for tc in thumbnailControllers { tc.hideWindow() }
        }

        let delay = UserDefaults.standard.integer(forKey: "captureDelaySeconds")
        trace?.mark("capture delay read delay=\(delay)")

        if delay > 0 {
            captureTimingTrace?.mark("showPreCaptureCountdown requested")
            showPreCaptureCountdown(seconds: delay)
            return
        }

        performCapture(fromMenu: fromMenu)
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
                self?.performCapture(fromMenu: false)
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
        pendingRestoreLastArea = false
    }

    private func performCapture(fromMenu: Bool) {
        captureTimingTrace?.mark("performCapture entered fromMenu=\(fromMenu)")
        let screens = measureCaptureTiming("NSScreen.screens") {
            NSScreen.screens
        }
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = screens.first { $0.frame.contains(mouseLocation) }

        // Kick off the screenshot capture on a background queue. Window
        // creation runs on main concurrently — both costs are paid in parallel.
        // CGWindowListCreateImage is used because it preserves transient UI
        // (menu extras, app menus, Raycast-style panels) that disappears once
        // anything steals focus. Overlay windows haven't been ordered-front yet
        // so they won't appear in the capture.
        let captureContext = measureCaptureTiming("makeImmediateCaptureContext") {
            ScreenCaptureManager.makeImmediateCaptureContext()
        }
        let trace = captureTimingTrace
        let sessionID = captureSessionID

        // Pull (don't construct) overlay controllers from the persistent pool.
        // Each controller's NSPanel was created and warmed at launch / pool
        // rebuild, so WindowServer's per-window cache is already hot.
        var controllers: [OverlayWindowController] = []
        for screen in screens {
            let controller = measureCaptureTiming("acquire pooled overlay") {
                pooledController(for: screen)
            }
            controller.overlayDelegate = self
            if let trace = captureTimingTrace {
                controller.timingMark = { label in trace.mark(label) }
            }
            controller.capturedWindowTitle = capturedWindowTitle
            if pendingRecordMode { controller.setAutoRecordMode() }
            if pendingOCRMode { controller.setAutoOCRMode() }
            if pendingQuickCaptureMode { controller.setAutoQuickSaveMode() }
            if pendingScrollCaptureMode { controller.setAutoScrollCaptureMode() }
            controllers.append(controller)
        }
        overlayControllers.append(contentsOf: controllers)

        pendingRecordMode = false
        let didApplyFullScreenRecord = pendingFullScreenRecord
        let didApplyFullScreenRecordAutoStart = pendingFullScreenRecordAutoStart
        let didApplyFullScreen = pendingFullScreen
        pendingFullScreenRecordAutoStart = false
        pendingOCRMode = false
        pendingQuickCaptureMode = false
        pendingScrollCaptureMode = false
        pendingFullScreen = false
        pendingFullScreenRecord = false

        // Run the screenshot capture now and dispatch back to main when done.
        // Window creation above already ran in parallel with the prep that the
        // background work still has to do.
        //
        // Prefer SCScreenshotManager: it honors the "Capture mouse cursor"
        // toggle even for the enlarged shake-to-find / accessibility cursor,
        // which CGWindowListCreateImage cannot exclude (the cursor is a
        // WindowServer layer, not a window). On macOS 26+, use the rect-based
        // screenshot API to avoid SCShareableContent enumeration in the hot
        // path. Older SCK fallback still fetches fresh shareable content so
        // transient UI (menus, Spotlight) is preserved. If SCK fails or can't
        // cover every display, fall back to the synchronous CGWindowListCreateImage
        // path (which manually composites the cursor from the prebuilt context).
        Task { [weak self] in
            trace?.mark("background screenshot begin")
            var captures: [ScreenCapture]? = nil
            if #available(macOS 14.0, *) {
                captures = await ScreenCaptureManager.captureAllScreensImmediatelySCK(
                    timing: { label in trace?.mark(label) })
            }
            let finalCaptures = captures ?? ScreenCaptureManager.captureAllScreensImmediately(
                context: captureContext,
                timing: { label in trace?.mark(label) })
            trace?.mark("background screenshot end count=\(finalCaptures.count)")
            await MainActor.run {
                guard let self = self, self.isCapturing,
                      self.captureSessionID == sessionID else { return }
                self.installAndShowOverlays(
                    captures: finalCaptures,
                    controllers: controllers,
                    mouseScreen: mouseScreen,
                    applyFullScreen: didApplyFullScreen,
                    applyFullScreenRecord: didApplyFullScreenRecord,
                    autoStartRecord: didApplyFullScreenRecordAutoStart)
            }
        }
    }

    /// Install screenshots into the pre-built overlay controllers and order
    /// them front. This is the single moment the overlay becomes visible.
    private func installAndShowOverlays(
        captures: [ScreenCapture],
        controllers: [OverlayWindowController],
        mouseScreen: NSScreen?,
        applyFullScreen: Bool,
        applyFullScreenRecord: Bool,
        autoStartRecord: Bool
    ) {
        if captures.isEmpty {
            captureTimingTrace?.mark("no captures returned — bailing out")
            dismissOverlays(refocusPreviousApp: true)
            showOnboarding()
            return
        }

        let capturesByScreen = Dictionary(uniqueKeysWithValues: captures.map { ($0.screen, $0.image) })

        for controller in controllers {
            if let image = capturesByScreen[controller.screen] {
                measureCaptureTiming("set screenshot") {
                    controller.setScreenshot(image)
                }
            }
            measureCaptureTiming("show overlay") {
                controller.showOverlay()
            }
            let isMouseScreen = (controller.screen == mouseScreen)
                || (mouseScreen == nil && controller.screen == NSScreen.main)
            if (applyFullScreen || applyFullScreenRecord) && isMouseScreen {
                measureCaptureTiming("apply full screen selection") {
                    controller.applyFullScreenSelection()
                }
            }
            if applyFullScreenRecord && isMouseScreen {
                controller.enterRecordingMode()
                if autoStartRecord {
                    controller.autoStartRecording()
                }
            }
        }

        captureTimingTrace?.mark("overlays installed and shown — INTERACTIVE")
        // Beacon: schedule periodic main-runloop marks so we can see if the
        // runloop is alive between INTERACTIVE and the first user event.
        // Fires every 50ms for 3 seconds, then auto-cancels.
        if let trace = captureTimingTrace {
            let report = trace.report(finalLabel: "INTERACTIVE-checkpoint")
            os_log("=== TRACE @ INTERACTIVE ===\n%{public}@", log: timingLog, type: .info, report)
            startRunloopBeacon()
        }
        applyPendingRestoredSelectionIfNeeded()
    }

    private var runloopBeaconTimer: Timer?
    private func startRunloopBeacon() {
        stopRunloopBeacon()
        var ticks = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            ticks += 1
            self?.captureTimingTrace?.mark("BEACON tick=\(ticks)")
            if ticks >= 60 {  // 3 seconds
                t.invalidate()
                self?.runloopBeaconTimer = nil
            }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        runloopBeaconTimer = timer
    }
    private func stopRunloopBeacon() {
        runloopBeaconTimer?.invalidate()
        runloopBeaconTimer = nil
    }

    private func applyPendingRestoredSelectionIfNeeded() {
        guard pendingRestoreLastArea else { return }
        pendingRestoreLastArea = false
        restoreLastSelection(controllers: overlayControllers)
    }

    /// Apply the stored last selection rect to the matching overlay controller.
    private func restoreLastSelection(controllers: [OverlayWindowController]) {
        guard let rectStr = UserDefaults.standard.string(forKey: "lastSelectionRect"),
              let screenStr = UserDefaults.standard.string(forKey: "lastSelectionScreenFrame") else { return }
        let savedRect = NSRectFromString(rectStr)
        let savedScreenFrame = NSRectFromString(screenStr)
        guard savedRect.width > 1, savedRect.height > 1 else { return }
        for controller in controllers where controller.screen.frame == savedScreenFrame {
            controller.applySelection(savedRect)
            break
        }
    }

    /// Returns the title of the frontmost window via CGWindowList (requires Screen Recording permission).
    nonisolated private static func focusedWindowTitle(forPID pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    private func resolveFocusedWindowTitleAsync(for pid: pid_t?, sessionID: UInt) {
        guard let pid = pid else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let title = Self.focusedWindowTitle(forPID: pid)
            DispatchQueue.main.async {
                guard let self = self, self.isCapturing, self.captureSessionID == sessionID else { return }
                self.capturedWindowTitle = title
                for controller in self.overlayControllers {
                    controller.capturedWindowTitle = title
                }
            }
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
        captureTimingTrace?.mark("dismissOverlays entered refocus=\(refocusPreviousApp)")
        autoreleasepool {
            for controller in overlayControllers {
                controller.dismiss()
            }
            overlayControllers.removeAll()
        }
        captureTimingTrace?.mark("overlay controllers dismissed")
        isCapturing = false
        // Restore hidden thumbnails
        measureCaptureTiming("restore thumbnails") {
            for tc in thumbnailControllers { tc.showWindow() }
        }
        if refocusPreviousApp {
            // Restore AFTER another app takes focus so the stashed windows
            // come back behind it instead of on top. See
            // `scheduleBackgroundWindowRestore` for the timing logic.
            captureTimingTrace?.mark("schedule focus restore")
            scheduleBackgroundWindowRestore()
            returnFocusIfNeeded()
        } else {
            // No focus switch coming — just bring them back immediately.
            captureTimingTrace?.mark("restore background windows immediately")
            restoreBackgroundWindowsNow()
        }
        captureTimingTrace?.mark("dismissOverlays completed")
        if refocusPreviousApp, let trace = captureTimingTrace {
            let report = trace.report(finalLabel: "OVERLAY DISMISSED")
            os_log("=== FINAL TRACE ===\n%{public}@", log: timingLog, type: .info, report)
            Self.appendTimingReport(report)
            captureTimingTrace = nil
        }
    }

    /// Path to the rolling timing log inside the sandbox container.
    /// Real path on disk:
    ///   ~/Library/Containers/com.sw33tlie.macshot.macshot/Data/Library/Application Support/macshot/timing.log
    static let timingLogURL: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("macshot", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timing.log")
    }()

    /// Append a timing report to the rolling log file. Each entry is prefixed
    /// with a wall-clock timestamp so cold vs warm runs are easy to compare.
    /// Runs synchronously on whatever queue calls it — file writes are fast.
    static func appendTimingReport(_ report: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "\n========== \(ts) ==========\n\(report)\n"
        let url = timingLogURL
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                if let data = entry.data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            } else {
                try entry.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            os_log("appendTimingReport failed: %{public}@", log: timingLog, type: .error, "\(error)")
        }
    }

    /// Hide non-overlay titled macshot windows so they can't be dragged in
    /// front of the user's frontmost app when the overlay activates.
    ///
    /// We only stash when another app was frontmost — that means the user is
    /// trying to screenshot something *other than* macshot, and any macshot
    /// windows still on screen are unintended background clutter. When
    /// macshot itself is frontmost the user presumably wants to capture one
    /// of its own windows, so we leave everything alone.
    private func stashBackgroundWindows() {
        stashedBackgroundWindows.removeAll()
        let ourBundleID = Bundle.main.bundleIdentifier
        let macshotWasFrontmost = previousApp?.bundleIdentifier == ourBundleID
        guard !macshotWasFrontmost else { return }
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            stashedBackgroundWindows.append(window)
            window.orderOut(nil)
        }
    }

    /// Wait until another app becomes frontmost, then restore the stashed
    /// windows. If we restore before the user's previous app regains focus,
    /// the windows come back on top and clobber whatever was frontmost.
    ///
    /// Uses NSWorkspace's activation notification as the trigger, with a
    /// short timer fallback in case activation never completes (e.g. the
    /// previous app terminated during capture).
    private func scheduleBackgroundWindowRestore() {
        guard !stashedBackgroundWindows.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        var token: NSObjectProtocol?
        token = ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                if let token = token { ws.removeObserver(token) }
                self.restoreBackgroundWindowsNow()
            }
        }
        // Fallback — if no other app ever activates in the next 1s just
        // restore anyway. Otherwise the windows would stay invisible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            if !self.stashedBackgroundWindows.isEmpty {
                if let token = token { ws.removeObserver(token) }
                self.restoreBackgroundWindowsNow()
            }
        }
    }

    /// Reverse of `stashBackgroundWindows`. Uses `orderBack` instead of
    /// `orderFront` so the restored windows land behind every other
    /// app's windows rather than on top of them. (`orderFront` still
    /// raises windows in the global z-stack even when the owning app
    /// isn't frontmost, which is what was causing the editor to pop
    /// visible right after a screenshot.)
    private func restoreBackgroundWindowsNow() {
        for window in stashedBackgroundWindows {
            window.orderBack(nil)
        }
        stashedBackgroundWindows.removeAll()
    }

    private func finishCaptureTimingReport(_ finalLabel: String) -> String? {
        #if DEBUG
        guard let trace = captureTimingTrace else { return nil }
        let report = trace.report(finalLabel: finalLabel)
        captureTimingTrace = nil
        return report
        #else
        captureTimingTrace = nil
        return nil
        #endif
    }

    private func showCaptureTimingDialog(_ report: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Capture Timing"
        alert.informativeText = "Timing for the last screenshot capture."
        alert.addButton(withTitle: "OK")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = report
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.runModal()
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
        let corner = thumbnailCorner()
        let thumbSize = FloatingThumbnailController.currentThumbnailSize()
        let xOrigin = thumbnailX(for: thumbSize.width, in: screenFrame, corner: corner, padding: padding)

        // Compute Y: bottom corners stack upward, top corners stack downward.
        var yOrigin = corner.isTop ? screenFrame.maxY - thumbSize.height - padding : screenFrame.minY + padding
        if let topController = thumbnailControllers.last {
            let topFrame = topController.windowFrame
            yOrigin = corner.isTop ? topFrame.minY - thumbSize.height - gap : topFrame.maxY + gap
        }

        let controller = FloatingThumbnailController(image: image)
        controller.historyEntryID = historyEntryID
        controller.annotationData = annotationData
        controller.onDismiss = { [weak self] in
            self?.thumbnailControllers.removeAll { $0 === controller }
            self?.reflowThumbnails()
        }
        controller.onCopy = { [weak controller] in
            guard let image = controller?.image else { return }
            ImageEncoder.copyToClipboard(image)
        }
        controller.onSave = { [weak self, weak controller] in
            guard let self = self, let image = controller?.image else { return }
            self.saveThumbnailImage(image)
        }
        controller.onSaveAs = { [weak self, weak controller] in
            guard let self = self, let image = controller?.image else { return }
            self.saveThumbnailImageAs(image)
        }
        controller.onPin = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            let image = controller.image
            let data = controller.annotationData
            ScreenshotHistory.shared.add(
                image: image,
                rawImage: data?.rawImage,
                annotations: data?.annotations,
                editState: data?.editState
            )
            self.showPin(image: image)
        }
        controller.onEdit = { [weak controller] in
            guard let controller else { return }
            let image = controller.image
            let id = controller.historyEntryID ?? historyEntryID
            if let data = controller.annotationData {
                DetachedEditorWindowController.open(
                    image: data.rawImage,
                    annotations: data.annotations,
                    historyEntryID: id,
                    editState: data.editState
                )
                return
            }
            if let id,
               let entry = ScreenshotHistory.shared.entries.first(where: { $0.id == id }),
               let rawImage = ScreenshotHistory.shared.loadRawImage(for: entry),
               let annotations = ScreenshotHistory.shared.loadAnnotations(for: entry) {
                let editState = ScreenshotHistory.shared.loadEditState(for: entry)
                DetachedEditorWindowController.open(
                    image: rawImage,
                    annotations: annotations,
                    historyEntryID: id,
                    editState: editState
                )
                return
            }
            // Image already has beautify/effects baked in — disable to avoid double-applying
            DetachedEditorWindowController.open(image: image, historyEntryID: id, disableBeautify: true)
        }
        controller.onUpload = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            let image = controller.image
            let data = controller.annotationData
            ScreenshotHistory.shared.add(
                image: image,
                rawImage: data?.rawImage,
                annotations: data?.annotations,
                editState: data?.editState
            )
            self.showUploadProgress(image: image)
        }
        controller.onTransform = { transformed in
            if let id = historyEntryID {
                ScreenshotHistory.shared.updateEntry(id: id, compositedImage: transformed, rawImage: nil, annotations: nil)
            }
        }
        controller.onOCR = { [weak self, weak controller] in
            guard let image = controller?.image else { return }
            self?.runOCR(on: image)
        }
        controller.onDelete = {
            if let id = historyEntryID {
                ScreenshotHistory.shared.removeEntry(id: id)
            }
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
        controller.show(at: NSPoint(x: xOrigin, y: yOrigin), corner: corner)
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

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            panel.begin { [weak self] response in
                guard response == .OK, let dirURL = panel.url else { return }
                let rawTemplate = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
                // Ensure batch writes don't collide when the template lacks {index}.
                let template = rawTemplate.contains("{index}") ? rawTemplate : "\(rawTemplate)-{index}"
                let batchDate = Date()

                DispatchQueue.global(qos: .userInitiated).async {
                    for (i, image) in images.enumerated() {
                        guard let data = ImageEncoder.encode(image) else { continue }
                        let base = FilenameFormatter.format(template: template, index: i + 1, date: batchDate)
                        let filename = "\(base).\(ImageEncoder.fileExtension)"
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
    }

    private func reflowThumbnails() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let padding: CGFloat = 16
        let gap: CGFloat = 8
        let frame = screen.visibleFrame
        let corner = thumbnailCorner()
        var y = corner.isTop ? frame.maxY - padding : frame.minY + padding
        for c in thumbnailControllers {
            let size = c.windowFrame.size
            let x = thumbnailX(for: size.width, in: frame, corner: corner, padding: padding)
            let yOrigin: CGFloat
            if corner.isTop {
                y -= size.height
                yOrigin = y
                y -= gap
            } else {
                yOrigin = y
                y += size.height + gap
            }
            c.moveTo(origin: NSPoint(x: x, y: yOrigin))
        }
    }

    private func thumbnailCorner() -> FloatingThumbnailCorner {
        let rawValue = UserDefaults.standard.string(forKey: "thumbnailCorner") ?? FloatingThumbnailCorner.bottomRight.rawValue
        return FloatingThumbnailCorner(rawValue: rawValue) ?? .bottomRight
    }

    private func thumbnailX(
        for width: CGFloat,
        in frame: NSRect,
        corner: FloatingThumbnailCorner,
        padding: CGFloat
    ) -> CGFloat {
        corner.isLeft ? frame.minX + padding : frame.maxX - width - padding
    }

    /// Update a floating thumbnail's image if it matches the given history entry.
    func refreshThumbnail(for entryID: String, image: NSImage, annotationData: CaptureAnnotationData? = nil) {
        for tc in thumbnailControllers where tc.historyEntryID == entryID {
            tc.updateImage(image, annotationData: annotationData)
        }
    }

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        Self.captureSound?.stop()
        Self.captureSound?.play()
    }

    func runOCR(on image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextAndQRCodeRecognition(cgImage: cgImage) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
                    let shouldCopy = ocrAction == 0 || ocrAction == 2
                    let shouldShowWindow = ocrAction == 0 || ocrAction == 1

                    if shouldCopy && !result.copyText.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.copyText, forType: .string)
                    }

                    if shouldShowWindow {
                        self.ocrController?.close()
                        let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
                        self.ocrController = ocr
                        ocr.show()
                    }
                }
            }
        }
    }

    private func saveThumbnailImage(_ image: NSImage) {
        ImageSaveService.save(image, panelLevel: .floating, activateApp: true) { [weak self] success in
            if success {
                self?.playCopySound()
            }
        }
    }

    private func saveThumbnailImageAs(_ image: NSImage) {
        ImageSaveService.showSavePanel(for: image, panelLevel: .floating, activateApp: true) { [weak self] success in
            if success {
                self?.playCopySound()
            }
        }
    }

    private func saveImageToConfiguredFolder(_ image: NSImage) {
        ImageSaveService.saveToConfiguredFolder(image, panelLevel: .floating, activateApp: true)
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

    @objc private func pinFromClipboard() {
        guard let item = NSPasteboard.general.pasteboardItems?.first else {
            showNoPinClipboardContentAlert()
            return
        }

        switch ClipboardPinService.image(from: item) {
        case .image(let image):
            showPin(image: image)
        case .unsupported:
            showNoPinClipboardContentAlert()
        }
    }

    private func showNoPinClipboardContentAlert() {
        let alert = NSAlert()
        alert.messageText = L("No Image or Text on Clipboard")
        alert.informativeText = L("Copy an image or text to the clipboard first, then try again.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
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

    // MARK: - Open Video

    @objc private func openVideoFromMenu() {
        openVideoWithPanel()
    }

    private func openVideoWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie, .video, .gif]
        panel.message = L("Choose a video to open in macshot editor")

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                self.openVideoFile(url: url)
            }
        }
    }

    private func openVideoFile(url: URL) {
        // Never let the editor delete the user's source file on close.
        VideoEditorWindowController.open(url: url, deleteOnClose: false)
    }

    /// Handle files opened via Finder "Open With", drag-to-dock, or command line.
    func application(_ application: NSApplication, open urls: [URL]) {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic", "heif", "webp", "icns"]
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
        for url in urls {
            if url.scheme == "macshot" {
                let urlSchemeEnabled = UserDefaults.standard.object(forKey: "urlSchemeEnabled") as? Bool ?? true
                guard urlSchemeEnabled else { continue }
                handleURLSchemeAction(url)
                continue
            }
            let ext = url.pathExtension.lowercased()
            // GIFs can be opened in either the image editor or the video
            // editor. Default to image editor (matches prior behavior) — users
            // wanting to trim a GIF use "Open Video..." explicitly.
            if imageExtensions.contains(ext) {
                openImageFile(url: url)
            } else if videoExtensions.contains(ext) {
                openVideoFile(url: url)
            }
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
        case "capture-last":        captureLastArea()
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
        captureTimingTrace?.mark("overlayDidConfirm entered image=\(capturedImage != nil)")
        dismissOverlays()
        captureTimingTrace?.mark("overlayDidConfirm after dismissOverlays")
        if let image = capturedImage {
            ScreenshotHistory.shared.add(
                image: image,
                rawImage: annotationData?.rawImage,
                annotations: annotationData?.annotations,
                editState: annotationData?.editState)
            captureTimingTrace?.mark("screenshot added to history")
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
                    DetachedEditorWindowController.open(
                        image: data.rawImage,
                        annotations: data.annotations,
                        historyEntryID: entryID,
                        editState: data.editState
                    )
                } else {
                    DetachedEditorWindowController.open(image: image, historyEntryID: entryID, disableBeautify: true)
                }
            }

            if let report = finishCaptureTimingReport("timing report generated") {
                DispatchQueue.main.async { [weak self] in
                    self?.showCaptureTimingDialog(report)
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
            cs = CGColorSpace(name: CGColorSpace.sRGB)!
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

    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?) {
        ScreenshotHistory.shared.add(
            image: image,
            rawImage: annotationData?.rawImage,
            annotations: annotationData?.annotations,
            editState: annotationData?.editState
        )
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

    func overlayDidRequestOCR(_ controller: OverlayWindowController, result: OCRScanResult, image: NSImage?) {
        // OCR & QR action: 0 = window + copy (default), 1 = window only, 2 = copy only
        let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
        let shouldCopy = ocrAction == 0 || ocrAction == 2
        let shouldShowWindow = ocrAction == 0 || ocrAction == 1
        dismissOverlays(refocusPreviousApp: !shouldShowWindow)

        if shouldCopy && !result.copyText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.copyText, forType: .string)
        }

        if shouldShowWindow {
            ocrController?.close()
            let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
            ocrController = ocr
            ocr.show()
        }
    }

    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?) {
        ScreenshotHistory.shared.add(
            image: image,
            rawImage: annotationData?.rawImage,
            annotations: annotationData?.annotations,
            editState: annotationData?.editState
        )
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
                        // Move the recording out of our sandbox tmp to a
                        // user-visible directory before revealing. Otherwise
                        // Finder would open inside the sandbox container
                        // (confusing to navigate, and our launch sweep can't
                        // safely clean tmp Recordings since they look
                        // user-managed).
                        self.revealRecordingInFinder(tmpURL: finalURL)
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

    /// Move a recording out of our sandbox tmp to a user-visible directory
    /// and reveal it in Finder. Used by the `recordingOnStop = "finder"`
    /// flow so the user doesn't end up staring at a deep sandbox path.
    ///
    /// Resolution order:
    ///   1. Recording save directory (if configured + bookmark still valid)
    ///   2. Same as screenshots (if configured + bookmark still valid)
    ///   3. Save panel — user picks a location explicitly
    ///
    /// On a collision at the destination, we append " (N)" to the filename
    /// so nothing gets silently overwritten.
    private func revealRecordingInFinder(tmpURL: URL) {
        // Try the configured recording dir first.
        if let recDir = SaveDirectoryAccess.resolveRecordingDirectoryIfAccessible() {
            defer { SaveDirectoryAccess.stopAccessing(url: recDir) }
            if let moved = moveRecording(from: tmpURL, intoDirectory: recDir) {
                NSWorkspace.shared.activateFileViewerSelecting([moved])
                return
            }
        }
        // Fall back to the general screenshot save directory if THAT has a
        // valid security-scoped bookmark (without one we have no sandbox write
        // access). resolveIfAccessible() returns nil precisely in that case.
        if let screenshotDir = SaveDirectoryAccess.resolveIfAccessible() {
            defer { SaveDirectoryAccess.stopAccessing(url: screenshotDir) }
            if let moved = moveRecording(from: tmpURL, intoDirectory: screenshotDir) {
                NSWorkspace.shared.activateFileViewerSelecting([moved])
                return
            }
        }
        // No usable saved location — prompt the user via NSSavePanel.
        promptToSaveRecording(tmpURL: tmpURL)
    }

    /// Move `src` into `dir`, renaming on collision, returning the new URL.
    /// Returns nil if the move fails (bad permissions, disk full, etc.).
    private func moveRecording(from src: URL, intoDirectory dir: URL) -> URL? {
        let fm = FileManager.default
        let name = src.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var dest = dir.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: dest.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            dest = dir.appendingPathComponent(newName)
            counter += 1
            if counter > 1000 { return nil }  // sanity cap
        }
        do {
            try fm.moveItem(at: src, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Last-resort: the user has no configured save dir, so ask them where
    /// to put the recording. On cancel we leave the tmp file in place —
    /// the launch sweep won't touch it (Recording prefix is preserved)
    /// but the user can still deal with it manually if they want.
    private func promptToSaveRecording(tmpURL: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tmpURL.lastPathComponent
        panel.title = L("Save Recording")
        panel.prompt = L("Save")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.moveItem(at: tmpURL, to: dest)) != nil {
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
    }

    private func copyRecordingToClipboard(url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Move the recording to a fixed clipboard path so we only ever have
        // one-per-extension on disk. The user's recording tmp at `url` would
        // otherwise linger forever (the pasteboard keeps the file URL
        // reference so we can't delete it; but we can overwrite the same
        // fixed path on the next clipboard copy).
        let ext = url.pathExtension.lowercased()
        let fixedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-clipboard-recording.\(ext)")
        try? FileManager.default.removeItem(at: fixedURL)
        let pasteURL: URL
        if (try? FileManager.default.moveItem(at: url, to: fixedURL)) != nil {
            pasteURL = fixedURL
        } else {
            // Move failed (cross-volume? permissions?) — fall back to the
            // original path. Launch sweep will still clean it up later.
            pasteURL = url
        }

        if ext == "gif", let data = try? Data(contentsOf: pasteURL) {
            // Write raw GIF data so apps can render the animation inline
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            // Also add file URL for Finder compatibility
            item.setString(pasteURL.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        } else {
            // MP4: write file URL (apps like Slack/Discord accept file drops)
            pasteboard.writeObjects([pasteURL as NSURL])
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
        captureTimingTrace?.mark("user began selection")
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
            saveImageToConfiguredFolder(image)
        }
        playCopySound()
        showFloatingThumbnail(image: image)

        if UserDefaults.standard.bool(forKey: "quickCaptureOpenEditor") {
            DetachedEditorWindowController.open(image: image, historyEntryID: entryID, disableBeautify: true)
        }
    }

}

// MARK: - PinWindowControllerDelegate

extension AppDelegate: PinWindowControllerDelegate {
    func pinWindowDidClose(_ controller: PinWindowController) {
        pinControllers.removeAll { $0 === controller }
    }
}

// MARK: - NSMenuDelegate (status bar menu + Recent Captures submenu)

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Only for the main status-bar menu (the history submenu rebuilds via
        // menuNeedsUpdate). Dismiss any active modal before the menu shows, and
        // pre-warm ScreenCaptureKit content while the user browses.
        guard menu === statusBarMenu else { return }
        ScreenCaptureManager.prewarm()
        if let modalWin = NSApp.modalWindow {
            NSApp.stopModal()
            modalWin.close()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Only rebuild the history submenu, not the main status bar menu
        guard menu === historyMenu else { return }

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
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        guard let image = ScreenshotHistory.shared.loadImage(for: entry) else { return }

        ImageEncoder.copyToClipboard(image)
        showFloatingThumbnail(image: image, historyEntryID: entry.id)

        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        if soundEnabled {
            Self.captureSound?.stop()
            Self.captureSound?.play()
        }
    }

    @objc private func clearHistory() {
        confirmClearHistory()
    }

    private func clearHistorySilently() {
        ScreenshotHistory.shared.clear()
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
