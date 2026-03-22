import Cocoa
import Security
import CryptoKit

/// Google Drive uploader using OAuth2 with PKCE.
/// Files are uploaded to a "macshot" folder in the user's Drive, kept private (not shared).
final class GoogleDriveUploader: NSObject {

    static let shared = GoogleDriveUploader()

    // GCP OAuth Desktop client — secret is not confidential for installed apps per Google's docs
    private let clientID = "681324894254-c7jli6kv5gshg0bk4hoa6u04idiqoqcj.apps.googleusercontent.com"
    private let clientSecret = "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"
    private let redirectURI = "http://127.0.0.1"  // loopback — port appended at runtime
    private let scopes = "https://www.googleapis.com/auth/drive.file"

    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let uploadURL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"
    private let filesURL = "https://www.googleapis.com/drive/v3/files"

    private var macShotFolderID: String?
    private var loopbackServer: LoopbackAuthServer?

    // MARK: - Public API

    var isSignedIn: Bool {
        loadRefreshToken() != nil
    }

    var userEmail: String? {
        UserDefaults.standard.string(forKey: "gdriveUserEmail")
    }

    /// Start the OAuth2 sign-in flow using a loopback HTTP server.
    func signIn(from window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        // Start loopback server to receive the callback
        let server = LoopbackAuthServer()
        guard let port = server.start() else {
            completion(false)
            return
        }
        loopbackServer = server

        let actualRedirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: actualRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes + " email"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url else { completion(false); return }

        server.onCode = { [weak self] code in
            guard let self = self else { return }
            self.loopbackServer?.stop()
            self.loopbackServer = nil
            if let code = code {
                self.exchangeCodeWithRedirect(code, codeVerifier: codeVerifier, redirectURI: actualRedirectURI, completion: completion)
            } else {
                DispatchQueue.main.async { completion(false) }
            }
        }

        NSWorkspace.shared.open(authURL)
    }

    func signOut() {
        deleteTokens()
        UserDefaults.standard.removeObject(forKey: "gdriveUserEmail")
        macShotFolderID = nil
    }

    /// Progress callback: percentage 0.0–1.0
    var onProgress: ((Double) -> Void)?

    /// Upload a file (image or video) to the macshot folder.
    func upload(data: Data, filename: String, mimeType: String, completion: @escaping (Result<String, Error>) -> Void) {
        ensureValidToken { [weak self] success in
            guard let self = self, success else {
                completion(.failure(Self.error("Not signed in")))
                return
            }
            self.ensureMacShotFolder { folderID in
                guard let folderID = folderID else {
                    completion(.failure(Self.error("Failed to create macshot folder")))
                    return
                }
                self.uploadFile(data: data, filename: filename, mimeType: mimeType, folderID: folderID, completion: completion)
            }
        }
    }

    /// Upload an NSImage.
    func uploadImage(_ image: NSImage, completion: @escaping (Result<String, Error>) -> Void) {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            completion(.failure(Self.error("Failed to encode image")))
            return
        }
        let filename = "Screenshot \(Self.timestamp()).png"
        upload(data: pngData, filename: filename, mimeType: "image/png", completion: completion)
    }

    /// Upload a video file from URL.
    func uploadVideo(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let data = try? Data(contentsOf: url) else {
            completion(.failure(Self.error("Failed to read video file")))
            return
        }
        let ext = url.pathExtension.lowercased()
        let mime = ext == "gif" ? "image/gif" : "video/mp4"
        let filename = url.lastPathComponent
        upload(data: data, filename: filename, mimeType: mime, completion: completion)
    }

    // MARK: - OAuth Token Exchange

    private func exchangeCodeWithRedirect(_ code: String, codeVerifier: String, redirectURI: String, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier,
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
         .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let refreshToken = json["refresh_token"] as? String ?? self.loadRefreshToken()
            guard let finalRefreshToken = refreshToken else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let expiresIn = json["expires_in"] as? Int ?? 3600
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            self.saveToken(accessToken: accessToken, refreshToken: finalRefreshToken, expiry: expiry.timeIntervalSince1970)

            self.fetchUserEmail(accessToken: accessToken)

            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                completion(true)
            }
        }.resume()
    }

    private func refreshAccessToken(completion: @escaping (Bool) -> Void) {
        guard let refreshToken = loadRefreshToken() else {
            completion(false)
            return
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
         .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let expiresIn = json["expires_in"] as? Int ?? 3600
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))

            var tokens = self.loadTokens()
            tokens.accessToken = accessToken
            tokens.expiry = expiry.timeIntervalSince1970
            self.saveTokens(tokens)

            DispatchQueue.main.async { completion(true) }
        }.resume()
    }

    private func ensureValidToken(completion: @escaping (Bool) -> Void) {
        guard let expiry = loadExpiry() else {
            completion(false)
            return
        }

        if Date().timeIntervalSince1970 < expiry, loadAccessToken() != nil {
            completion(true)
        } else {
            refreshAccessToken(completion: completion)
        }
    }

    private func fetchUserEmail(accessToken: String) {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let email = json["email"] as? String else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(email, forKey: "gdriveUserEmail")
            }
        }.resume()
    }

    // MARK: - Drive Operations

    private func ensureMacShotFolder(completion: @escaping (String?) -> Void) {
        if let id = macShotFolderID { completion(id); return }

        guard let token = loadAccessToken() else { completion(nil); return }

        // Search for existing macshot folder
        let query = "name='macshot' and mimeType='application/vnd.google-apps.folder' and trashed=false"
        var searchURL = URLComponents(string: filesURL)!
        searchURL.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "fields", value: "files(id)")]

        var request = URLRequest(url: searchURL.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if let existing = files.first, let id = existing["id"] as? String {
                self.macShotFolderID = id
                DispatchQueue.main.async { completion(id) }
            } else {
                self.createMacShotFolder(token: token, completion: completion)
            }
        }.resume()
    }

    private func createMacShotFolder(token: String, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: filesURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": "macshot",
            "mimeType": "application/vnd.google-apps.folder",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: metadata)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self?.macShotFolderID = id
            DispatchQueue.main.async { completion(id) }
        }.resume()
    }

    private func uploadFile(data: Data, filename: String, mimeType: String, folderID: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let token = loadAccessToken() else {
            completion(.failure(Self.error("No access token")))
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: uploadURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": filename,
            "parents": [folderID],
        ]
        let metadataData = try! JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // Write body to temp file for uploadTask (enables progress tracking)
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("macshot_upload_\(UUID().uuidString).tmp")
        try? body.write(to: tmpFile)

        let task = URLSession.shared.uploadTask(with: request, fromFile: tmpFile) { [weak self] data, response, error in
            try? FileManager.default.removeItem(at: tmpFile)
            if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fileID = json["id"] as? String else {
                DispatchQueue.main.async { completion(.failure(Self.error("Upload failed"))) }
                return
            }
            let viewLink = "https://drive.google.com/file/d/\(fileID)/view"
            DispatchQueue.main.async {
                self?.onProgress = nil
                completion(.success(viewLink))
            }
        }

        // Observe upload progress
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.onProgress?(progress.fractionCompleted)
            }
        }
        // Store observation to keep it alive; released when task completes
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)

        task.resume()
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = verifier.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Token Storage (file-based, avoids Keychain ACL prompts)

    private struct TokenData: Codable {
        var accessToken: String?
        var refreshToken: String?
        var expiry: Double?
    }

    private var tokenFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.sw33tlie.macshot")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                      attributes: [.posixPermissions: 0o700])
        }
        return dir.appendingPathComponent("gdrive_tokens.json")
    }

    private func loadTokens() -> TokenData {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let tokens = try? JSONDecoder().decode(TokenData.self, from: data) else {
            return TokenData()
        }
        return tokens
    }

    private func saveTokens(_ tokens: TokenData) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        FileManager.default.createFile(atPath: tokenFileURL.path, contents: data,
                                        attributes: [.posixPermissions: 0o600])
    }

    private func deleteTokens() {
        try? FileManager.default.removeItem(at: tokenFileURL)
    }

    // Convenience accessors matching the old Keychain API
    private func saveToken(accessToken: String, refreshToken: String, expiry: Double) {
        var tokens = loadTokens()
        tokens.accessToken = accessToken
        tokens.refreshToken = refreshToken
        tokens.expiry = expiry
        saveTokens(tokens)
    }

    private func loadAccessToken() -> String? { loadTokens().accessToken }
    private func loadRefreshToken() -> String? { loadTokens().refreshToken }
    private func loadExpiry() -> Double? { loadTokens().expiry }

    // MARK: - Helpers

    private static func error(_ msg: String) -> NSError {
        NSError(domain: "GoogleDriveUploader", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}

// MARK: - Loopback HTTP Server for OAuth callback

/// Minimal HTTP server that listens on a random port, waits for Google's OAuth redirect,
/// extracts the authorization code, shows a success page, and shuts down.
private final class LoopbackAuthServer {
    var onCode: ((String?) -> Void)?
    private var serverSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private(set) var port: UInt16 = 0

    func start() -> UInt16? {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return nil }

        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // random port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { close(serverSocket); return nil }

        // Get assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverSocket, sockPtr, &addrLen)
            }
        }
        port = UInt16(bigEndian: boundAddr.sin_port)

        guard Darwin.listen(serverSocket, 1) == 0 else { close(serverSocket); return nil }

        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .global())
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 { close(fd) }
        }
        source.resume()
        listenSource = source

        return port
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        if serverSocket >= 0 { close(serverSocket); serverSocket = -1 }
    }

    private func acceptConnection() {
        let clientFD = accept(serverSocket, nil, nil)
        guard clientFD >= 0 else { return }

        // Read the HTTP request
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientFD, &buffer, buffer.count)
        guard bytesRead > 0 else { close(clientFD); return }

        let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

        // Extract the path from "GET /path?query HTTP/1.1"
        var code: String?
        if let firstLine = requestStr.components(separatedBy: "\r\n").first,
           let pathStart = firstLine.range(of: "GET ")?.upperBound,
           let pathEnd = firstLine.range(of: " HTTP")?.lowerBound {
            let path = String(firstLine[pathStart..<pathEnd])
            if let urlComponents = URLComponents(string: "http://127.0.0.1\(path)") {
                code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value
            }
        }

        // Send response
        let responseBody: String
        if code != nil {
            responseBody = """
            <html><body style="font-family:-apple-system,sans-serif;text-align:center;padding:60px;">
            <h2>&#10004; Signed in to macshot</h2>
            <p style="color:#666;">You can close this tab and return to macshot.</p>
            </body></html>
            """
        } else {
            responseBody = """
            <html><body style="font-family:-apple-system,sans-serif;text-align:center;padding:60px;">
            <h2>&#10008; Sign-in failed</h2>
            <p style="color:#666;">Please try again from macshot Preferences.</p>
            </body></html>
            """
        }

        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
        _ = response.withCString { ptr in
            write(clientFD, ptr, strlen(ptr))
        }
        close(clientFD)

        DispatchQueue.main.async { [weak self] in
            self?.onCode?(code)
        }
    }
}
