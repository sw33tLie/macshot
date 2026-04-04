import Cocoa
import CoreGraphics

/// A custom onboarding window shown on first launch (or when screen recording
/// permission is missing). Guides the user step-by-step instead of letting
/// macOS throw its own generic dialogs.
class PermissionOnboardingController: NSWindowController {

    // Called when the user has granted permission and we're ready to go
    var onPermissionGranted: (() -> Void)?

    private var pollTimer: Timer?
    private var permissionGranted = false

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Welcome to macshot")
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true

        super.init(window: window)
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
        let title = NSTextField(labelWithString: L("macshot needs one permission"))
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(title)

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

            // Guide image — fixed small size, centered, just enough to orient the user
            imgView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
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
        // Deep-link directly to Privacy & Security → Screen Recording.
        // macOS will add macshot to the list automatically when it first
        // attempts a capture — no CGRequestScreenCaptureAccess() call needed
        // (that API shows the redundant native dialog we want to avoid).
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
