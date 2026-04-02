import Cocoa

struct HistoryEntry {
    let id: String           // UUID filename (without extension)
    let fileExtension: String // "png" or "jpg"
    let timestamp: Date
    let pixelWidth: Int
    let pixelHeight: Int
    var thumbnail: NSImage?  // lazily cached, tiny

    var timeAgoString: String {
        let seconds = Int(-timestamp.timeIntervalSinceNow)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: timestamp)
    }
}

class ScreenshotHistory {

    static let shared = ScreenshotHistory()

    private(set) var entries: [HistoryEntry] = []

    private let historyDir: URL
    private let indexFile: URL

    var maxEntries: Int {
        if let stored = UserDefaults.standard.object(forKey: "historySize") as? Int {
            return stored
        }
        return 10  // default
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        historyDir = appSupport.appendingPathComponent("com.sw33tlie.macshot/history")
        indexFile = historyDir.appendingPathComponent("index.json")

        // Create directory with 0700 permissions (owner only)
        if !FileManager.default.fileExists(atPath: historyDir.path) {
            try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }

        loadIndex()
    }

    // MARK: - Public API

    func add(image: NSImage) {
        let max = maxEntries
        guard max > 0 else { return }

        let id = UUID().uuidString
        let ext = "png"

        // Generate thumbnail on the main thread (needs NSImage, quick operation)
        let thumb = makeThumbnail(image: image, maxWidth: 36)
        let size = image.size
        let scale: CGFloat = ImageEncoder.downscaleRetina ? 1.0 : (NSScreen.main?.backingScaleFactor ?? 2.0)

        let entry = HistoryEntry(
            id: id,
            fileExtension: ext,
            timestamp: Date(),
            pixelWidth: Int(size.width * scale),
            pixelHeight: Int(size.height * scale),
            thumbnail: thumb
        )
        entries.insert(entry, at: 0)

        // Prune oldest entries beyond max
        while entries.count > max {
            let removed = entries.removeLast()
            deleteFiles(for: removed.id, ext: removed.fileExtension)
        }

        saveIndex()

        // PNG encode + disk write on background thread (the expensive part)
        let fileURL = historyDir.appendingPathComponent("\(id).\(ext)")
        let thumbURL = historyDir.appendingPathComponent("\(id)_thumb.png")
        DispatchQueue.global(qos: .utility).async {
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let imageData = bitmap.representation(using: .png, properties: [:]) {
                try? imageData.write(to: fileURL, options: .atomic)
            }
            if let thumbTiff = thumb.tiffRepresentation,
               let thumbBitmap = NSBitmapImageRep(data: thumbTiff),
               let thumbPng = thumbBitmap.representation(using: .png, properties: [:]) {
                try? thumbPng.write(to: thumbURL, options: .atomic)
            }
        }
    }

    /// Add a GIF recording to history by copying the file and extracting a thumbnail from the first frame.
    func addRecording(url: URL) {
        let max = maxEntries
        guard max > 0 else { return }

        let ext = url.pathExtension.lowercased()
        guard ext == "gif" else { return }  // only GIF for now — MP4 thumbnails need AVAsset

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }

        let id = UUID().uuidString
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let thumb = makeThumbnail(image: image, maxWidth: 36)

        let entry = HistoryEntry(
            id: id,
            fileExtension: ext,
            timestamp: Date(),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            thumbnail: thumb
        )
        entries.insert(entry, at: 0)

        while entries.count > max {
            let removed = entries.removeLast()
            deleteFiles(for: removed.id, ext: removed.fileExtension)
        }
        saveIndex()

        // Copy GIF + save thumbnail on background thread
        let destURL = historyDir.appendingPathComponent("\(id).\(ext)")
        let thumbURL = historyDir.appendingPathComponent("\(id)_thumb.png")
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.copyItem(at: url, to: destURL)
            if let thumbTiff = thumb.tiffRepresentation,
               let thumbBitmap = NSBitmapImageRep(data: thumbTiff),
               let thumbPng = thumbBitmap.representation(using: .png, properties: [:]) {
                try? thumbPng.write(to: thumbURL, options: .atomic)
            }
        }
    }

    func pruneToMax() {
        let max = maxEntries
        if max <= 0 {
            clear()
        } else {
            while entries.count > max {
                let removed = entries.removeLast()
                deleteFiles(for: removed.id, ext: removed.fileExtension)
            }
            saveIndex()
        }
    }

    func clear() {
        for entry in entries {
            deleteFiles(for: entry.id, ext: entry.fileExtension)
        }
        entries.removeAll()
        saveIndex()
    }

    func copyEntry(at index: Int) {
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        let fileURL = historyDir.appendingPathComponent("\(entry.id).\(entry.fileExtension)")
        guard let imageData = try? Data(contentsOf: fileURL),
              let image = NSImage(data: imageData) else { return }
        ImageEncoder.copyToClipboard(image)
    }

    func loadImage(for entry: HistoryEntry) -> NSImage? {
        let fileURL = historyDir.appendingPathComponent("\(entry.id).\(entry.fileExtension)")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }

    func loadThumbnail(for entry: HistoryEntry) -> NSImage? {
        if let thumb = entry.thumbnail { return thumb }
        let thumbURL = historyDir.appendingPathComponent("\(entry.id)_thumb.png")
        return NSImage(contentsOf: thumbURL)
    }

    // MARK: - Persistence

    private struct IndexEntry: Codable {
        let id: String
        let fileExtension: String
        let timestamp: Date
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private func saveIndex() {
        let indexEntries = entries.map { IndexEntry(id: $0.id, fileExtension: $0.fileExtension, timestamp: $0.timestamp, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight) }
        if let data = try? JSONEncoder().encode(indexEntries) {
            try? data.write(to: indexFile, options: .atomic)
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFile),
              let indexEntries = try? JSONDecoder().decode([IndexEntry].self, from: data) else { return }

        entries = indexEntries.compactMap { ie in
            // Only include entries whose image file still exists
            let ext = ie.fileExtension
            let fileURL = historyDir.appendingPathComponent("\(ie.id).\(ext)")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return HistoryEntry(id: ie.id, fileExtension: ext, timestamp: ie.timestamp, pixelWidth: ie.pixelWidth, pixelHeight: ie.pixelHeight, thumbnail: nil)
        }

        // Prune if maxEntries was lowered since last run
        let max = maxEntries
        if max <= 0 {
            clear()
        } else {
            while entries.count > max {
                let removed = entries.removeLast()
                deleteFiles(for: removed.id, ext: removed.fileExtension)
            }
            if entries.count < indexEntries.count {
                saveIndex()
            }
        }
    }

    // MARK: - File helpers

    private func deleteFiles(for id: String, ext: String = "png") {
        let fileURL = historyDir.appendingPathComponent("\(id).\(ext)")
        let thumbURL = historyDir.appendingPathComponent("\(id)_thumb.png")
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: thumbURL)
    }

    private func makeThumbnail(image: NSImage, maxWidth: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxWidth / size.width, maxWidth / size.height)
        let thumbSize = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: thumbSize, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: thumbSize), from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        return thumb
    }
}
