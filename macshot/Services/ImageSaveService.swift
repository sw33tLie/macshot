import Cocoa

enum SaveActionPreference: Int, CaseIterable {
    case saveToFolder = 0
    case askWhereToSave = 1

    static let userDefaultsKey = "saveAction"

    static var current: SaveActionPreference {
        get {
            guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else {
                return .saveToFolder
            }
            return SaveActionPreference(rawValue: UserDefaults.standard.integer(forKey: userDefaultsKey)) ?? .saveToFolder
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }

    var title: String {
        switch self {
        case .saveToFolder:
            return L("Save to default folder")
        case .askWhereToSave:
            return L("Ask where to save")
        }
    }
}

enum QuickCaptureMode: Int, CaseIterable {
    case saveToFile = 0
    case copyImage = 1
    case saveAndCopyImage = 2
    case doNothing = 3
    case saveAndCopyPath = 4

    static let userDefaultsKey = "quickCaptureMode"

    static var current: QuickCaptureMode {
        guard let rawValue = UserDefaults.standard.object(forKey: userDefaultsKey) as? Int else {
            return .copyImage
        }
        return QuickCaptureMode(rawValue: rawValue) ?? .copyImage
    }

    static let settingsOrder: [QuickCaptureMode] = [
        .saveToFile, .copyImage, .saveAndCopyImage, .saveAndCopyPath, .doNothing,
    ]

    var title: String {
        switch self {
        case .saveToFile: return L("Save to file")
        case .copyImage: return L("Copy to clipboard")
        case .saveAndCopyImage: return L("Save + copy to clipboard")
        case .doNothing: return L("Do nothing")
        case .saveAndCopyPath: return [L("Save"), L("Copy Path")].joined(separator: " + ")
        }
    }

    var shouldCopyImage: Bool {
        self == .copyImage || self == .saveAndCopyImage
    }

    var shouldSave: Bool {
        self == .saveToFile || self == .saveAndCopyImage || self == .saveAndCopyPath
    }

    var copyPathOverride: Bool? {
        self == .saveAndCopyPath ? true : nil
    }
}

enum ImageSaveService {
    typealias Completion = (Bool) -> Void

    static let copyPathAfterSaveKey = "copyPathAfterSave"

    static var copyPathAfterSave: Bool {
        get { UserDefaults.standard.bool(forKey: copyPathAfterSaveKey) }
        set { UserDefaults.standard.set(newValue, forKey: copyPathAfterSaveKey) }
    }

    /// Called with a user-facing message when a save fails. AppDelegate wires
    /// this to a toast at launch. Before it existed, a failed write was logged
    /// in DEBUG only and every call site ignored the `false` completion — the
    /// overlay dismissed, the thumbnail animated, and the screenshot was gone
    /// with no indication it had ever been lost.
    nonisolated(unsafe) static var onFailure: ((String) -> Void)?

    static func reportFailure(_ message: String) {
        DispatchQueue.main.async { onFailure?(message) }
    }

    /// Writes a screenshot into `directory` without overwriting an existing
    /// file. Exposed for tests; the app goes through `save`.
    static func writeImageForTesting(_ image: NSImage, toDirectory directory: URL,
                                     filename: String, copyPathToClipboard: Bool? = nil,
                                     completion: Completion?) {
        guard let prepared = prepare(image, completion: completion) else { return }
        writePreparedImage(prepared, to: directory.appendingPathComponent(filename),
                           chooseAvailableName: true, copyPathToClipboard: copyPathToClipboard,
                           completion: completion)
    }

    static func save(
        _ image: NSImage,
        using action: SaveActionPreference = .current,
        windowTitle: String? = nil,
        appName: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        activateApp: Bool = true,
        copyPathToClipboard: Bool? = nil,
        completion: Completion? = nil
    ) {
        switch action {
        case .saveToFolder:
            saveToConfiguredFolder(
                image,
                windowTitle: windowTitle,
                appName: appName,
                panelLevel: panelLevel,
                sheetWindow: sheetWindow,
                activateApp: activateApp,
                copyPathToClipboard: copyPathToClipboard,
                completion: completion)
        case .askWhereToSave:
            showSavePanel(
                for: image,
                windowTitle: windowTitle,
                appName: appName,
                panelLevel: panelLevel,
                sheetWindow: sheetWindow,
                activateApp: activateApp,
                copyPathToClipboard: copyPathToClipboard,
                completion: completion)
        }
    }

    static func saveToConfiguredFolder(
        _ image: NSImage,
        windowTitle: String? = nil,
        appName: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        activateApp: Bool = true,
        copyPathToClipboard: Bool? = nil,
        completion: Completion? = nil
    ) {
        guard let prepared = prepare(image, completion: completion) else { return }
        // May contain "/" when the template files captures into subfolders.
        let filename = defaultRelativePath(windowTitle: windowTitle, appName: appName, format: prepared.format)
        if let dirURL = SaveDirectoryAccess.resolveIfAccessible() {
            writePreparedImage(prepared, to: dirURL.appendingPathComponent(filename), chooseAvailableName: true,
                               lease: SaveDirectoryLease(alreadyAccessing: dirURL), subfoldersBelow: dirURL,
                               copyPathToClipboard: copyPathToClipboard, completion: completion)
            return
        }

        requestSaveDirectoryAccess(
            panelLevel: panelLevel,
            sheetWindow: sheetWindow,
            activateApp: activateApp
        ) { dirURL, securityScoped in
            guard let dirURL else { completionOnMain(completion, false); return }
            writePreparedImage(prepared, to: dirURL.appendingPathComponent(filename), chooseAvailableName: true,
                               lease: SaveDirectoryLease(alreadyAccessing: securityScoped ? dirURL : nil),
                               subfoldersBelow: dirURL,
                               copyPathToClipboard: copyPathToClipboard, completion: completion)
        }
    }

    static func showSavePanel(
        for image: NSImage,
        suggestedFilename: String? = nil,
        windowTitle: String? = nil,
        appName: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        activateApp: Bool = true,
        copyPathToClipboard: Bool? = nil,
        completion: Completion? = nil
    ) {
        guard let prepared = prepare(image, completion: completion) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [prepared.format.utType]
        panel.nameFieldStringValue = suggestedFilename
            ?? (defaultRelativePath(windowTitle: windowTitle, appName: appName, format: prepared.format) as NSString).lastPathComponent
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let panelLevel {
            panel.level = panelLevel
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            // Cancelling the panel is not a failure — don't report it.
            guard response == .OK, let url = panel.url else {
                completionOnMain(completion, false)
                return
            }
            let accessing = url.startAccessingSecurityScopedResource()
            writePreparedImage(prepared, to: url, chooseAvailableName: false,
                               lease: SaveDirectoryLease(alreadyAccessing: accessing ? url : nil),
                               copyPathToClipboard: copyPathToClipboard, completion: completion)
        }

        presentPanel(panel, sheetWindow: sheetWindow, activateApp: activateApp, completionHandler: handler)
    }

    /// Template-rendered path relative to the save folder, with extension.
    private static func defaultRelativePath(windowTitle: String?, appName: String?, format: ImageEncoder.Format) -> String {
        let defaults = UserDefaults.standard
        let template = defaults.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        let components = FilenameFormatter.formatRelativePath(
            template: template,
            noAppTemplate: defaults.string(forKey: FilenameFormatter.noAppUserDefaultsKey),
            windowTitle: windowTitle,
            appName: appName)
        return components.joined(separator: "/") + ".\(format.fileExtension)"
    }

    private static func prepare(_ image: NSImage, completion: Completion?) -> ImageEncoder.PreparedImage? {
        do { return try ImageEncoder.PreparedImage(image) }
        catch {
            reportFailure(L("Could not encode the screenshot."))
            completionOnMain(completion, false)
            return nil
        }
    }

    /// The same prepared operation handles Save and Save As. The app owns it
    /// through completion (including quit), and the destination is only replaced
    /// after the fully encoded file has been flushed successfully.
    /// `subfoldersBelow`: an existing save folder under which missing template
    /// subfolders ({yyyy}/{MM}/...) may be created. The folder itself is never
    /// recreated: a vanished save folder must fail and be reported.
    static func writePreparedImage(_ prepared: ImageEncoder.PreparedImage, to url: URL,
                                   chooseAvailableName: Bool, lease: SaveDirectoryLease? = nil,
                                   subfoldersBelow root: URL? = nil,
                                   copyPathToClipboard: Bool? = nil,
                                   completion: Completion?) {
        let shouldCopyPath = copyPathToClipboard ?? copyPathAfterSave
        MediaExportCoordinator.shared.start(title: url.lastPathComponent, status: L("Saving..."), operation: { cancellation, _ in
            let savedURL = try await MediaExportIO.perform {
                defer { withExtendedLifetime(lease) {} }
                return try autoreleasepool {
                    try cancellation.check()
                    guard let data = prepared.encode() else { throw CocoaError(.fileWriteUnknown) }
                    if chooseAvailableName {
                        try createSubfolders(for: url, below: root)
                        return try writeWithoutOverwriting(
                            data,
                            in: url.deletingLastPathComponent(),
                            filename: url.lastPathComponent,
                            beforePublish: cancellation.beginPublication)
                    } else {
                        let transaction = try AtomicMediaSave(destinationURL: url)
                        try data.write(to: transaction.stagingURL)
                        try transaction.commit(beforePublish: cancellation.beginPublication)
                        return url
                    }
                }
            }
            if shouldCopyPath {
                copyFilePathToClipboard(savedURL)
            }
        }, completion: { result in
            switch result {
            case .success: completion?(true)
            case .failure(let error):
                reportFailure(String(format: L("Could not save the screenshot: %@"), error.localizedDescription))
                completion?(false)
            }
        })
    }

    /// Creates the folders between an existing `root` and `url`'s parent.
    /// No-op when `root` is nil, missing, or `url` is directly inside it.
    nonisolated static func createSubfolders(for url: URL, below root: URL?) throws {
        guard let root else { return }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let base = root.standardizedFileURL
        guard parent.path != base.path, parent.path.hasPrefix(base.path + "/") else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private static func requestSaveDirectoryAccess(
        panelLevel: NSWindow.Level?,
        sheetWindow: NSWindow?,
        activateApp: Bool,
        completion: @escaping (URL?, Bool) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose a folder")
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        if let panelLevel {
            panel.level = panelLevel
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { completion(nil, false); return }
            SaveDirectoryAccess.save(url: url)
            if let scopedURL = SaveDirectoryAccess.resolveIfAccessible() {
                completion(scopedURL, true)
                return
            }
            let securityScoped = url.startAccessingSecurityScopedResource()
            completion(url, securityScoped)
        }

        presentPanel(panel, sheetWindow: sheetWindow, activateApp: activateApp, completionHandler: handler)
    }

    private static func presentPanel(
        _ panel: NSSavePanel,
        sheetWindow: NSWindow?,
        activateApp: Bool,
        completionHandler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }

        DispatchQueue.main.async {
            if activateApp {
                NSApp.activate(ignoringOtherApps: true)
            }
            if let sheetWindow {
                panel.beginSheetModal(for: sheetWindow, completionHandler: completionHandler)
            } else {
                panel.begin(completionHandler: completionHandler)
            }
        }
    }

    /// Write to the preferred filename without ever replacing an existing
    /// item. Filename selection and creation must be one operation: separate
    /// `fileExists` and `write` calls let concurrent saves select the same
    /// free path and race, silently replacing one capture.
    nonisolated private static func writeWithoutOverwriting(_ data: Data,
                                                in dirURL: URL,
                                                filename: String,
                                                beforePublish: () throws -> Void) throws -> URL {
        try beforePublish()
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dirURL.appendingPathComponent(filename)
        var counter = 2

        while true {
            do {
                let transaction = try AtomicMediaSave(destinationURL: candidate)
                try data.write(to: transaction.stagingURL)
                // Exclusive rename arbitrates concurrent saves of the same name.
                try transaction.commit(overwritingExisting: false)
                return candidate
            } catch {
                let nsError = error as NSError
                guard (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EEXIST)) ||
                      (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.fileWriteFileExists.rawValue) else {
                    throw error
                }
                if counter < 1000 {
                    let nextName = ext.isEmpty
                        ? "\(base) (\(counter))"
                        : "\(base) (\(counter)).\(ext)"
                    candidate = dirURL.appendingPathComponent(nextName)
                    counter += 1
                } else {
                    // UUID collisions are extraordinarily unlikely, but the
                    // loop deliberately retries even that case so this method
                    // maintains a strict no-overwrite guarantee.
                    let uuidName = ext.isEmpty
                        ? "\(base) \(UUID().uuidString)"
                        : "\(base) \(UUID().uuidString).\(ext)"
                    candidate = dirURL.appendingPathComponent(uuidName)
                }
            }
        }
    }

    @MainActor
    private static func copyFilePathToClipboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.standardizedFileURL.path, forType: .string)
    }

    private static func completionOnMain(_ completion: Completion?, _ success: Bool) {
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(success)
        }
    }
}
