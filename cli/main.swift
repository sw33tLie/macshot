import AppKit
import ImageIO
import Security
import Darwin

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func option(_ key: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: key), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func absolute(_ path: String?) throws -> URL {
    guard let path, path.hasPrefix("/") else { throw FeedbackError.invalidSession }
    return URL(fileURLWithPath: path).standardizedFileURL
}

func jsonPrint<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func appURL() throws -> URL {
    if let path = option("--app") { return try absolute(path) }
    let embedded = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if embedded.pathExtension == "app" { return embedded }
    let bundleID = CommandLine.arguments.contains("--offline") ? "com.sw33tlie.macshot.offline" : "com.sw33tlie.macshot.macshot"
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        fail("Cannot find macshot. Pass --app /absolute/macshot.app.")
    }
    return url
}

do {
    let command = CommandLine.arguments.dropFirst().first ?? "help"
    if command == "help" || command == "--help" {
        print("""
        macshot-cli annotate /absolute/image.png --output /absolute/round/feedback.json
          --handoff /absolute/macshot-ai [--timeout 1800] [--app /absolute/macshot.app] [--offline]
        macshot-cli capture --output /absolute/round/feedback.json
          --handoff /absolute/macshot-ai [--timeout 1800] [--app /absolute/macshot.app] [--offline]
        macshot-cli version [--app /absolute/macshot.app]
        macshot-cli skill install --target codex|claude|antigravity
          [--directory /absolute/skills] [--handoff /absolute/macshot-ai]
        If references/local.json has no handoff, copy the folder shown in
        Settings > Capture > AI Collaboration, move the existing skill aside, then run:
          macshot-cli skill install --target codex --handoff "/absolute/macshot-ai"
        Choose the same private handoff folder in macshot first. Output parent must already exist.
        Exit codes: 0 submitted, 2 failed/invalid input, 3 timed out, 4 cancelled.
        """)
        exit(0)
    }
    if command == "skill" {
        try FeedbackSkillInstaller.install(arguments: Array(CommandLine.arguments.dropFirst(2)))
        exit(0)
    }
    let app = try appURL()
    if command == "version" {
        let bundle = Bundle(url: app)
        try jsonPrint(["version": bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                       "build": bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                       "app": app.path, "protocol": "1"])
        exit(0)
    }
    guard command == "annotate" || command == "capture" else { fail("Unknown command. Use --help.", code: 2) }
    let input = command == "annotate" ? try absolute(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil) : nil
    // Capture has no positional image argument; reject typos before creating a session.
    let captureArguments = Array(CommandLine.arguments.dropFirst(2))
    if command == "capture" {
        var seen = Set<String>()
        var index = 0
        while index < captureArguments.count {
            let key = captureArguments[index]
            guard seen.insert(key).inserted else { fail("Duplicate capture option: \(key)", code: 2) }
            if key == "--offline" { index += 1; continue }
            guard ["--handoff", "--output", "--timeout", "--app"].contains(key),
                  index + 1 < captureArguments.count, !captureArguments[index + 1].hasPrefix("--") else {
                fail("Invalid capture option: \(key)", code: 2)
            }
            index += 2
        }
    }
    let root = try absolute(option("--handoff") ?? ProcessInfo.processInfo.environment["MACSHOT_FEEDBACK_HANDOFF"])
    let output = try absolute(option("--output"))
    guard output.lastPathComponent == "feedback.json" else { fail("--output must end in feedback.json", code: 2) }
    let destination = output.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        fail("Output parent must already exist.", code: 2)
    }
    let names = ["source.png", "preview.png", "feedback.md", "feedback.json"]
    guard names.allSatisfy({ !FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path) }) else { throw FeedbackError.outputExists }
    let timeout = Double(option("--timeout") ?? "1800") ?? 0
    guard timeout >= 1, timeout <= 86_400 else { fail("--timeout must be between 1 and 86400 seconds", code: 2) }
    try FeedbackSessionFiles.check(root, directory: true)
    var expectedSize: (width: Int, height: Int)?
    if let input {
        let properties = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= 128_000_000 else { throw FeedbackError.invalidImage }
        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0, w <= 32_768, h <= 32_768, w*h <= 100_000_000 else { throw FeedbackError.invalidImage }
        expectedSize = (w, h)
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fail("Cannot create session token.") }
    let request = FeedbackRequest(version: 1, session: UUID(), token: bytes.map { String(format: "%02x", $0) }.joined(),
                                  deadline: Date().timeIntervalSince1970 + timeout, mode: command == "capture" ? .capture : nil)
    let folder = root.appendingPathComponent(request.session.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    if let input {
        let inputCopy = folder.appendingPathComponent("input.png")
        try FileManager.default.copyItem(at: input, to: inputCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputCopy.path)
    }
    try FeedbackExport.publish(JSONEncoder().encode(request), to: folder.appendingPathComponent("request.json"))
    let cancel = {
        try? FeedbackExport.publish(JSONEncoder().encode(request), to: folder.appendingPathComponent("cancel.json"))
    }
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { cancel(); exit(4) }; interrupt.resume()
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    terminate.setEventHandler { cancel(); exit(4) }; terminate.resume()
    let url = URL(string: "macshot://feedback?session=\(request.session.uuidString)")!
    let config = NSWorkspace.OpenConfiguration()
    config.activates = command != "capture"
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, error in
        if let error { cancel(); fail(error.localizedDescription, code: 2) }
    }
    while true {
        let resultURL = folder.appendingPathComponent("result.json")
        if FileManager.default.fileExists(atPath: resultURL.path) {
            let receipt = try FeedbackSessionFiles.read(FeedbackReceipt.self, at: resultURL)
            guard receipt.version == 1, receipt.session == request.session, receipt.token == request.token else { throw FeedbackError.invalidSession }
            switch receipt.state {
            case .cancelled: try jsonPrint(receipt); exit(4)
            case .timedOut: try jsonPrint(receipt); exit(3)
            case .failed: try jsonPrint(receipt); exit(2)
            case .submitted:
                let feedbackURL = folder.appendingPathComponent("feedback.json")
                try FeedbackSessionFiles.check(feedbackURL, directory: false, maximumBytes: 16_000_000)
                let feedback = try JSONDecoder().decode(FeedbackDocument.self, from: Data(contentsOf: feedbackURL)).validated()
                if let expectedSize {
                    guard feedback.width == expectedSize.width, feedback.height == expectedSize.height else { throw FeedbackError.invalidDocument }
                }
                let sourceURL = folder.appendingPathComponent("source.png")
                try FeedbackSessionFiles.check(sourceURL, directory: false)
                let sourceImage = try FeedbackExport.loadImage(sourceURL)
                guard feedback.width == sourceImage.width, feedback.height == sourceImage.height else { throw FeedbackError.invalidDocument }
                var copied: [URL] = []
                do {
                    for name in names {
                        let source = folder.appendingPathComponent(name)
                        try FeedbackSessionFiles.check(source, directory: false)
                        let target = destination.appendingPathComponent(name)
                        try FeedbackExport.publish(Data(contentsOf: source), to: target)
                        copied.append(target)
                    }
                } catch { for url in copied { try? FileManager.default.removeItem(at: url) }; throw error }
                try jsonPrint(["state": "submitted", "session": request.session.uuidString, "feedback": output.path])
                exit(0)
            }
        }
        if Date().timeIntervalSince1970 >= request.deadline {
            cancel(); fail("Feedback session timed out. Unsubmitted notes remain a draft.", code: 3)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
} catch { fail(error.localizedDescription, code: 2) }
