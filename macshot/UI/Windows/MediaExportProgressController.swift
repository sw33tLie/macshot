import Cocoa

/// A modeless native progress window owned by the export, not its editor.
/// It remains available for cancellation if the editor closes mid-export.
@MainActor
final class MediaExportProgressController: NSObject, NSWindowDelegate {
    private static var active: [UUID: MediaExportProgressController] = [:]
    private let job: MediaExportCoordinator.Job
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: L("Cancel"), target: nil, action: nil)

    static func show(for job: MediaExportCoordinator.Job) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !job.isFinished else { return }
            let controller = MediaExportProgressController(job: job)
            active[job.id] = controller
            controller.show()
        }
    }

    private init(job: MediaExportCoordinator.Job) {
        self.job = job
        super.init()
    }

    private func show() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 130),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = job.title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.delegate = self
        let content = NSView()
        panel.contentView = content
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        progress.style = .bar
        progress.minValue = 0; progress.maxValue = 1
        progress.isIndeterminate = true
        progress.setAccessibilityLabel(job.status)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        for view in [label, progress, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            progress.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            progress.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 14),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        self.panel = panel
        job.onChange = { [weak self] in self?.update() }
        update()
        panel.center()
        panel.orderFront(nil)
    }

    private func update() {
        if job.isFinished {
            panel?.close()
            panel = nil
            Self.active.removeValue(forKey: job.id)
            (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
            return
        }
        label.stringValue = job.isCancelling ? L("Cancelling...") : job.status
        if let fraction = job.progress, !job.isCancelling {
            progress.isIndeterminate = false
            progress.doubleValue = fraction
            label.stringValue += " \(Int(fraction * 100))%"
        } else {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        }
        cancelButton.isEnabled = job.canCancel
    }

    @objc private func cancel() { job.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { job.cancel(); return false }
}
