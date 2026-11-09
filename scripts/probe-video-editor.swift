// Used by probe-video-editor.sh. All editor, timeline, compositor, export,
// source-ownership and progress code is compiled directly from macshot/.
// Only unrelated app services, colors and localization are stubbed here.
import Cocoa
enum ProbeInput {
    static var directory: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
    static var url: URL { directory.appendingPathComponent("input.mp4") }
}
func L(_ value: String) -> String { value }
enum ToolbarLayout {
    static var bgColor: NSColor { NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1) }
    static var iconColor: NSColor { .white }
    static var accentColor: NSColor { .systemBlue }
    static var appearance: NSAppearance { NSAppearance(named: .darkAqua)! }
}
enum SaveDirectoryAccess {
    static func resolveRecordingDirectoryIfAccessible() -> URL? { ProbeInput.directory }
    static func recordingDirectoryHint() -> URL? { resolveRecordingDirectoryIfAccessible() }
    static func stopAccessing(url: URL) {}
}
#if !OFFLINE
// Normal toolbar layout, with all network operations deliberately unavailable.
// Provider wire behavior is tested separately with injected local URLProtocol fixtures.
final class DisabledProbeUploader {
    static let shared = DisabledProbeUploader()
    let isSignedIn = false
    let isConfigured = false
    func uploadVideo(url: URL, progress: @escaping @MainActor @Sendable (Double) -> Void,
                     completion: @escaping (Result<String, Error>) -> Void) {
        completion(.failure(CocoaError(.featureUnsupported)))
    }
}
typealias GoogleDriveUploader = DisabledProbeUploader
typealias S3Uploader = DisabledProbeUploader
#endif
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let termination = ApplicationTerminationCoordinator()
    private var audioMerge: AudioMergeController?
    private var completionCount = 0
    func returnFocusIfNeeded() {}
    func showFailureToast(_ text: String) { log(["error": text]) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        let mixer = NSMenuItem(title: "Open Audio Mixer", action: #selector(openAudioMixer), keyEquivalent: "m")
        mixer.target = self
        appMenu.addItem(mixer)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = menu
        let env = ProcessInfo.processInfo.environment
        if let root = env["PROBE_ROOT"] { RecordingSessionStore.probeRoot = URL(fileURLWithPath: root, isDirectory: true) }
        if Bundle.main.object(forInfoDictionaryKey: "AudioMergeProbe") as? Bool == true { openAudioMixer() }
        else if let video = env["PROBE_VIDEO"] {
            VideoEditorWindowController.open(url: URL(fileURLWithPath: video), deleteOnClose: false)
        } else { VideoEditorWindowController.open(url: ProbeInput.url, deleteOnClose: false) }
        if let commands = env["PROBE_COMMANDS"] { pollCommands(path: commands) }
    }
    @objc private func openAudioMixer() {
        guard audioMerge == nil else { return }
        let controller = AudioMergeController()
        audioMerge = controller
        controller.show(url: ProbeInput.url) { [weak self] result in
            guard let self else { return }
            self.completionCount += 1
            self.audioMerge = nil
            self.log(["completion": self.completionCount, "original": result == ProbeInput.url,
                      "output": result.path, "exists": FileManager.default.fileExists(atPath: result.path)])
            VideoEditorWindowController.open(url: result, deleteOnClose: false)
        }
    }
    /// Scripted UI driving: each line appended to the file runs once.
    private func pollCommands(path: String) {
        var consumed = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard lines.count - 1 > consumed else { return }
                let editor = NSApp.windows.compactMap { ($0 as? VideoEditorWindow)?.editor }.first
                // One command per tick lets scheduled rebuilds and layout run
                // between commands, as they would between user actions.
                let line = lines[consumed]
                consumed += 1
                guard !line.isEmpty else { return }
                let result = editor?.probe(line) ?? "no editor"
                FileHandle.standardOutput.write(Data((result + "\n").utf8))
            }
        }
    }

    private func log(_ values: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.request(hasActiveWork: MediaExportCoordinator.shared.hasActiveJobs,
            drain: { await MediaExportCoordinator.shared.waitUntilIdle() }, terminate: { sender.terminate(nil) })
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
