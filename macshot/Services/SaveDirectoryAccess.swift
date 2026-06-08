import Foundation

/// Manages security-scoped bookmark access for the user-chosen save directory.
/// In sandbox mode, a raw file path is not enough — we need a bookmark that the
/// system can resolve to regrant access across app launches.
enum SaveDirectoryAccess {

    private static let bookmarkKey = "saveDirectoryBookmark"
    private static let pathKey = "saveDirectory"

    /// Save both the path (for display) and the security-scoped bookmark (for sandbox access).
    static func save(url: URL) {
        UserDefaults.standard.set(url.path, forKey: pathKey)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } else {
            // Bookmark creation failed — clear any stale bookmark so we don't
            // keep granting access to an old folder that no longer matches path.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    /// Resolve the configured save directory, starting sandbox-scoped access,
    /// but return `nil` when no valid security-scoped bookmark exists. Use this
    /// for writes that must succeed in the sandbox — `nil` means the caller
    /// should prompt the user to choose a folder. Mirrors
    /// `resolveRecordingDirectoryIfAccessible()`.
    /// Caller **must** call `stopAccessing(url:)` when done writing.
    static func resolveIfAccessible() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    /// Resolve the save directory URL and start sandbox-scoped access.
    /// Caller **must** call `stopAccessing(url:)` when done writing.
    ///
    /// ⚠️ This **always** returns a URL, falling back to the stored raw path or
    /// `~/Pictures` when no bookmark exists — but that fallback has **no**
    /// sandbox write access, so `write(to:)` will fail. Prefer
    /// `resolveIfAccessible()` for writes that must work in the sandbox.
    static func resolve() -> URL {
        if let url = resolveIfAccessible() { return url }
        if let path = UserDefaults.standard.string(forKey: pathKey) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Resolve the directory URL **without** starting scoped access.
    /// Use this for NSSavePanel/NSOpenPanel `directoryURL` hints — they handle
    /// their own sandbox access via powerbox.
    static func directoryHint() -> URL? {
        if let path = UserDefaults.standard.string(forKey: pathKey) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
    }

    /// Stop accessing the security-scoped resource after writing is complete.
    static func stopAccessing(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// The display path for the settings UI.
    static var displayPath: String {
        UserDefaults.standard.string(forKey: pathKey) ?? "~/Pictures"
    }

    // MARK: - Recording save directory (optional, falls back to general)

    private static let recBookmarkKey = "recordingSaveDirectoryBookmark"
    private static let recPathKey = "recordingSaveDirectory"

    static func saveRecordingDirectory(url: URL) {
        UserDefaults.standard.set(url.path, forKey: recPathKey)
        if let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: recBookmarkKey)
        }
    }

    static func clearRecordingDirectory() {
        UserDefaults.standard.removeObject(forKey: recPathKey)
        UserDefaults.standard.removeObject(forKey: recBookmarkKey)
    }

    /// Like resolveRecordingDirectory(), but returns nil if no valid security-scoped bookmark exists.
    /// Use this to decide whether to fall back to a Save As panel.
    static func resolveRecordingDirectoryIfAccessible() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: recBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: recBookmarkKey)
            }
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    static func recordingDirectoryHint() -> URL? {
        if let path = UserDefaults.standard.string(forKey: recPathKey) {
            return URL(fileURLWithPath: path)
        }
        return directoryHint()
    }

    static var recordingDisplayPath: String {
        UserDefaults.standard.string(forKey: recPathKey) ?? L("Same as screenshots")
    }
}
