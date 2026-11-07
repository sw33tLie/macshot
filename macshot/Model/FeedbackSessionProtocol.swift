import Foundation
import Darwin

/// Wire messages are intentionally strict; unlike editable drafts, missing fields reject a request.
nonisolated struct FeedbackRequest: Codable, Sendable {
    enum Mode: String, Codable, Sendable { case annotate, capture }
    let version: Int
    let session: UUID
    let token: String
    let deadline: TimeInterval
    var mode: Mode? = nil
}

nonisolated struct FeedbackReceipt: Codable, Sendable {
    enum State: String, Codable, Sendable { case submitted, cancelled, timedOut, failed }
    let version: Int
    let session: UUID
    let token: String
    let state: State
    let message: String
}

nonisolated enum FeedbackSessionFiles {
    static func check(_ url: URL, directory: Bool, maximumBytes: Int = 512_000_000) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              directory || (info.st_nlink == 1 && info.st_size >= 0 && info.st_size <= maximumBytes) else {
            throw FeedbackError.invalidSession
        }
    }

    static func directory(root: URL, session: UUID) throws -> URL {
        try check(root, directory: true)
        let folder = root.appendingPathComponent(session.uuidString, isDirectory: true)
        try check(folder, directory: true)
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw FeedbackError.invalidSession
        }
        return folder
    }

    static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try check(url, directory: false, maximumBytes: 65_536)
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536 else { throw FeedbackError.invalidSession }
        return try JSONDecoder().decode(type, from: data)
    }

    static func request(root: URL, session: UUID) throws -> (URL, FeedbackRequest) {
        let folder = try directory(root: root, session: session)
        let request = try read(FeedbackRequest.self, at: folder.appendingPathComponent("request.json"))
        guard request.version == 1, request.session == session,
              request.token.count == 64, request.token.allSatisfy({ $0.isHexDigit }),
              request.deadline.isFinite else { throw FeedbackError.invalidSession }
        return (folder, request)
    }

    static func cancelled(_ folder: URL, request: FeedbackRequest) -> Bool {
        guard let cancel = try? read(FeedbackRequest.self, at: folder.appendingPathComponent("cancel.json")) else { return false }
        return cancel.version == 1 && cancel.session == request.session && cancel.token == request.token
    }
}
