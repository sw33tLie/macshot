import Foundation

// MARK: - DirectorySweeper
//
// One place that knows how to walk a directory, read modification times,
// and delete files older than a TTL that pass a caller-supplied filter.
// Every cleanup we do at launch boils down to this operation — sharing
// the implementation keeps each cleaner down to declarative config.

enum DirectorySweeper {

    /// Result of a sweep, handy for logging.
    struct Result {
        var removed: Int = 0
        var bytesFreed: UInt64 = 0
    }

    /// Walk `directory` (no recursion), and delete regular files that
    /// satisfy `shouldDelete`. When `olderThan` is non-nil, files
    /// modified more recently than `now - olderThan` are skipped so
    /// in-flight writes can't get clobbered. Returns counts for logging.
    ///
    /// - Parameters:
    ///   - directory: Directory to scan. Missing directory → empty result.
    ///   - olderThan: Age gate. Pass nil to skip the age check entirely
    ///     (e.g. when using an independent signal like "orphaned from
    ///     an index file").
    ///   - shouldDelete: Filter run on the filename (last path component
    ///     only). Return true to include the file, false to leave it.
    @discardableResult
    static func sweep(directory: URL,
                      olderThan ttl: TimeInterval?,
                      shouldDelete: (String) -> Bool) -> Result {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return Result() }

        let cutoff: Date? = ttl.map { Date().addingTimeInterval(-$0) }
        var result = Result()

        for url in contents {
            guard shouldDelete(url.lastPathComponent) else { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
            ]) else { continue }
            guard values.isRegularFile == true else { continue }
            if let cutoff = cutoff {
                guard let modified = values.contentModificationDate,
                      modified < cutoff else { continue }
            }

            let size = UInt64(values.fileSize ?? 0)
            if (try? fm.removeItem(at: url)) != nil {
                result.removed += 1
                result.bytesFreed += size
            }
        }
        return result
    }
}

// MARK: - LaunchCleaner

/// One discrete cleanup task that runs at app launch. Each implementation
/// encodes a single rule ("sweep X older than Y") and nothing else —
/// add a new cleaner by conforming, then registering in `LaunchCleanup.all`.
protocol LaunchCleaner {
    /// Short name used for debug logging.
    var name: String { get }
    /// Do the work. Expected to run quickly (I/O only) and return. The
    /// caller dispatches to a background queue, so implementations are
    /// free to block.
    func sweep() -> DirectorySweeper.Result
}

// MARK: - Registry

enum LaunchCleanup {

    /// All cleaners that should run on launch. Order doesn't matter.
    /// Adding a new leak handler is a one-line addition here plus a new
    /// `LaunchCleaner`-conforming type.
    static let all: [LaunchCleaner] = [
        TmpFileCleaner(),
        ScratchDirectoryCleaner(),
        ClipboardDirectoryCleaner(),
    ]

    /// Run every cleaner off the main thread. Safe to call from
    /// `applicationDidFinishLaunching`.
    static func runAll() {
        DispatchQueue.global(qos: .utility).async {
            for cleaner in all {
                let result = cleaner.sweep()
                #if DEBUG
                if result.removed > 0 {
                    print("[\(cleaner.name)] removed \(result.removed) files, freed \(result.bytesFreed) bytes")
                }
                #endif
            }
        }
    }
}

// MARK: - Concrete cleaners

/// Sweeps macshot-owned files from `NSTemporaryDirectory()` that match
/// known stale patterns — legacy UUID-named clipboard PNGs, date-named
/// captures, microphone scratch, debug logs, upload intermediates,
/// UUID-named GIF/MP4 scratch files, and macOS sandbox quarantine stubs.
///
/// Preserves:
///   - `macshot-clipboard.png` and `macshot-clipboard-recording.*`
///     (fixed paths that are always-overwritten by design).
///   - `Recording *` files (user-visible when `recordingOnStop = "finder"`;
///     auto-deleting would silently lose their recording).
///
/// 24-hour TTL so in-flight operations can't get clobbered.
private struct TmpFileCleaner: LaunchCleaner {
    let name = "TmpFileCleaner"

    /// One day — long enough to cover "copied yesterday, paste today"
    /// and short enough that abandoned temporaries don't accumulate.
    private let ttl: TimeInterval = 24 * 60 * 60

    /// Filename prefixes we know are ours. The `macshot-clipboard-`
    /// prefix here is intentional to catch the *legacy* UUID-named form
    /// from pre-fix builds; the current single-file `macshot-clipboard.png`
    /// is explicitly preserved in the filter below.
    ///
    /// "Recording " is included now that every `recordingOnStop` branch
    /// either moves the file out of tmp (editor save / finder reveal) or
    /// replaces it at a fixed path (clipboard). Any `Recording *` still
    /// in tmp after 24 hours was definitely abandoned — e.g. the user
    /// cancelled the Save panel on the finder path, or the app crashed
    /// mid-editor-session before `deleteOnClose` fired.
    private let stalePrefixes: [String] = [
        "macshot-clipboard-",
        "macshot_upload_",
        "macshot_mic_",
        "macshot_cursor_debug",
        "macshot_",
        "Recording ",
    ]

    /// Extensions that, when paired with a UUID basename, are our scratch
    /// output (GIF conversion, video re-encode).
    private let uuidScratchExtensions: Set<String> = ["gif", "mp4"]

    func sweep() -> DirectorySweeper.Result {
        return DirectorySweeper.sweep(
            directory: FileManager.default.temporaryDirectory,
            olderThan: ttl,
            shouldDelete: isStale(name:)
        )
    }

    private func isStale(name: String) -> Bool {
        // Preserve always-overwritten fixed paths.
        if name == "macshot-clipboard.png" { return false }
        if name.hasPrefix("macshot-clipboard-recording.") { return false }

        if stalePrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        if isUUIDScratchFile(name: name) { return true }
        if isSandboxQuarantineFile(name: name) { return true }
        return false
    }

    /// "<UUID>.gif" / "<UUID>.mp4" — scratch tmps from GIF conversion and
    /// video re-encode paths.
    private func isUUIDScratchFile(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard uuidScratchExtensions.contains(ext) else { return false }
        let base = (name as NSString).deletingPathExtension
        return UUID(uuidString: base) != nil
    }

    /// "<UUID>.gif.sb-XXXX-YYYY" — macOS sandbox write-quarantine stubs.
    /// They only appear in our container, so always safe to clean.
    private func isSandboxQuarantineFile(name: String) -> Bool {
        guard name.contains(".sb-") else { return false }
        guard let firstDot = name.firstIndex(of: ".") else { return false }
        return UUID(uuidString: String(name[..<firstDot])) != nil
    }
}

/// Sweeps everything in `tmp/macshot-share/` older than 5 minutes.
/// That subfolder is exclusively used for drag-to-Finder and
/// share-sheet scratch files whose names follow the user-configured
/// filename template (so they can't be pattern-matched reliably). The
/// 5-minute TTL is far longer than any share/drag in practice.
private struct ScratchDirectoryCleaner: LaunchCleaner {
    let name = "ScratchDirectoryCleaner"
    private let ttl: TimeInterval = 5 * 60

    func sweep() -> DirectorySweeper.Result {
        return DirectorySweeper.sweep(
            directory: TmpScratchDirectory.url,
            olderThan: ttl,
            shouldDelete: { _ in true }
        )
    }
}

/// Sweeps everything in `tmp/macshot-clipboard/` older than 24 hours.
///
/// `ImageEncoder.copyToClipboard` writes a date-stamped PNG here and
/// deletes the previous one on the next copy — at most one file ever
/// lives here during normal use. This sweeper is a backstop for the
/// case where macshot crashed or force-quit between writes, leaving an
/// orphan. 24h TTL so we never race with a file that's currently
/// referenced on the pasteboard.
private struct ClipboardDirectoryCleaner: LaunchCleaner {
    let name = "ClipboardDirectoryCleaner"
    private let ttl: TimeInterval = 24 * 60 * 60

    func sweep() -> DirectorySweeper.Result {
        return DirectorySweeper.sweep(
            directory: ImageEncoder.clipboardTmpDirectory,
            olderThan: ttl,
            shouldDelete: { _ in true }
        )
    }
}
