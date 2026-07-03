import Foundation

/// Retained backing files for pasteboard file-URL representations.
///
/// Clipboard history tools may keep the file URL from the pasteboard and read it
/// later. Keep these files independent from `/tmp` and from screenshot history so
/// old clipboard entries do not break on the next capture.
enum ClipboardBackingStore {
    private static let subdirectory = "clipboard"
    private static let maxFiles = 100
    private static let ttl: TimeInterval = 7 * 24 * 60 * 60

    static let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("com.sw33tlie.macshot", isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return dir
    }()

    static func writeImageData(_ data: Data) -> URL? {
        let url = makeUniqueURL(fileExtension: "png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    @discardableResult
    static func cleanup() -> DirectorySweeper.Result {
        var result = DirectorySweeper.sweep(
            directory: directory,
            olderThan: ttl,
            shouldDelete: { _ in true }
        )

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return result }

        let files = contents.compactMap { url -> (url: URL, modified: Date, size: UInt64)? in
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
            ]), values.isRegularFile == true else { return nil }
            return (
                url,
                values.contentModificationDate ?? .distantPast,
                UInt64(values.fileSize ?? 0)
            )
        }
        .sorted { lhs, rhs in lhs.modified > rhs.modified }

        for file in files.dropFirst(maxFiles) {
            if (try? fm.removeItem(at: file.url)) != nil {
                result.removed += 1
                result.bytesFreed += file.size
            }
        }

        return result
    }

    private static func makeUniqueURL(fileExtension: String) -> URL {
        let filename = FilenameFormatter.defaultImageFilename(fileExtension: fileExtension)
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
            if counter > 1000 {
                return directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            }
        }
        return candidate
    }
}
