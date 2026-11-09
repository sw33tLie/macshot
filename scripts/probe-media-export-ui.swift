// Native progress/quit probe using the production coordinators and window.
// It generates synthetic progress, not a recording or a media export.
// Build from the repository root:
// swiftc -swift-version 5 -parse-as-library \
//   macshot/Services/ApplicationTerminationCoordinator.swift \
//   macshot/Services/MediaExportCoordinator.swift \
//   macshot/UI/Windows/MediaExportProgressController.swift \
//   scripts/probe-media-export-ui.swift -o /tmp/ExportProbe
// Run /tmp/ExportProbe quit: requests Quit at 2s; must exit after success at ~8s.
// Run /tmp/ExportProbe quit-dark: requests Quit at 2s; click Cancel or close the
//   progress window. It must report cancellation once, then exit with active=0.
// Run /tmp/ExportProbe cancel: light appearance, two-minute synthetic job.
// No capture permissions, network, preferences, or user files are used.
import Cocoa

func L(_ value: String) -> String { value }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let started = Date()
    private let termination = ApplicationTerminationCoordinator()
    private let mode = CommandLine.arguments.dropFirst().first ?? "cancel"

    func log(_ value: String) {
        let data = Data(String(format: "%.3f %@\n", Date().timeIntervalSince(started), value).utf8)
        FileHandle.standardOutput.write(data)
    }

    func returnFocusIfNeeded() { log("progress window closed") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: mode.contains("dark") ? .darkAqua : .aqua)
        let count = mode == "quit" ? 40 : 600
        let job = MediaExportCoordinator.shared.start(title: "Synthetic recording.mp4", status: "Saving...",
            operation: { cancellation, progress in
                for index in 0..<count {
                    try cancellation.check()
                    try await Task.sleep(nanoseconds: 200_000_000)
                    progress(Double(index + 1) / Double(count))
                }
                try cancellation.beginPublication()
            }, completion: { [weak self] result in
                self?.log("job completion: \(result)")
            })
        MediaExportProgressController.show(for: job)
        NSApp.activate(ignoringOtherApps: true)
        log("job registered")
        if mode.hasPrefix("quit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log("quit requested; active=\(MediaExportCoordinator.shared.activeCount)")
        return termination.request(hasActiveWork: MediaExportCoordinator.shared.hasActiveJobs, drain: {
            await MediaExportCoordinator.shared.waitUntilIdle()
        }, terminate: { [self] in
            log("all work drained")
            sender.terminate(nil)
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("application terminated; active=\(MediaExportCoordinator.shared.activeCount)")
    }
}

@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
