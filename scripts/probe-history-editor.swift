import Cocoa

@MainActor
func historyProbeDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("history-probes", isDirectory: true)
        .appendingPathComponent(Bundle.main.infoDictionary!["HistoryProbeRun"] as! String, isDirectory: true)
}

/// Installed as main.swift only in the launcher's private source copy.
/// No capture permissions, hotkeys, uploads, or the real AppDelegate startup.
@MainActor
final class HistoryEditorProbeDelegate: NSObject, NSApplicationDelegate {
    private var controls: NSWindow?
    private var failureLabel: NSTextField?
    private let termination = ApplicationTerminationCoordinator()
    private var directory: URL { historyProbeDirectory() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(editorClosed(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "History probe")
        let failItem = NSMenuItem(title: "Fail index publication", action: #selector(toggleFailureMenu(_:)), keyEquivalent: "f")
        failItem.keyEquivalentModifierMask = [.command, .option]
        failItem.target = self
        applicationMenu.addItem(failItem)
        let delayItem = NSMenuItem(title: "Delay next history save (10 seconds)", action: #selector(delayNextSave), keyEquivalent: "d")
        delayItem.keyEquivalentModifierMask = [.command, .option]
        delayItem.target = self
        applicationMenu.addItem(delayItem)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit History Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
        UserDefaults.standard.set(10, forKey: "historySize")
        UserDefaults.standard.set(false, forKey: "historyUnlimited")
        UserDefaults.standard.set(false, forKey: "beautifyEnabled")
        ImageSaveService.onFailure = { [weak self] message in
            self?.failureLabel?.stringValue = message
            print("HISTORY ERROR: " + message)
            fflush(stdout)
        }
        let window = NSWindow(contentRect: NSRect(x: 40, y: 60, width: 600, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "History probe controls"
        window.isReleasedWhenClosed = false
        let toggle = NSButton(checkboxWithTitle: "Fail index publication", target: self, action: #selector(toggleFailure(_:)))
        toggle.frame = NSRect(x: 16, y: 76, width: 300, height: 24)
        window.contentView?.addSubview(toggle)
        let label = NSTextField(wrappingLabelWithString: "No save failure")
        label.frame = NSRect(x: 16, y: 10, width: 570, height: 56)
        window.contentView?.addSubview(label)
        failureLabel = label
        controls = window
        window.orderFront(nil)
        Task {
            let image = makeImage()
            let history = ScreenshotHistory.shared
            let id = history.add(image: image)
            await history.waitUntilIdle()
            print("HISTORY DIRECTORY: " + directory.path)
            print("ENTRY: " + (id ?? "missing"))
            fflush(stdout)
            DetachedEditorWindowController.open(image: image, historyEntryID: id, disableBeautify: true)
        }
    }

    @objc private func toggleFailure(_ sender: NSButton) {
        setFailure(sender.state == .on)
    }

    @objc private func editorClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.title.hasPrefix("macshot Editor") else { return }
        print("EDITOR CLOSED")
        fflush(stdout)
        DispatchQueue.main.async { [weak self] in self?.controls?.makeKeyAndOrderFront(nil) }
    }

    @objc private func toggleFailureMenu(_ sender: NSMenuItem) {
        sender.state = FileManager.default.fileExists(atPath: directory.appendingPathComponent("fail-index").path) ? .off : .on
        setFailure(sender.state == .on)
    }

    @objc private func delayNextSave() {
        try? Data([1]).write(to: directory.appendingPathComponent("delay-index"))
        failureLabel?.stringValue = "Next history save will wait for 10 seconds before publication"
    }

    private func setFailure(_ enabled: Bool) {
        let marker = directory.appendingPathComponent("fail-index")
        if enabled { try? Data([1]).write(to: marker) }
        else { try? FileManager.default.removeItem(at: marker) }
        failureLabel?.stringValue = enabled ? "Next history save will fail before publication" : "Saving enabled"
    }

    private func makeImage() -> NSImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 900, height: 560, bitsPerComponent: 8, bytesPerRow: 900 * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.10, green: 0.17, blue: 0.28, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 560))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.75, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 180, y: 160, width: 540, height: 240))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 900, height: 560))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request(hasActiveWork: ScreenshotHistory.shared.hasPendingWrites || MediaExportCoordinator.shared.hasActiveJobs,
            drain: {
                await MediaExportCoordinator.shared.waitUntilIdle()
                await ScreenshotHistory.shared.waitUntilIdle()
            }, terminate: { sender.terminate(nil) })
    }
}

let probeApplication = NSApplication.shared
let probeDelegate: HistoryEditorProbeDelegate
if #available(macOS 14.0, *) {
    probeDelegate = MainActor.assumeIsolated { HistoryEditorProbeDelegate() }
} else {
    fatalError("The native history probe requires macOS 14 or later.")
}
probeApplication.delegate = probeDelegate
probeApplication.setActivationPolicy(.regular)
probeApplication.run()
withExtendedLifetime(probeDelegate) {}
