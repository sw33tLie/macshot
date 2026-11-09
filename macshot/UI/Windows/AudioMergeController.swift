import Cocoa
import AVFoundation

/// Shows a dialog to merge microphone + system audio tracks into one,
/// with individual volume sliders. Presented after recording when both
/// audio sources were active.
final class AudioMergeController: NSObject {

    private var window: NSPanel?
    private var micSlider: NSSlider!
    private var systemSlider: NSSlider!
    private var mergeButton: NSButton?
    private var skipButton: NSButton?
    private var titleLabel: NSTextField?
    private var progressIndicator: NSProgressIndicator?
    private var mergeJob: MediaExportCoordinator.Job?

    /// Merge the audio tracks and call completion with the final URL.
    /// If the user skips merging, completion is called with the original URL.
    func show(url: URL, completion: @escaping (URL) -> Void) {
        let asset = AVAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count >= 2 else {
            completion(url)
            return
        }

        let panelW: CGFloat = 380
        let panelH: CGFloat = 160

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Audio Tracks")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.level = .floating
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))

        // Title label
        let title = NSTextField(labelWithString: L("Adjust volume for each audio track:"))
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.frame = NSRect(x: 20, y: panelH - 32, width: panelW - 40, height: 18)
        content.addSubview(title)
        titleLabel = title

        // Mic volume row
        let micLabel = NSTextField(labelWithString: L("Microphone:"))
        micLabel.font = NSFont.systemFont(ofSize: 11)
        micLabel.frame = NSRect(x: 20, y: panelH - 62, width: 90, height: 18)
        content.addSubview(micLabel)

        micSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
        micSlider.frame = NSRect(x: 115, y: panelH - 64, width: panelW - 155, height: 22)
        micSlider.isContinuous = true
        micSlider.setAccessibilityLabel(L("Microphone:"))
        content.addSubview(micSlider)

        // System volume row
        let sysLabel = NSTextField(labelWithString: L("System audio:"))
        sysLabel.font = NSFont.systemFont(ofSize: 11)
        sysLabel.frame = NSRect(x: 20, y: panelH - 92, width: 90, height: 18)
        content.addSubview(sysLabel)

        systemSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
        systemSlider.frame = NSRect(x: 115, y: panelH - 94, width: panelW - 155, height: 22)
        systemSlider.isContinuous = true
        systemSlider.setAccessibilityLabel(L("System audio:"))
        content.addSubview(systemSlider)

        // Buttons
        let mergeBtn = NSButton(title: L("Merge Audio"), target: nil, action: nil)
        mergeBtn.bezelStyle = .rounded
        mergeBtn.keyEquivalent = "\r"
        mergeBtn.frame = NSRect(x: panelW - 130, y: 12, width: 115, height: 30)
        content.addSubview(mergeBtn)
        mergeButton = mergeBtn

        let skipBtn = NSButton(title: L("Keep Separate"), target: nil, action: nil)
        skipBtn.bezelStyle = .rounded
        skipBtn.keyEquivalent = "\u{1b}"
        skipBtn.frame = NSRect(x: panelW - 255, y: 12, width: 115, height: 30)
        content.addSubview(skipBtn)
        skipButton = skipBtn

        panel.contentView = content
        panel.delegate = self
        self.window = panel

        mergeBtn.target = self
        mergeBtn.action = #selector(mergeClicked)
        skipBtn.target = self
        skipBtn.action = #selector(skipClicked)

        // Store state for callbacks
        _url = url
        _completion = completion

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var _url: URL!
    private var _completion: ((URL) -> Void)!

    @objc private func mergeClicked() {
        guard mergeJob == nil, let source = _url else { return }
        let volumes = [Float(micSlider.doubleValue), Float(systemSlider.doubleValue)]
        let destination = source.deletingLastPathComponent().appendingPathComponent(
            source.deletingPathExtension().lastPathComponent + "_mixed_" + UUID().uuidString + ".mp4")
        micSlider.isEnabled = false
        systemSlider.isEnabled = false
        mergeButton?.isEnabled = false
        skipButton?.title = L("Cancel")
        titleLabel?.stringValue = L("Exporting...") + " 0%"
        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 116, width: 340, height: 8))
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        window?.contentView?.addSubview(indicator)
        progressIndicator = indicator

        let job = MediaExportCoordinator.shared.start(title: source.lastPathComponent, status: L("Exporting..."),
            operation: { cancellation, progress in
                try await AudioTrackMixer.export(source: source, destination: destination,
                    volumes: volumes, cancellation: cancellation, progress: progress)
            }, completion: { [weak self] result in
                self?.mergeJob = nil
                switch result {
                case .success:
                    self?.deliverAndClose(destination)
                case .failure(let error):
                    if !(error is CancellationError) {
                        (NSApp.delegate as? AppDelegate)?.showFailureToast(L("Export failed") + ": " + error.localizedDescription)
                    }
                    self?.deliverAndClose(source)
                }
            })
        mergeJob = job
        job.onChange = { [weak self, weak job] in
            guard let self, let job, !job.isFinished else { return }
            self.skipButton?.isEnabled = job.canCancel
            self.titleLabel?.stringValue = job.isCancelling ? L("Cancelling...") : job.status
            if let fraction = job.progress, !job.isCancelling {
                self.progressIndicator?.doubleValue = fraction
                self.titleLabel?.stringValue += " \(Int(fraction * 100))%"
            }
        }
    }

    @objc private func skipClicked() { deliverOriginalAndClose() }

    private func deliverOriginalAndClose() {
        guard let url = _url else { return }
        if let job = mergeJob {
            // Keep ownership and the progress panel until the writer actually
            // stops. Publication may already have won the cancellation race.
            job.cancel()
            return
        }
        deliverAndClose(url)
    }

    private func deliverAndClose(_ url: URL) {
        guard let completion = _completion else { return }
        _completion = nil
        window?.close()
        window = nil
        completion(url)
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}

extension AudioMergeController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let job = mergeJob else { return true }
        job.cancel()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Normal completion clears the callback before closing the window.
        deliverOriginalAndClose()
    }
}
