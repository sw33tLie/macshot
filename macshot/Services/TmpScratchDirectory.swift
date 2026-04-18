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

    /// Build a URL inside the scratch dir with the given filename.
    /// Callers write their data here.
    static func makeURL(filename: String) -> URL {
        return url.appendingPathComponent(filename)
    }
}
