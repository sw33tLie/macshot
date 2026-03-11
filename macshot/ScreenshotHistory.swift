import Cocoa

struct HistoryEntry {
    let image: NSImage
    let thumbnail: NSImage
    let timestamp: Date
    let pixelWidth: Int
    let pixelHeight: Int

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

    var maxEntries: Int {
        if let stored = UserDefaults.standard.object(forKey: "historySize") as? Int {
            return stored
        }
        return 10  // default
    }

    func add(image: NSImage) {
        let max = maxEntries
        guard max > 0 else { return }  // history disabled

        let thumb = makeThumbnail(image: image, maxWidth: 36)
        let size = image.size
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let entry = HistoryEntry(
            image: image,
            thumbnail: thumb,
            timestamp: Date(),
            pixelWidth: Int(size.width * scale),
            pixelHeight: Int(size.height * scale)
        )
        entries.insert(entry, at: 0)

        // Prune oldest entries beyond max
        if entries.count > max {
            entries.removeLast(entries.count - max)
        }
    }

    /// Re-prune after user lowers the history size in preferences
    func pruneToMax() {
        let max = maxEntries
        if max <= 0 {
            entries.removeAll()
        } else if entries.count > max {
            entries.removeLast(entries.count - max)
        }
    }

    func clear() {
        entries.removeAll()
    }

    func copyEntry(at index: Int) {
        guard index >= 0, index < entries.count else { return }
        let image = entries[index].image
        guard let tiffData = image.tiffRepresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiffData, forType: .tiff)
        if let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            pasteboard.setData(pngData, forType: .png)
        }
    }

    private func makeThumbnail(image: NSImage, maxWidth: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxWidth / size.width, maxWidth / size.height)
        let thumbSize = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: thumbSize), from: .zero, operation: .copy, fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }
}
