import Cocoa

@MainActor final class FeedbackSessionManager {
    static let shared = FeedbackSessionManager()
    private var root: URL?
    private var request: FeedbackRequest?
    private var folder: URL?
    private weak var editor: FeedbackEditorWindowController?
    private var timer: Timer?
    private var submitting = false
    private var awaitingCapture = false
    private var captureCleanup: (() -> Void)?
    private let bookmarkKey = "feedbackHandoffBookmark"
    private let pathKey = "feedbackHandoffPath"
    private let directoryResolver: (() throws -> URL)?

    init(directoryResolver: (() throws -> URL)? = nil) {
        self.directoryResolver = directoryResolver
    }

    var hasActiveSession: Bool { request != nil }

    var directoryDisplayPath: String? {
        refreshDirectoryPathSnapshot()
    }

    @discardableResult
    func refreshDirectoryPathSnapshot() -> String? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            UserDefaults.standard.removeObject(forKey: pathKey)
            return nil
        }
        var stale = false
        guard let path = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale).path else {
            UserDefaults.standard.removeObject(forKey: pathKey)
            return nil
        }
        UserDefaults.standard.set(path, forKey: pathKey)
        UserDefaults.standard.synchronize()
        return path
    }

    func chooseDirectory() {
        guard !hasActiveSession else { NSAlert(error: FeedbackLocalization.localizedError(FeedbackError.busy)).runModal(); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = L("Choose a parent folder. macshot will create a private macshot-ai handoff folder and will not read other files.")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let accessed = parent.startAccessingSecurityScopedResource()
        defer { if accessed { parent.stopAccessingSecurityScopedResource() } }
        do {
            let directory = parent.appendingPathComponent("macshot-ai", isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            try FeedbackSessionFiles.check(directory, directory: true)
            let bookmark = try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            UserDefaults.standard.set(directory.path, forKey: pathKey)
            UserDefaults.standard.synchronize()
            let alert = NSAlert(); alert.messageText = L("AI Handoff Folder Authorized")
            alert.informativeText = directory.path + "\n\n" + L("Use --handoff to specify this folder in the CLI. Normal screenshots and manual export do not require this setting.")
            alert.runModal()
        } catch { NSAlert(error: FeedbackLocalization.localizedError(error)).runModal() }
    }

    private func resolve() throws -> URL {
        if let directoryResolver { return try directoryResolver() }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { throw FeedbackError.invalidSession }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw FeedbackError.invalidSession }
        if stale {
            do {
                let fresh = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            } catch { url.stopAccessingSecurityScopedResource(); throw error }
        }
        UserDefaults.standard.set(url.path, forKey: pathKey)
        UserDefaults.standard.synchronize()
        return url
    }

    /// The caller owns the security scope and must release it after the write finishes.
    func resolveDirectoryForManualExport() throws -> URL { try resolve() }

    func open(session: UUID, beginCapture: ((UUID) -> Void)? = nil,
              cancelCapture: ((UUID) -> Void)? = nil) {
        if request?.session == session { editor?.showWindow(nil); return }
        do {
            let root = try resolve()
            var retained = false
            defer { if !retained { root.stopAccessingSecurityScopedResource() } }
            let (folder, incoming) = try FeedbackSessionFiles.request(root: root, session: session)
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("result.json").path) { return }
            if hasActiveSession {
                try finish(.failed, message: FeedbackLocalization.message(FeedbackError.busy), request: incoming, folder: folder)
                return
            }
            guard incoming.deadline > Date().timeIntervalSince1970, incoming.deadline <= Date().timeIntervalSince1970 + 86_400 else {
                try finish(.timedOut, message: L("The session has timed out."), request: incoming, folder: folder); return
            }
            var image: CGImage?
            if incoming.mode == .capture {
                guard beginCapture != nil else {
                    try finish(.failed, message: L("Screenshot capture is unavailable."), request: incoming, folder: folder)
                    return
                }
            } else {
                let input = folder.appendingPathComponent("input.png")
                do {
                    try FeedbackSessionFiles.check(input, directory: false, maximumBytes: 128_000_000)
                    image = try FeedbackExport.loadImage(input)
                } catch {
                    try finish(.failed, message: FeedbackLocalization.message(error), request: incoming, folder: folder)
                    NSAlert(error: FeedbackLocalization.localizedError(error)).runModal()
                    return
                }
            }
            self.root = root; self.request = incoming; self.folder = folder
            retained = true
            awaitingCapture = incoming.mode == .capture
            if awaitingCapture { captureCleanup = { cancelCapture?(incoming.session) } }
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            poll()
            guard request?.session == incoming.session else { return }
            if let image { openEditor(image: image) }
            else { beginCapture?(incoming.session) }
        } catch { NSAlert(error: FeedbackLocalization.localizedError(error)).runModal() }
    }

    private func openEditor(image: CGImage) {
        let controller = FeedbackEditorWindowController.open(image: image)
        editor = controller
        controller.configureSession(submit: { [weak self] doc, source, preview, completion in
            self?.submit(doc, source: source, preview: preview, completion: completion)
        }, cancel: { [weak self] in self?.terminate(.cancelled, message: L("Session cancelled. Notes remain a draft.")) })
    }

    func completeCapture(session: UUID, image: CGImage?) {
        poll()
        guard request?.session == session, awaitingCapture else { return }
        captureCleanup = nil
        awaitingCapture = false
        guard let image,
              (try? FeedbackDocument(width: image.width, height: image.height).validated()) != nil else {
            terminate(.failed, message: FeedbackLocalization.message(FeedbackError.invalidImage))
            return
        }
        openEditor(image: image)
    }

    func endCapture(session: UUID, state: FeedbackReceipt.State, message: String) {
        guard request?.session == session, awaitingCapture else { return }
        terminate(state, message: message)
    }

    private func finish(_ state: FeedbackReceipt.State, message: String, request: FeedbackRequest, folder: URL) throws {
        let result = FeedbackReceipt(version: 1, session: request.session, token: request.token, state: state, message: message)
        try FeedbackExport.publish(JSONEncoder().encode(result), to: folder.appendingPathComponent("result.json"))
    }

    private func poll() {
        guard let request, let folder else { return }
        if FeedbackSessionFiles.cancelled(folder, request: request) { terminate(.cancelled, message: L("Session cancelled. Notes remain a draft.")) }
        else if Date().timeIntervalSince1970 >= request.deadline { terminate(.timedOut, message: L("Session timed out. Notes remain a draft.")) }
    }

    private func terminate(_ state: FeedbackReceipt.State, message: String) {
        guard let request, let folder else { return }
        do { try finish(state, message: message, request: request, folder: folder) }
        catch { editor?.endSession(message: String(format: L("Could not write the session result: %@"), FeedbackLocalization.message(error))); clear(); return }
        editor?.endSession(message: message)
        clear()
    }

    private func clear() {
        let cleanup = captureCleanup
        captureCleanup = nil
        awaitingCapture = false
        timer?.invalidate(); timer = nil
        root?.stopAccessingSecurityScopedResource(); root = nil
        request = nil; folder = nil; editor = nil; submitting = false
        cleanup?()
    }

    private func submit(_ document: FeedbackDocument, source: CGImage, preview: CGImage,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        poll()
        guard !submitting, let request, let folder else { completion(.failure(FeedbackError.invalidSession)); return }
        submitting = true
        let markdown = document.markdown(labels: FeedbackLocalization.markdownLabels)
        // This worker owns another scope lease even if a timeout ends the UI session.
        let lease = root
        let accessed = lease?.startAccessingSecurityScopedResource() ?? false
        MediaExportCoordinator.shared.start(title: L("Submit AI Feedback"), status: L("Publishing this feedback round"), operation: { cancellation, _ in
            try cancellation.beginPublication()
            try await MediaExportIO.perform {
                try FeedbackExport.write(source: source, preview: preview, document: document, directory: folder, markdown: markdown)
            }
        }, completion: { [weak self] result in
                defer { if accessed { lease?.stopAccessingSecurityScopedResource() } }
                guard let self else { completion(.failure(FeedbackError.invalidSession)); return }
                self.poll()
                guard self.request?.session == request.session else { completion(.failure(FeedbackError.invalidSession)); return }
                self.submitting = false
                var published = false
                do {
                    try result.get()
                    published = true
                    try self.finish(.submitted, message: L("Feedback submitted."), request: request, folder: folder)
                    self.clear()
                    completion(.success(()))
                } catch {
                    if published {
                        for name in ["source.png", "preview.png", "feedback.md", "feedback.json"] {
                            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                        }
                    }
                    completion(.failure(error))
                }
        })
    }

    func applicationWillTerminate() {
        terminate(.cancelled, message: L("The app quit without submitting this round. Notes can be restored from drafts."))
    }
}
