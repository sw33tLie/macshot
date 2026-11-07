import Foundation
import Darwin

enum FeedbackSkillInstaller {
    static func install(arguments: [String]) throws {
        guard arguments.first == "install" else {
            fail("Use: macshot-cli skill install --target codex|claude|antigravity [--directory /absolute/skills] [--handoff /absolute/macshot-ai]", code: 2)
        }
        var options: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard ["--target", "--directory", "--handoff"].contains(key),
                  options[key] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else {
                fail("Invalid or duplicate skill install option: \(key)", code: 2)
            }
            options[key] = arguments[index + 1]
            index += 2
        }
        let locations = ["codex": ".agents/skills", "claude": ".claude/skills", "antigravity": ".gemini/config/skills"]
        guard let target = options["--target"], let location = locations[target] else {
            fail("--target must be codex, claude, or antigravity.", code: 2)
        }
        let parent: URL
        if let custom = options["--directory"] { parent = try absolute(custom) }
        else { parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(location, isDirectory: true) }
        guard let executable = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            fail("Cannot locate this CLI executable.", code: 2)
        }
        var config = ["cli": executable.resolvingSymlinksInPath().path]
        if let path = options["--handoff"]
            ?? ProcessInfo.processInfo.environment["MACSHOT_FEEDBACK_HANDOFF"]
            ?? configuredHandoff(executable: executable) {
            let handoff = try absolute(path)
            try FeedbackSessionFiles.check(handoff, directory: true)
            config["handoff"] = handoff.path
        }
        let fm = FileManager.default
        let destination = parent.appendingPathComponent("macshot-feedback", isDirectory: true)
        guard !fm.fileExists(atPath: destination.path),
              (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            fail("Skill already exists; nothing was overwritten: \(destination.path)", code: 2)
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".macshot-feedback-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("references"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(FeedbackSkillTemplate.markdown.utf8).write(to: staging.appendingPathComponent("SKILL.md"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: staging.appendingPathComponent("references/local.json"))
        // Publish the complete skill atomically without replacing an existing directory.
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try jsonPrint(["state": "installed", "target": target, "skill": "macshot-feedback", "directory": destination.path])
        let message = config["handoff"] == nil
            ? "No handoff folder recorded in references/local.json. If Settings already shows one, move this skill aside and reinstall with --handoff \"/absolute/macshot-ai\".\n"
            : "Handoff folder recorded; macshot must authorize this same folder in Settings > Capture > AI Collaboration.\n"
        FileHandle.standardError.write(Data((message + "Reload skills or start a new agent session if macshot-feedback is not visible.\n").utf8))
    }

    private static func configuredHandoff(executable: URL) -> String? {
        let app = executable.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let bundleID = Bundle(url: app)?.bundleIdentifier,
              let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let preferences = library.appendingPathComponent("Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
        guard let data = try? Data(contentsOf: preferences),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return values["feedbackHandoffPath"] as? String
    }
}
