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
        }
    }

    /// Resolve the save directory URL and start sandbox-scoped access.
    /// Caller **must** call `stopAccessing(url:)` when done writing.
    static func resolve() -> URL {
        if let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData,
                                   options: .withSecurityScope,
                                   relativeTo: nil,
                                   bookmarkDataIsStale: &isStale) {
                if isStale {
                    if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
                        UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                    }
                }
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
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

    /// The display path for the preferences UI.
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

    static var hasRecordingDirectory: Bool {
        UserDefaults.standard.string(forKey: recPathKey) != nil
    }

    /// Resolve recording save directory. Falls back to general save directory.
    static func resolveRecordingDirectory() -> URL {
        if let bookmarkData = UserDefaults.standard.data(forKey: recBookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData,
                                   options: .withSecurityScope,
                                   relativeTo: nil,
                                   bookmarkDataIsStale: &isStale) {
                if isStale {
                    if let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
                        UserDefaults.standard.set(fresh, forKey: recBookmarkKey)
                    }
                }
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        if let path = UserDefaults.standard.string(forKey: recPathKey) {
            return URL(fileURLWithPath: path)
        }
        return resolve()
    }

    static func recordingDirectoryHint() -> URL? {
        if let path = UserDefaults.standard.string(forKey: recPathKey) {
            return URL(fileURLWithPath: path)
        }
        return directoryHint()
    }

    static var recordingDisplayPath: String {
        UserDefaults.standard.string(forKey: recPathKey) ?? "Same as screenshots"
    }
}
