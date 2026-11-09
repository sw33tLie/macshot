import Foundation

/// A dedicated tmp subdirectory for short-lived share/drag files.
///
/// Drag-to-Finder and share-sheet flows write a file to tmp with the
/// user-configured filename (e.g. "Screenshot 2026-04-18.png") so the
/// destination app gets a recognizable name. The file has to exist as a
/// *real* file URL — we can't use raw data for drag — but there's no
/// deterministic signal for "drop accepted, safe to delete." Delegate
/// callbacks fire too early for some targets (they read the file
/// *after* the callback in their own async handler).
///
/// Solution: isolate these writes in a subfolder we 100% own, then let
/// `LaunchCleanup.runAll()` sweep the whole folder. Anything older than
/// a few minutes is definitely not being read any more.
enum TmpScratchDirectory {

    /// Path to the scratch subfolder. Created lazily on first access.
    static let url: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-share")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    /// Build a URL inside the scratch dir with the given filename, in its own
    /// subfolder so two shares can't collide.
    ///
    /// The destination app sees the filename the user configured, but a second
    /// share of the same name no longer overwrites the first — which used to
    /// swap the attachment under an open Mail draft whenever two captures
    /// rendered the same name (easy with a `{date}`-only template, and possible
    /// with the default one for two captures in the same second).
    static func makeURL(filename: String) -> URL {
        let safeName = filename.isEmpty ? "macshot" : filename
        let container = url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container.appendingPathComponent(safeName)
    }
}
