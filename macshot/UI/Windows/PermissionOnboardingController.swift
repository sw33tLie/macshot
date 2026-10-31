import Cocoa
import CoreGraphics

/// A custom onboarding window shown on first launch (or when screen recording
/// permission is missing). Guides the user step-by-step instead of letting
/// macOS throw its own generic dialogs.
class PermissionOnboardingController: NSWindowController {

    // Called when the user has granted permission and we're ready to go
    var onPermissionGranted: (() -> Void)?

    /// Called when the window closes without permission being granted (e.g. the
    /// user dismisses it with the title-bar red-X), so the owner can drop its
    /// reference and the poll timer stops.
    var onClose: (() -> Void)?

    private var pollTimer: Timer?
    private var permissionGranted = false

    /// Someone who has used macshot before is asked to turn the permission
    /// back on (macOS can require it again after an update, e.g. when the
    /// signing identity changes) rather than greeted as a new user.
    private let isReturningUser: Bool

    private static let grantedBeforeKey = "screenRecordingGrantedBefore"

    /// Sparkle records the first launch; the flag covers later grants.
    static func isReturningUser(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: grantedBeforeKey) || defaults.bool(forKey: "SUHasLaunchedBefore")
    }

    static func rememberGranted(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: grantedBeforeKey)
    }

    // MARK: - Init

    init(returningUser: Bool = PermissionOnboardingController.isReturningUser()) {
        isReturningUser = returningUser
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: returningUser ? 610 : 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = returningUser ? L("Welcome back to macshot") : L("Welcome to macshot")
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true

        super.init(window: window)
        window.delegate = self   // catch the title-bar red-X (see windowWillClose)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - UI

    private weak var statusLabel: NSTextField?
    private weak var actionButton: NSButton?
    private weak var continueButton: NSButton?
    private weak var spinner: NSProgressIndicator?
    private weak var checkmark: NSTextField?

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        cv.wantsLayer = true

        // App icon / logo
        let logoView = NSImageView()
        logoView.image = NSImage(named: "AppIcon") ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(logoView)

        // Title
        let title = NSTextField(labelWithString: isReturningUser ? L("Turn Screen Recording back on") : L("macshot needs one permission"))
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(title)

        // Returning users: reassure, and give the fix for a stale entry that
        // still shows as on in System Settings.
        let note = NSTextField(wrappingLabelWithString: L("After some updates, macOS asks you to allow macshot again. Your settings and captures are safe. If macshot is already in the list, select it, click the minus button (−) to remove it, then click the plus button (+) and add macshot again."))
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.isHidden = !isReturningUser
        note.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(note)

        // Guide image — always visible, shows how to enable permission
        let imgView = NSImageView()
        imgView.image = NSImage(named: "PermissionsGuide")
        imgView.imageScaling = .scaleProportionallyUpOrDown
        imgView.wantsLayer = true
        imgView.layer?.cornerRadius = 7
        imgView.layer?.masksToBounds = true
        imgView.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(imgView)

        // Step indicator box
        let stepBox = NSBox()
        stepBox.boxType = .custom
        stepBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
        stepBox.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.25)
        stepBox.borderWidth = 1
        stepBox.cornerRadius = 9
        stepBox.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(stepBox)

        // Status label (inside box)
        let statusLbl = NSTextField(labelWithString: L("Screen Recording not yet granted"))
        statusLbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLbl.textColor = .secondaryLabelColor
        statusLbl.alignment = .center
        statusLbl.translatesAutoresizingMaskIntoConstraints = false
        stepBox.addSubview(statusLbl)
        self.statusLabel = statusLbl

        // Spinner (inside box)
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.isIndeterminate = true
        spin.translatesAutoresizingMaskIntoConstraints = false
        stepBox.addSubview(spin)
        self.spinner = spin

        // Checkmark (hidden until granted)
        let check = NSTextField(labelWithString: "✓")
        check.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        check.textColor = .systemGreen
        check.isHidden = true
        check.translatesAutoresizingMaskIntoConstraints = false
        stepBox.addSubview(check)
        self.checkmark = check

        // Primary button
        let openBtn = NSButton(title: L("Open Screen Recording Settings"), target: self, action: #selector(openSettings))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .large
        openBtn.keyEquivalent = "\r"
        openBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(openBtn)
        self.actionButton = openBtn

        // Continue button (hidden until granted)
        let contBtn = NSButton(title: L("Continue"), target: self, action: #selector(continueClicked))
        contBtn.bezelStyle = .rounded
        contBtn.controlSize = .large
        contBtn.isHidden = true
        contBtn.keyEquivalent = "\r"
        contBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(contBtn)
        self.continueButton = contBtn

        // Image aspect ratio: 1405 × 892
        let imgAspect: CGFloat = 892.0 / 1405.0

        NSLayoutConstraint.activate([
            logoView.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            logoView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20),
            logoView.widthAnchor.constraint(equalToConstant: 44),
            logoView.heightAnchor.constraint(equalToConstant: 44),

            title.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -24),

            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 28),
            note.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -28),

            // Guide image — fixed small size, centered, just enough to orient the user
            imgView.topAnchor.constraint(equalTo: isReturningUser ? note.bottomAnchor : title.bottomAnchor, constant: 12),
            imgView.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 360),
            imgView.heightAnchor.constraint(equalToConstant: floor(360 * imgAspect)),

            stepBox.topAnchor.constraint(equalTo: imgView.bottomAnchor, constant: 14),
            stepBox.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            stepBox.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            stepBox.heightAnchor.constraint(equalToConstant: 38),

            spin.leadingAnchor.constraint(equalTo: stepBox.leadingAnchor, constant: 12),
            spin.centerYAnchor.constraint(equalTo: stepBox.centerYAnchor),
            spin.widthAnchor.constraint(equalToConstant: 14),
            spin.heightAnchor.constraint(equalToConstant: 14),

            check.leadingAnchor.constraint(equalTo: stepBox.leadingAnchor, constant: 11),
            check.centerYAnchor.constraint(equalTo: stepBox.centerYAnchor),

            statusLbl.centerXAnchor.constraint(equalTo: stepBox.centerXAnchor),
            statusLbl.centerYAnchor.constraint(equalTo: stepBox.centerYAnchor),

            openBtn.topAnchor.constraint(equalTo: stepBox.bottomAnchor, constant: 14),
            openBtn.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            openBtn.widthAnchor.constraint(equalToConstant: 260),
            openBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),

            contBtn.topAnchor.constraint(equalTo: stepBox.bottomAnchor, constant: 14),
            contBtn.centerXAnchor.constraint(equalTo: cv.centerXAnchor),
            contBtn.widthAnchor.constraint(equalToConstant: 260),
            contBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -20),
        ])
    }

    // MARK: - Show

    func show() {
        // Reset granted state each time we show — handles the revoke-then-reshown case.
        // CGPreflightScreenCaptureAccess() caches true within a process lifetime, so
        // we cannot rely on it after revocation. We reset here so polling starts fresh.
        permissionGranted = false

        // Reset UI back to initial state in case this controller is being reused
        spinner?.isHidden = false
        spinner?.startAnimation(nil)
        checkmark?.isHidden = true
        statusLabel?.stringValue = L("Screen Recording not yet granted")
        statusLabel?.textColor = .secondaryLabelColor
        actionButton?.isHidden = false
        continueButton?.isHidden = true

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    // MARK: - Permission polling

    private func startPolling() {
        pollTimer?.invalidate()
        // Poll every 0.75s using CGPreflightScreenCaptureAccess() — this is a pure
        // TCC status query that never triggers the native system dialog.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.checkPermission()
        }
    }

    private func checkPermission() {
        guard !permissionGranted else { return }
        if CGPreflightScreenCaptureAccess() {
            permissionGranted = true
            pollTimer?.invalidate()
            pollTimer = nil
            showGranted()
        }
    }

    /// Check screen recording permission without triggering a system dialog.
    /// Uses CGPreflightScreenCaptureAccess() which is purely a status query.
    /// NOTE: This may return a stale cached value if permission was revoked since launch.
    static func hasScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Check at app launch — synchronous and dialog-free.
    static func checkPermissionSync(completion: @escaping (Bool) -> Void) {
        completion(hasScreenRecordingPermission())
    }

    private func showGranted() {
        Self.rememberGranted()
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
        checkmark?.isHidden = false
        statusLabel?.stringValue = L("Screen Recording granted!")
        statusLabel?.textColor = .systemGreen
        actionButton?.isHidden = true
        continueButton?.isHidden = false
        continueButton?.keyEquivalent = "\r"

        // Auto-advance after 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.continueClicked()
        }
    }

    // MARK: - Actions

    @objc private func openSettings() {
        // macOS lists an app under Screen Recording only once it has asked.
        // The preflight polling never asks, and captures don't run until the
        // permission exists, so the list had no macshot to switch on (#299).
        // Ask once before opening Settings: the first call adds macshot to
        // the list (switched off) and shows the system prompt; later calls
        // return immediately without a dialog.
        _ = CGRequestScreenCaptureAccess()
        // Deep-link directly to Privacy & Security → Screen Recording.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }

        statusLabel?.stringValue = L("Enable macshot, then try taking a screenshot")
    }

    @objc private func continueClicked() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
        onPermissionGranted?()
    }
}

extension PermissionOnboardingController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Title-bar red-X (the Continue button uses orderOut, not close, so it
        // doesn't come through here). Stop the permission poll and let the owner
        // drop its reference so the controller + timer don't leak.
        pollTimer?.invalidate()
        pollTimer = nil
        // If permission was already granted (red-X hit during the 1s auto-continue
        // gap), honor the granted path so prewarm still runs; otherwise it's a
        // plain dismissal.
        if permissionGranted {
            let granted = onPermissionGranted
            onPermissionGranted = nil
            onClose = nil
            granted?()
        } else {
            onClose?()
            onClose = nil
        }
    }
}
