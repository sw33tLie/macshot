#if !OFFLINE
import Cocoa
import Security
import CryptoKit
import AuthenticationServices

/// Google Drive uploads remain private in the configured destination folder.
final class GoogleDriveUploader: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleDriveUploader()
    private let clientID = "92758256085-8gkpg2b9to7bu7to0vgh9c7af755hp5d.apps.googleusercontent.com"
    private var callbackScheme: String { clientID.components(separatedBy: ".").reversed().joined(separator: ".") }
    private let scopes = "https://www.googleapis.com/auth/drive.file"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let uploadURL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"
    private let filesURL = "https://www.googleapis.com/drive/v3/files"
    private let session: URLSession
    private let tokenFileOverride: URL?
    private let defaults: UserDefaults
    private let retryDelay: UInt64
    private var authGeneration = UUID()
    private var folderGeneration = UUID()
    private var tokenRefresh: (id: UUID, task: Task<String, Error>)?
    private var folderRequests: [String: (id: UUID, task: Task<String, Error>)] = [:]
    private var cachedFolderID: String?
    private var cachedFolderName: String?
    private var authSession: ASWebAuthenticationSession?
    private weak var presentationWindow: NSWindow?

    init(session: URLSession? = nil, tokenFileURL: URL? = nil,
         defaults: UserDefaults = .standard, retryDelayNanoseconds: UInt64 = 2_000_000_000) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        self.session = session ?? URLSession(configuration: config)
        self.tokenFileOverride = tokenFileURL
        self.defaults = defaults
        self.retryDelay = retryDelayNanoseconds
        super.init()
    }

    var isSignedIn: Bool { loadRefreshToken() != nil }
    var userEmail: String? { defaults.string(forKey: "gdriveUserEmail") }
    private var folderName: String {
        let name = defaults.string(forKey: "gdriveFolderName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "macshot" : name
    }

    /// Start the OAuth2 sign-in flow using ASWebAuthenticationSession.
    func signIn(from window: NSWindow?, completion: @escaping (Bool) -> Void) {
        authGeneration = UUID()
        let generation = authGeneration
        authSession?.cancel()
        tokenRefresh?.task.cancel()
        tokenRefresh = nil
        invalidateFolderCache()
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let redirectURI = "\(callbackScheme):/oauthredirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes + " email"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url else { completion(false); return }

        presentationWindow = window
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
            Task { @MainActor [weak self] in
                guard let self, self.authGeneration == generation else { completion(false); return }
                self.authSession = nil

                guard let callbackURL = callbackURL, error == nil,
                      let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                self.exchangeCodeWithRedirect(code, codeVerifier: codeVerifier, redirectURI: redirectURI, completion: completion)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        if !session.start() { authSession = nil; completion(false) }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow ?? NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    func signOut() {
        authGeneration = UUID()
        authSession?.cancel()
        authSession = nil
        tokenRefresh?.task.cancel()
        tokenRefresh = nil
        invalidateFolderCache()
        deleteTokens()
        defaults.removeObject(forKey: "gdriveUserEmail")
    }

    func upload(data: Data, filename: String, mimeType: String,
                progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                completion: @escaping (Result<String, Error>) -> Void) {
        upload(payload: .data(data), filename: filename, mimeType: mimeType, progress: progress, completion: completion)
    }

    func upload(payload: UploadPayload, filename: String, mimeType: String,
                progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                completion: @escaping (Result<String, Error>) -> Void) {
        let generation = authGeneration
        let name = folderName
        UploadJob.start(filename: filename, operation: { [weak self] in
            guard let self else { throw CancellationError() }
            let source = try await MediaExportIO.perform { try PreparedUploadBody(payload: payload) }
            try checkAccount(generation)
            _ = try await validToken()
            let folder = try await destinationFolder(name: name, generation: generation)
            return try await uploadFile(source: source, filename: filename, mimeType: mimeType,
                                        folderID: folder, generation: generation, progress: progress)
        }, completion: completion)
    }

    func uploadImage(_ image: NSImage, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let pixels = try HistoryImageSnapshot.Image(image)
            let template = defaults.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
            upload(payload: .image(pixels), filename: FilenameFormatter.format(template: template) + ".png",
                   mimeType: "image/png", progress: progress, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func uploadVideo(url: URL, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        upload(payload: .file(url), filename: url.lastPathComponent,
               mimeType: url.pathExtension.lowercased() == "gif" ? "image/gif" : "video/mp4",
               progress: progress, completion: completion)
    }

    // All account/cache mutation resumes on the main actor. A response from
    // before sign-out can neither restore credentials nor start another upload.
    private func checkAccount(_ generation: UUID) throws {
        guard generation == authGeneration else { throw Self.error("Account changed during upload") }
    }

    private func tokenRequest(_ values: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = UploadTransport.formBody(values)
        return request
    }

    private func exchangeCodeWithRedirect(_ code: String, codeVerifier: String, redirectURI: String,
                                          completion: @escaping (Bool) -> Void) {
        let generation = authGeneration
        let request = tokenRequest(["code": code, "client_id": clientID, "redirect_uri": redirectURI,
                                    "grant_type": "authorization_code", "code_verifier": codeVerifier])
        Task { [weak self] in
            guard let self else { completion(false); return }
            do {
                let json = try await jsonResponse(request)
                try checkAccount(generation)
                guard let access = json["access_token"] as? String,
                      let refresh = json["refresh_token"] as? String ?? loadRefreshToken() else {
                    throw Self.error("Invalid authentication response")
                }
                let expiry = Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int ?? 3600) - 60))
                saveToken(accessToken: access, refreshToken: refresh, expiry: expiry.timeIntervalSince1970)
                guard loadAccessToken() == access else { throw Self.error("Could not save authentication") }
                fetchUserEmail(accessToken: access)
                NSApp.activate(ignoringOtherApps: true)
                completion(true)
            } catch { completion(false) }
        }
    }

    private func validToken(forceRefresh: Bool = false) async throws -> String {
        let generation = authGeneration
        if !forceRefresh, let expiry = loadExpiry(), Date().timeIntervalSince1970 < expiry,
           let token = loadAccessToken() { return token }
        if let pending = tokenRefresh { return try await pending.task.value }
        guard let refresh = loadRefreshToken() else { throw Self.error("Not signed in") }
        let id = UUID()
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let json = try await jsonResponse(tokenRequest(["refresh_token": refresh, "client_id": clientID,
                                                           "grant_type": "refresh_token"]))
            try checkAccount(generation)
            guard let access = json["access_token"] as? String else { throw Self.error("Authentication expired") }
            let expiry = Date().addingTimeInterval(TimeInterval((json["expires_in"] as? Int ?? 3600) - 60))
            saveToken(accessToken: access, refreshToken: json["refresh_token"] as? String ?? refresh,
                      expiry: expiry.timeIntervalSince1970)
            guard loadAccessToken() == access else { throw Self.error("Could not save authentication") }
            return access
        }
        tokenRefresh = (id, task)
        defer { if tokenRefresh?.id == id { tokenRefresh = nil } }
        return try await task.value
    }

    func fetchUserEmail(accessToken: String? = nil, completion: (() -> Void)? = nil) {
        guard let token = accessToken ?? loadAccessToken() else { completion?(); return }
        let generation = authGeneration
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        Task { [weak self] in
            guard let self else { completion?(); return }
            if let json = try? await jsonResponse(request), generation == authGeneration,
               let email = json["email"] as? String { defaults.set(email, forKey: "gdriveUserEmail") }
            completion?()
        }
    }

    func invalidateFolderCache() {
        folderGeneration = UUID()
        cachedFolderID = nil
        cachedFolderName = nil
        folderRequests.removeAll()
    }

    private func destinationFolder(name: String, generation: UUID) async throws -> String {
        try checkAccount(generation)
        if let id = cachedFolderID, cachedFolderName == name { return id }
        if let pending = folderRequests[name] { return try await pending.task.value }
        let id = UUID()
        let cacheGeneration = folderGeneration
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw CancellationError() }
            let token = try await validToken()
            try checkAccount(generation)
            var url = URLComponents(string: filesURL)!
            url.queryItems = [URLQueryItem(name: "q", value: "name='\(escapeForDriveQuery(name))' and mimeType='application/vnd.google-apps.folder' and trashed=false"),
                              URLQueryItem(name: "fields", value: "files(id)")]
            var request = URLRequest(url: url.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let json = try await jsonResponse(request)
            try checkAccount(generation)
            guard let files = json["files"] as? [[String: Any]] else { throw Self.error("Folder search returned an invalid response") }
            let folderID: String
            if let existing = files.first?["id"] as? String, !existing.isEmpty { folderID = existing }
            else {
                var create = URLRequest(url: URL(string: filesURL)!)
                create.httpMethod = "POST"
                create.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                create.setValue("application/json", forHTTPHeaderField: "Content-Type")
                create.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": "application/vnd.google-apps.folder"])
                let response = try await jsonResponse(create)
                try checkAccount(generation)
                guard let created = response["id"] as? String, !created.isEmpty else { throw Self.error("Create folder returned no ID") }
                folderID = created
            }
            if folderGeneration == cacheGeneration {
                cachedFolderID = folderID
                cachedFolderName = name
            }
            return folderID
        }
        folderRequests[name] = (id, task)
        defer { if folderRequests[name]?.id == id { folderRequests.removeValue(forKey: name) } }
        return try await task.value
    }

    private func uploadFile(source: PreparedUploadBody, filename: String, mimeType: String,
                            folderID: String, generation: UUID,
                            progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> String {
        // A fixed Drive-generated ID makes a lost-response retry idempotent.
        // https://developers.google.com/workspace/drive/api/guides/manage-uploads#use_a_pre-generated_id_to_upload_files
        try checkAccount(generation)
        var idsRequest = URLRequest(url: URL(string: filesURL + "/generateIds?count=1&space=drive")!)
        idsRequest.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        try checkAccount(generation)
        let ids = try await jsonResponse(idsRequest)
        try checkAccount(generation)
        guard let fileID = (ids["ids"] as? [String])?.first, !fileID.isEmpty else { throw Self.error("Drive returned no upload ID") }
        let metadata = try JSONSerialization.data(withJSONObject: ["id": fileID, "name": filename, "parents": [folderID]])
        let boundary = UUID().uuidString
        let body = try await MediaExportIO.perform {
            try PreparedUploadBody(relatedTo: source, metadata: metadata, mimeType: mimeType, boundary: boundary)
        }
        for attempt in 1...3 {
            try checkAccount(generation)
            var request = URLRequest(url: URL(string: uploadURL)!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
            try checkAccount(generation)
            do {
                let (data, response) = try await UploadTransport.upload(session: session, request: request, body: body, progress: progress)
                try checkAccount(generation)
                if response.statusCode == 401, attempt < 3 { _ = try await validToken(forceRefresh: true); continue }
                // Drive documents 409 after a successful attempt with this ID.
                if response.statusCode == 409, attempt > 1 { return "https://drive.google.com/file/d/\(fileID)/view" }
                if (500...599).contains(response.statusCode), attempt < 3 {
                    try await Task.sleep(nanoseconds: retryDelay * UInt64(attempt)); continue
                }
                if response.statusCode == 404, cachedFolderID == folderID { invalidateFolderCache() }
                let json = try Self.parseResponse(data, response: response)
                guard json["id"] as? String == fileID else { throw Self.error("Upload returned an unexpected file ID") }
                return "https://drive.google.com/file/d/\(fileID)/view"
            } catch let error as URLError where attempt < 3 && [.networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code) {
                try await Task.sleep(nanoseconds: retryDelay * UInt64(attempt))
            }
        }
        throw Self.error("Upload could not be completed")
    }

    private func jsonResponse(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Self.error("No response from server") }
        return try Self.parseResponse(data, response: response)
    }

    private static func parseResponse(_ data: Data, response: HTTPURLResponse) throws -> [String: Any] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200...299).contains(response.statusCode), let json, json["error"] == nil else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String ?? "Invalid server response"
            throw error("\(message) (HTTP \(response.statusCode))")
        }
        return json
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
        if let tokenFileOverride { return tokenFileOverride }
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
        do {
            try data.write(to: tokenFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
        } catch { /* A failed token write is handled by the next token lookup. */ }
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

    /// Escapes a value for safe interpolation into a Drive API `q` query string.
    private func escapeForDriveQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'")
    }

    private static func error(_ msg: String) -> NSError {
        NSError(domain: "GoogleDriveUploader", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

}
#endif
