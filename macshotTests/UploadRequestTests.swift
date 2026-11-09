#if !OFFLINE
import Cocoa
import CryptoKit
import XCTest

private final class UploadFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let body: Data }
    nonisolated static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> Reply)?
    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    nonisolated override func stopLoading() {}
    nonisolated override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            guard let handler else { throw URLError(.unsupportedURL) }
            let result = try handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

final class UploadRequestTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var session: URLSession!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "macshot-upload-tests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadFixtureProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        UploadFixtureProtocol.lock.lock(); UploadFixtureProtocol.handler = nil; UploadFixtureProtocol.lock.unlock()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
    private func respond(_ handler: @escaping (URLRequest, Data) throws -> UploadFixtureProtocol.Reply) {
        UploadFixtureProtocol.lock.lock(); UploadFixtureProtocol.handler = handler; UploadFixtureProtocol.lock.unlock()
    }
    private func s3(pathPrefix: String = "folder+name") -> S3Uploader {
        S3Uploader(session: session, config: .init(endpoint: "https://upload.example:9443/proxy path", region: "us-east-1",
            bucket: "shots", accessKeyID: "fixture-key", secretAccessKey: "fixture-secret",
            publicURLBase: "https://cdn.example", pathPrefix: pathPrefix, publicRead: true))
    }
    private func drive(expired: Bool = false) throws -> GoogleDriveUploader {
        let tokens = directory.appendingPathComponent("tokens.json")
        try JSONSerialization.data(withJSONObject: ["accessToken": "fixture-access", "refreshToken": "refresh+a&b=c",
            "expiry": Date().timeIntervalSince1970 + (expired ? -60 : 3600)]).write(to: tokens)
        return GoogleDriveUploader(session: session, tokenFileURL: tokens, defaults: defaults, retryDelayNanoseconds: 0)
    }
    private func upload(_ uploader: S3Uploader, _ payload: UploadPayload, name: String) async throws -> String {
        defer { withExtendedLifetime(uploader) {} }
        return try await withCheckedThrowingContinuation { continuation in
            uploader.upload(payload: payload, filename: name, contentType: "video/mp4") { continuation.resume(with: $0) }
        }
    }
    private func upload(_ uploader: GoogleDriveUploader, _ payload: UploadPayload, name: String = "clip.mp4") async throws -> String {
        defer { withExtendedLifetime(uploader) {} }
        return try await withCheckedThrowingContinuation { continuation in
            uploader.upload(payload: payload, filename: name, mimeType: "video/mp4") { continuation.resume(with: $0) }
        }
    }

    func testS3SignsTheExactBodyAndEscapedProxyPath() async throws {
        let data = Data("owned bytes".utf8)
        let received = expectation(description: "S3 request")
        respond { request, body in
            XCTAssertEqual(body, data)
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.absoluteString, "https://upload.example:9443/proxy%20path/shots/folder%2Bname/a%2Bb%25%3F.mp4")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Content-Sha256"),
                           SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "upload.example:9443")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-acl"), "public-read")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-acl") == true)
            received.fulfill()
            return .init(status: 200, body: Data())
        }
        let link = try await upload(s3(), .data(data), name: "a+b%?.mp4")
        XCTAssertEqual(link, "https://cdn.example/folder%2Bname/a%2Bb%25%3F.mp4")
        await fulfillment(of: [received], timeout: 5)
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testS3ExpandsDatePrefixInRequestAndPublicLink() async throws {
        let received = expectation(description: "S3 dated paths")
        received.expectedFulfillmentCount = 2
        let lock = NSLock()
        var expectedLinks: [String] = []
        respond { request, _ in
            let path = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath)
            XCTAssertNotNil(path.range(of: #"^/proxy%20path/shots/folder%2Bname/[0-9]{4}/[0-9]{2}/[0-9]{2}/a%2Bb%25%3F.mp4$"#,
                                       options: .regularExpression))
            lock.lock()
            expectedLinks.append("https://cdn.example/" + path.dropFirst("/proxy%20path/shots/".count))
            lock.unlock()
            received.fulfill()
            return .init(status: 200, body: Data())
        }
        var links: [String] = []
        for suffix in ["", "/"] {
            let uploader = s3(pathPrefix: "folder+name/{year}/{month}/{day}" + suffix)
            let link = try await upload(uploader, .data(Data([1])), name: "a+b%?.mp4")
            links.append(link)
        }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(links, expectedLinks)
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testPreparedBodyOutlivesChangedOrDeletedSourceAndCleansUp() async throws {
        let source = directory.appendingPathComponent("source.mp4")
        let bytes = Data(repeating: 0xAB, count: 3 * UploadPayload.chunkSize + 19)
        try bytes.write(to: source)
        var prepared: PreparedUploadBody? = try await MediaExportIO.perform {
            XCTAssertFalse(Thread.isMainThread)
            return try PreparedUploadBody(payload: .file(source))
        }
        let bodyURL = try XCTUnwrap(prepared?.url)
        try Data("different".utf8).write(to: source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: bodyURL), bytes)
        XCTAssertEqual(prepared?.byteCount, bytes.count)
        XCTAssertEqual(prepared?.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyURL.path))
    }

    func testDriveRetryKeepsBodyAndGeneratedIDAfterSourceDeletion() async throws {
        let source = directory.appendingPathComponent("source.mp4")
        let bytes = Data("original video bytes".utf8)
        try bytes.write(to: source)
        let uploader = try drive()
        let requests = NSLock()
        var bodies: [Data] = []
        respond { request, body in
            let path = request.url!.path
            if path.hasSuffix("generateIds") { return .init(status: 200, body: Data(#"{"ids":["generated-id"]}"#.utf8)) }
            if path == "/drive/v3/files" { return .init(status: 200, body: Data(#"{"files":[{"id":"folder-id"}]}"#.utf8)) }
            XCTAssertEqual(path, "/upload/drive/v3/files")
            requests.lock(); bodies.append(body); let attempt = bodies.count; requests.unlock()
            XCTAssertTrue(body.range(of: bytes) != nil)
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("generated-id"))
            if attempt == 1 {
                try FileManager.default.removeItem(at: source)
                throw URLError(.networkConnectionLost)
            }
            return .init(status: 409, body: Data())
        }
        let link = try await upload(uploader, .file(source))
        XCTAssertEqual(link, "https://drive.google.com/file/d/generated-id/view")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testDriveRefreshUsesFormEncodingAndRespectsHTTPFailure() async throws {
        let uploader = try drive(expired: true)
        respond { request, body in
            XCTAssertEqual(request.url?.path, "/token")
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("refresh_token=refresh%2Ba%26b%3Dc"))
            return .init(status: 401, body: Data(#"{"access_token":"must-not-be-saved"}"#.utf8))
        }
        do { _ = try await upload(uploader, .data(Data([1]))); XCTFail("HTTP failure accepted") } catch {}
        let stored = try String(contentsOf: directory.appendingPathComponent("tokens.json"), encoding: .utf8)
        XCTAssertFalse(stored.contains("must-not-be-saved"))
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testDriveRefreshesAnExpiredUploadTokenWithoutChangingTheRequestBody() async throws {
        let uploader = try drive()
        let lock = NSLock()
        var bodies: [Data] = []
        var refreshes = 0
        respond { request, body in
            lock.lock(); defer { lock.unlock() }
            switch request.url!.path {
            case "/token":
                refreshes += 1
                return .init(status: 200, body: Data(#"{"access_token":"renewed-token","expires_in":3600}"#.utf8))
            case "/drive/v3/files/generateIds":
                return .init(status: 200, body: Data(#"{"ids":["generated-id"]}"#.utf8))
            case "/drive/v3/files":
                return .init(status: 200, body: Data(#"{"files":[{"id":"folder-id"}]}"#.utf8))
            default:
                bodies.append(body)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                               bodies.count == 1 ? "Bearer fixture-access" : "Bearer renewed-token")
                return bodies.count == 1
                    ? .init(status: 401, body: Data())
                    : .init(status: 200, body: Data(#"{"id":"generated-id"}"#.utf8))
            }
        }
        let link = try await upload(uploader, .data(Data("same bytes".utf8)))
        XCTAssertEqual(link, "https://drive.google.com/file/d/generated-id/view")
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.first, bodies.last)
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testEachProgressDelegateRetainsItsOwnCallback() async {
        let first = expectation(description: "first progress")
        let second = expectation(description: "second progress")
        let a = UploadTransport.ProgressDelegate { value in XCTAssertEqual(value, 0.25); first.fulfill() }
        let b = UploadTransport.ProgressDelegate { value in XCTAssertEqual(value, 0.75); second.fulfill() }
        let task = session.dataTask(with: URL(string: "https://fixture.invalid")!)
        a.urlSession(session, task: task, didSendBodyData: 25, totalBytesSent: 25, totalBytesExpectedToSend: 100)
        b.urlSession(session, task: task, didSendBodyData: 75, totalBytesSent: 75, totalBytesExpectedToSend: 100)
        await fulfillment(of: [first, second], timeout: 5)
    }

    func testSigningOutWhileFolderSearchRunsCannotContinueTheUpload() async throws {
        let uploader = try drive()
        let searching = expectation(description: "folder lookup started")
        let gate = DispatchSemaphore(value: 0)
        respond { request, _ in
            XCTAssertEqual(request.url?.path, "/drive/v3/files")
            searching.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return .init(status: 200, body: Data(#"{"files":[{"id":"old-account-folder"}]}"#.utf8))
        }
        let operation = Task { try await upload(uploader, .data(Data([1]))) }
        await fulfillment(of: [searching], timeout: 5)
        XCTAssertTrue(MediaExportCoordinator.shared.hasActiveJobs)
        uploader.signOut()
        gate.signal()
        do { _ = try await operation.value; XCTFail("Signed-out upload continued") } catch {}
        XCTAssertFalse(uploader.isSignedIn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokens.json").path))
        await MediaExportCoordinator.shared.waitUntilIdle()
        XCTAssertFalse(MediaExportCoordinator.shared.hasActiveJobs)
    }

    func testSigningOutDuringRefreshDoesNotRestoreTokens() async throws {
        let uploader = try drive(expired: true)
        let refreshing = expectation(description: "refresh started")
        let gate = DispatchSemaphore(value: 0)
        respond { request, _ in
            XCTAssertEqual(request.url?.path, "/token")
            refreshing.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success)
            return .init(status: 200, body: Data(#"{"access_token":"obsolete-access","expires_in":3600}"#.utf8))
        }
        let operation = Task { try await upload(uploader, .data(Data([1]))) }
        await fulfillment(of: [refreshing], timeout: 5)
        uploader.signOut()
        gate.signal()
        do { _ = try await operation.value; XCTFail("Signed-out refresh accepted") } catch {}
        XCTAssertFalse(uploader.isSignedIn)
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testConcurrentDriveUploadsShareFolderLookupButKeepTheirOwnBodies() async throws {
        let uploader = try drive()
        let lock = NSLock()
        var searches = 0, creates = 0, ids = 0
        var received: [String: String] = [:]
        respond { request, body in
            lock.lock(); defer { lock.unlock() }
            if request.url!.path.hasSuffix("generateIds") {
                ids += 1
                return .init(status: 200, body: Data("{\"ids\":[\"id-\(ids)\"]}".utf8))
            }
            if request.url!.path == "/drive/v3/files" {
                if request.httpMethod == "POST" {
                    creates += 1
                    return .init(status: 200, body: Data(#"{"id":"folder-id"}"#.utf8))
                }
                searches += 1
                return .init(status: 200, body: Data(#"{"files":[]}"#.utf8))
            }
            let text = String(decoding: body, as: UTF8.self)
            let start = try XCTUnwrap(text.range(of: "\r\n\r\n")).upperBound
            let end = try XCTUnwrap(text.range(of: "\r\n--", range: start..<text.endIndex)).lowerBound
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[start..<end].utf8)) as? [String: Any])
            let id = try XCTUnwrap(metadata["id"] as? String)
            let name = try XCTUnwrap(metadata["name"] as? String)
            XCTAssertEqual(metadata["parents"] as? [String], ["folder-id"])
            XCTAssertTrue(text.contains(name == "first.mp4" ? "first bytes" : "second bytes"))
            received[name] = id
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["id": id]))
        }
        let first = Task { try await upload(uploader, .data(Data("first bytes".utf8)), name: "first.mp4") }
        let second = Task { try await upload(uploader, .data(Data("second bytes".utf8)), name: "second.mp4") }
        let links = try await [first.value, second.value]
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(Set(links).count, 2)
        XCTAssertEqual(received.count, 2)
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testImgbbSendsTheOwnedPNGAsBinaryMultipart() async throws {
        let image = ImageProbe.solidImage(width: 31, height: 19, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        respond { request, body in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "fixture-key")
            let headerEnd = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8))).upperBound
            let boundary = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last)
            let imageEnd = try XCTUnwrap(body.range(of: Data("\r\n--\(boundary)--".utf8))).lowerBound
            let png = Data(body[headerEnd..<imageEnd])
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.width, 31)
            XCTAssertEqual(decoded.height, 19)
            return .init(status: 200, body: Data(#"{"success":true,"data":{"url":"https://image.example/a.png","delete_url":"https://image.example/delete"}}"#.utf8))
        }
        let result: ImageUploadResult = try await withCheckedThrowingContinuation { continuation in
            ImageUploader.upload(image: image, session: session, key: "fixture-key") { continuation.resume(with: $0) }
            image.size = NSSize(width: 1, height: 1)
        }
        XCTAssertEqual(result.link, "https://image.example/a.png")
        await MediaExportCoordinator.shared.waitUntilIdle()
    }

    func testFinishedProgressCannotOverwriteACompletedStatus() async {
        var delivered = false
        let delegate = UploadTransport.ProgressDelegate { _ in delivered = true }
        let task = session.dataTask(with: URL(string: "https://fixture.invalid")!)
        delegate.urlSession(session, task: task, didSendBodyData: 10, totalBytesSent: 10, totalBytesExpectedToSend: 10)
        delegate.finish()
        // A FIFO main-queue barrier proves the queued callback was considered;
        // yielding alone could assert before the callback had a chance to run.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertFalse(delivered)
    }
}
#endif
