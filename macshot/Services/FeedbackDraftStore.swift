import Foundation
import CoreGraphics

nonisolated enum FeedbackDraftStore {
    static let queue = DispatchQueue(label: "com.macshot.feedback.drafts", qos: .utility)
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FeedbackDrafts", isDirectory: true)
    }

    static func save(_ document: FeedbackDocument, source: CGImage, directory: URL = root) throws {
        _ = try document.validated()
        let folder = directory.appendingPathComponent(document.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let imageURL = folder.appendingPathComponent("source.png")
        if !FileManager.default.fileExists(atPath: imageURL.path) {
            try FeedbackExport.publish(try FeedbackExport.png(source), to: imageURL)
        }
        let data = try JSONEncoder().encode(document)
        guard data.count <= 16_000_000 else { throw FeedbackError.invalidDocument }
        try data.write(to: folder.appendingPathComponent("draft.json"), options: .atomic)
    }

    static func list() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
    }

    static func load(_ folder: URL) throws -> (FeedbackDocument, CGImage) {
        let data = try Data(contentsOf: folder.appendingPathComponent("draft.json"))
        guard data.count <= 16_000_000 else { throw FeedbackError.invalidDocument }
        let doc = try JSONDecoder().decode(FeedbackDocument.self, from: data).validated()
        let image = try FeedbackExport.loadImage(folder.appendingPathComponent("source.png"))
        guard doc.id.uuidString == folder.lastPathComponent, image.width == doc.width, image.height == doc.height else {
            throw FeedbackError.invalidDocument
        }
        return (doc, image)
    }
}
