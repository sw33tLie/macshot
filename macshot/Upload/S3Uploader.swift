#if !OFFLINE
import Cocoa
import CryptoKit
import UniformTypeIdentifiers

/// S3-compatible uploader that works with AWS S3, Cloudflare R2, MinIO, etc.
/// Uses AWS Signature V4 for authentication — no AWS SDK dependency.
final class S3Uploader {

    static let shared = S3Uploader()
    private let session: URLSession
    private let configurationOverride: Config?

    init(session: URLSession = .shared, config: Config? = nil) {
        self.session = session
        self.configurationOverride = config
    }

    // MARK: - Configuration

    struct Config {
        let endpoint: String      // e.g. "https://abc123.r2.cloudflarestorage.com"
        let region: String        // e.g. "auto" for R2, "us-east-1" for AWS
        let bucket: String
        let accessKeyID: String
        let secretAccessKey: String
        let publicURLBase: String // e.g. "https://cdn.example.com" — used for the final link
        let pathPrefix: String    // e.g. "screenshots/{year}/{month}/{day}/" — optional prefix within bucket
        let publicRead: Bool      // send `x-amz-acl: public-read` so the object is world-readable

        var isValid: Bool {
            !endpoint.isEmpty && !bucket.isEmpty && !accessKeyID.isEmpty
                && !secretAccessKey.isEmpty && !effectiveRegion.isEmpty
        }

        /// The region to sign with. Clearing the settings field stores "", not
        /// nil, which defeated the `?? "auto"` default and produced a credential
        /// scope with an empty region — surfacing as SignatureDoesNotMatch,
        /// which points nowhere near the empty field.
        var effectiveRegion: String {
            let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "auto" : trimmed
        }

        /// Expand only {year}, {month} and {day} using the local upload date.
        /// Keep literal paths, slashes and unsupported placeholders unchanged.
        func resolvedPathPrefix(date: Date = Date(), timeZone: TimeZone = .current) -> String {
            Self.expandDatePlaceholders(in: pathPrefix, date: date, timeZone: timeZone)
        }

        static func expandDatePlaceholders(in template: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return template
                .replacingOccurrences(of: "{year}", with: String(format: "%04d", calendar.component(.year, from: date)))
                .replacingOccurrences(of: "{month}", with: String(format: "%02d", calendar.component(.month, from: date)))
                .replacingOccurrences(of: "{day}", with: String(format: "%02d", calendar.component(.day, from: date)))
        }
    }

    var config: Config {
        if let configurationOverride { return configurationOverride }
        let ud = UserDefaults.standard
        return Config(
            endpoint: ud.string(forKey: "s3Endpoint") ?? "",
            region: ud.string(forKey: "s3Region") ?? "auto",
            bucket: ud.string(forKey: "s3Bucket") ?? "",
            accessKeyID: ud.string(forKey: "s3AccessKeyID") ?? "",
            secretAccessKey: ud.string(forKey: "s3SecretAccessKey") ?? "",
            publicURLBase: ud.string(forKey: "s3PublicURLBase") ?? "",
            pathPrefix: ud.string(forKey: "s3PathPrefix") ?? "",
            publicRead: ud.bool(forKey: "s3PublicRead")
        )
    }

    var isConfigured: Bool { config.isValid }

    func uploadImage(_ image: NSImage, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        do {
            let pixels = try HistoryImageSnapshot.Image(image)
            let template = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
            upload(payload: .image(pixels), filename: FilenameFormatter.format(template: template) + ".png",
                   contentType: "image/png", progress: progress, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func uploadVideo(url: URL, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let types = ["gif": "image/gif", "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"]
        upload(payload: .file(url), filename: url.lastPathComponent,
               contentType: types[url.pathExtension.lowercased()] ?? "application/octet-stream",
               progress: progress, completion: completion)
    }

    func upload(data: Data, filename: String, contentType: String,
                progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                completion: @escaping (Result<String, Error>) -> Void) {
        upload(payload: .data(data), filename: filename, contentType: contentType, progress: progress, completion: completion)
    }

    func upload(payload: UploadPayload, filename: String, contentType: String,
                progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                completion: @escaping (Result<String, Error>) -> Void) {
        let cfg = config
        guard cfg.isValid else { completion(.failure(S3Error.notConfigured)); return }
        let session = self.session
        UploadJob.start(filename: filename, operation: {
            var prefix = cfg.resolvedPathPrefix()
            if !prefix.isEmpty && !prefix.hasSuffix("/") { prefix += "/" }
            let key = prefix + filename.replacingOccurrences(of: " ", with: "_")
            guard var endpoint = URLComponents(string: cfg.endpoint),
                  ["https", "http"].contains(endpoint.scheme?.lowercased() ?? ""),
                  let host = endpoint.host, !host.isEmpty,
                  endpoint.user == nil, endpoint.password == nil,
                  endpoint.query == nil, endpoint.fragment == nil else { throw S3Error.invalidEndpoint }
            let basePath = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            endpoint.percentEncodedPath = Self.uriEncode((basePath.isEmpty ? "" : "/" + basePath) + "/" + cfg.bucket + "/" + key)
            guard let url = endpoint.url else { throw S3Error.invalidEndpoint }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(host + (endpoint.port.map { ":\($0)" } ?? ""), forHTTPHeaderField: "Host")
            let body = try await MediaExportIO.perform { try PreparedUploadBody(payload: payload) }
            request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
            if cfg.publicRead { request.setValue("public-read", forHTTPHeaderField: "x-amz-acl") }
            Self.signRequest(&request, payloadHash: body.sha256, date: Date(), region: cfg.effectiveRegion,
                        accessKeyID: cfg.accessKeyID, secretAccessKey: cfg.secretAccessKey)
            let (data, response) = try await UploadTransport.upload(session: session, request: request, body: body, progress: progress)
            guard (200...299).contains(response.statusCode) else {
                let message = Self.extractXMLError(String(decoding: data, as: UTF8.self)) ?? "HTTP \(response.statusCode)"
                throw S3Error.httpError(response.statusCode, message)
            }
            if cfg.publicURLBase.isEmpty { return url.absoluteString }
            let separator = cfg.publicURLBase.hasSuffix("/") ? "" : "/"
            return cfg.publicURLBase + separator + Self.uriEncode(key)
        }, completion: completion)
    }

    private static func uriEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"))!
    }

    // MARK: - AWS Signature V4

    private static func signRequest(_ request: inout URLRequest, payloadHash: String, date: Date,
                              region: String, accessKeyID: String, secretAccessKey: String) {
        let service = "s3"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: date)

        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStamp = dateFormatter.string(from: date)

        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")

        // Content hash (streamed by the caller)
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        // Canonical request
        let method = request.httpMethod ?? "PUT"
        let url = request.url!
        // Sign precisely the escaped path sent on the wire. S3 does not
        // normalize repeated slashes and encodes reserved path characters.
        let canonicalURI = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let canonicalQueryString = url.query ?? ""

        // Signed headers (sorted). x-amz-acl is only present when the user opted into
        // public-read; sending it unsigned would fail the signature check.
        var signedHeaderNames = ["content-type", "host", "x-amz-content-sha256", "x-amz-date"]
        if request.value(forHTTPHeaderField: "x-amz-acl") != nil {
            signedHeaderNames.append("x-amz-acl")
            signedHeaderNames.sort()
        }
        let signedHeadersString = signedHeaderNames.joined(separator: ";")

        var canonicalHeaders = ""
        for name in signedHeaderNames {
            let value = request.value(forHTTPHeaderField: name) ?? ""
            canonicalHeaders += "\(name):\(value.trimmingCharacters(in: .whitespaces))\n"
        }

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQueryString,
            canonicalHeaders,
            signedHeadersString,
            payloadHash
        ].joined(separator: "\n")

        // String to sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(canonicalRequestHash)"

        // Signing key
        let kDate = Self.hmacSHA256(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = Self.hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = Self.hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmacSHA256(key: kService, data: Data("aws4_request".utf8))

        // Signature
        let signature = Self.hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).hexString

        // Authorization header
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeadersString), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac)
    }

    // MARK: - Helpers


    private static func extractXMLError(_ body: String) -> String? {
        // Simple extraction of <Message>...</Message> from S3 XML error responses
        guard let start = body.range(of: "<Message>"),
              let end = body.range(of: "</Message>", range: start.upperBound..<body.endIndex) else { return nil }
        return String(body[start.upperBound..<end.lowerBound])
    }

    // MARK: - Errors

    enum S3Error: LocalizedError {
        case notConfigured
        case invalidEndpoint
        case encodingFailed
        case fileReadFailed
        case noResponse
        case httpError(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "S3 not configured. Check Settings."
            case .invalidEndpoint: return "Invalid S3 endpoint URL"
            case .encodingFailed: return "Failed to encode image"
            case .fileReadFailed: return "Failed to read file"
            case .noResponse: return "No response from server"
            case .httpError(let code, let msg): return "S3 error (\(code)): \(msg)"
            }
        }
    }
}

// MARK: - SHA256 hex helper

private extension SHA256Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
#endif
