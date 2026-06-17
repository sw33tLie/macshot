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

enum ImageSaveService {
    typealias Completion = (Bool) -> Void

    static func save(
        _ image: NSImage,
        using action: SaveActionPreference = .current,
        windowTitle: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        activateApp: Bool = true,
        completion: Completion? = nil
    ) {
        switch action {
        case .saveToFolder:
            saveToConfiguredFolder(
                image,
                windowTitle: windowTitle,
                panelLevel: panelLevel,
                sheetWindow: sheetWindow,
                activateApp: activateApp,
                completion: completion)
        case .askWhereToSave:
            showSavePanel(
                for: image,
                windowTitle: windowTitle,
                panelLevel: panelLevel,
                sheetWindow: sheetWindow,
                activateApp: activateApp,
                completion: completion)
        }
    }

    static func saveToConfiguredFolder(
        _ image: NSImage,
        windowTitle: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        activateApp: Bool = true,
        completion: Completion? = nil
    ) {
        let filename = defaultFilename(windowTitle: windowTitle)
        if let dirURL = SaveDirectoryAccess.resolveIfAccessible() {
            writeImage(image, toDirectory: dirURL, filename: filename, securityScoped: true, completion: completion)
            return
        }

        requestSaveDirectoryAccess(
            panelLevel: panelLevel,
            sheetWindow: sheetWindow,
            activateApp: activateApp
        ) { dirURL, securityScoped in
            writeImage(image, toDirectory: dirURL, filename: filename, securityScoped: securityScoped, completion: completion)
        }
    }

    static func showSavePanel(
        for image: NSImage,
        suggestedFilename: String? = nil,
        windowTitle: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        activateApp: Bool = true,
        completion: Completion? = nil
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ImageEncoder.utType]
        panel.nameFieldStringValue = suggestedFilename ?? defaultFilename(windowTitle: windowTitle)
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let panelLevel {
            panel.level = panelLevel
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url, let imageData = ImageEncoder.encode(image) else {
                completionOnMain(completion, false)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try imageData.write(to: url)
                    completionOnMain(completion, true)
                } catch {
                    #if DEBUG
                    NSLog("macshot: failed to save screenshot to \(url.path): \(error.localizedDescription)")
                    #endif
                    completionOnMain(completion, false)
                }
            }
        }

        presentPanel(panel, sheetWindow: sheetWindow, activateApp: activateApp, completionHandler: handler)
    }

    private static func defaultFilename(windowTitle: String?) -> String {
        let template = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        let base = FilenameFormatter.format(template: template, windowTitle: windowTitle)
        return "\(base).\(ImageEncoder.fileExtension)"
    }

    private static func writeImage(
        _ image: NSImage,
        toDirectory dirURL: URL,
        filename: String,
        securityScoped: Bool,
        completion: Completion?
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if securityScoped { SaveDirectoryAccess.stopAccessing(url: dirURL) } }
            guard let imageData = ImageEncoder.encode(image) else {
                completionOnMain(completion, false)
                return
            }

            let fileURL = uniqueFileURL(in: dirURL, filename: filename)
            do {
                try imageData.write(to: fileURL)
                completionOnMain(completion, true)
            } catch {
                #if DEBUG
                NSLog("macshot: failed to save screenshot to \(fileURL.path): \(error.localizedDescription)")
                #endif
                completionOnMain(completion, false)
            }
        }
    }

    private static func requestSaveDirectoryAccess(
        panelLevel: NSWindow.Level?,
        sheetWindow: NSWindow?,
        activateApp: Bool,
        completion: @escaping (URL, Bool) -> Void
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
            guard response == .OK, let url = panel.url else { return }
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

    private static func uniqueFileURL(in dirURL: URL, filename: String) -> URL {
        var candidate = dirURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 2
        while counter < 1000 {
            let nextName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = dirURL.appendingPathComponent(nextName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
        return candidate
    }

    private static func completionOnMain(_ completion: Completion?, _ success: Bool) {
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(success)
        }
    }
}
