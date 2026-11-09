import Foundation

/// Original takes live outside temporary storage. Saving, closing an editor,
/// launch cleanup, and a failed export must not delete the only recording.
struct RecordingSessionStore: Sendable {
    let directoryURL: URL
    let mediaURL: URL
    private let createdAt: Date

    #if VIDEO_EDITOR_PROBE
    /// The isolated UI probe points the recording library at its fixtures.
    nonisolated(unsafe) static var probeRoot: URL?
    #endif

    nonisolated static var rootURL: URL {
        #if VIDEO_EDITOR_PROBE
        if let probeRoot { return probeRoot }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("com.sw33tlie.macshot/Recordings", isDirectory: true)
    }

    nonisolated static func owns(_ url: URL, root: URL = Self.rootURL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
            root.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    nonisolated init(filename: String, root: URL = Self.rootURL) throws {
        directoryURL = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Configuration can also come from an internal driver. Treat its name
        // as a display name, never as a relative path outside this session.
        let cleaned = FilenameSanitizer.sanitize(filename)
        let name = cleaned.isEmpty ? "Recording" : cleaned
        mediaURL = directoryURL.appendingPathComponent(name + ".mp4")
        createdAt = Date()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        do { try update(status: "recording", error: nil) }
        catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    /// The small, versioned property list remains readable even if a new
    /// version adds fields. Media never depends on successfully decoding it.
    nonisolated func update(status: String, error: Error?) throws {
        var metadata: [String: Any] = ["version": 1, "createdAt": createdAt,
            "filename": mediaURL.lastPathComponent, "status": status]
        if let error = error { metadata["error"] = error.localizedDescription }
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: directoryURL.appendingPathComponent("session.plist"), options: .atomic)
    }

    /// Only startup cancellation before any media file exists may remove an
    /// empty session. Once bytes exist, retain them for recovery.
    nonisolated func removeIfEmpty() {
        guard !FileManager.default.fileExists(atPath: mediaURL.path) else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
