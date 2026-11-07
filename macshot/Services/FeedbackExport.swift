import Cocoa
import ImageIO
import UniformTypeIdentifiers
import Darwin

nonisolated enum FeedbackExport {
    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int,
              let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 32_768, h <= 32_768, w * h <= 100_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FeedbackError.invalidImage }
        return image
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FeedbackError.invalidImage
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FeedbackError.invalidImage }
        return data as Data
    }

    /// Publish with an exclusive hard link: unlike replace/rename this cannot overwrite a racing writer.
    static func publish(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        guard link(tmp.path, url.path) == 0 else {
            if errno == EEXIST { throw FeedbackError.outputExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    @MainActor static func preview(_ source: CGImage, document: FeedbackDocument) throws -> CGImage {
        let size = NSSize(width: source.width, height: source.height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.width, pixelsHigh: source.height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { throw FeedbackError.invalidImage }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSImage(cgImage: source, size: size).draw(in: NSRect(origin: .zero, size: size))
        for (i, note) in document.submitted.notes.enumerated() where note.kind != .global {
            let r = CGRect(x: note.rect.minX, y: size.height - note.rect.maxY, width: note.rect.width, height: note.rect.height)
            NSColor.systemBlue.setStroke()
            if note.kind == .region { let path = NSBezierPath(rect: r); path.lineWidth = 2; path.stroke() }
            let radius: CGFloat = max(12, min(size.width, size.height) / 60)
            let x = min(max(radius, r.minX), size.width - radius)
            let y = min(max(radius, size.height - note.rect.minY), size.height - radius)
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: CGRect(x: x-radius, y: y-radius, width: radius*2, height: radius*2)).fill()
            let label = "\(i+1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: radius, weight: .semibold), .foregroundColor: NSColor.white]
            let s = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: x-s.width/2, y: y-s.height/2), withAttributes: attrs)
        }
        guard let cg = rep.cgImage else { throw FeedbackError.invalidImage }
        return cg
    }

    static func write(source: CGImage, preview: CGImage, document: FeedbackDocument, directory: URL, markdown: String? = nil) throws {
        let doc = try document.submitted.validated()
        guard source.width == doc.width, source.height == doc.height,
              preview.width == doc.width, preview.height == doc.height else { throw FeedbackError.invalidImage }
        let fm = FileManager.default
        let names = ["source.png", "preview.png", "feedback.md", "feedback.json"]
        guard names.allSatisfy({ !fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { throw FeedbackError.outputExists }
        var published: [URL] = []
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(doc)
            guard json.count <= 16_000_000 else { throw FeedbackError.invalidDocument }
            let contents = [try png(source), try png(preview), Data((markdown ?? doc.markdown).utf8), json]
            for (name, data) in zip(names, contents) {
                let url = directory.appendingPathComponent(name)
                try publish(data, to: url)
                published.append(url)
            }
        } catch {
            for url in published { try? fm.removeItem(at: url) }
            throw error
        }
    }

    static func writeManual(source: CGImage, preview: CGImage, document: FeedbackDocument,
                            root: URL, taskID: UUID, markdown: String) throws -> URL {
        try FeedbackSessionFiles.check(root, directory: true)
        let folder = root.appendingPathComponent(taskID.uuidString, isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else {
            if errno == EEXIST { throw FeedbackError.outputExists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        do {
            try write(source: source, preview: preview, document: document, directory: folder, markdown: markdown)
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func manualClipboardText(markdown: String, root: URL, taskID: UUID) -> String {
        let folder = root.appendingPathComponent(taskID.uuidString, isDirectory: true)
        return "Use the macshot-feedback Skill to read task ID \(taskID.uuidString) from the AI collaboration directory.\n" +
            "AI collaboration directory: \(root.path)\n" +
            "Feedback folder: \(folder.path)\n" +
            "Images: source.png, preview.png\n\n" + markdown
    }
}
