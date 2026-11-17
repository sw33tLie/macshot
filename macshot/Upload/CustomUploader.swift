#if !OFFLINE
import Cocoa

enum CustomUploaderError: LocalizedError, Equatable {
    case notConfigured
    case unreadableFile
    case notFileUploader
    case invalidRequestURL
    case unsupportedMethod(String)
    case unsupportedBody(String)
    case server(Int, String)
    case noLinkInResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Custom uploader not configured. Check Settings."
        case .unreadableFile: return "This file is not a ShareX custom uploader (.sxcu)."
        case .notFileUploader: return "This uploader does not accept images or files."
        case .invalidRequestURL: return "The uploader's request URL must be an http or https address."
        case .unsupportedMethod(let method): return "Request method \(method) is not supported. Use POST, PUT or PATCH."
        case .unsupportedBody(let body): return "Body type \(body) is not supported. Use MultipartFormData or Binary."
        case .server(let code, let message): return "Upload failed (\(code)): \(message)"
        case .noLinkInResponse: return "The server response did not contain a link."
        }
    }
}

struct CustomUploaderConfig: Equatable {
    enum BodyKind: Equatable {
        case multipart
        case binary
    }

    static let maxFileBytes = 1 << 20

    let name: String
    let method: String
    let requestURL: String
    let parameters: [String: String]
    let headers: [String: String]
    let body: BodyKind
    let arguments: [String: String]
    let fileFormName: String
    let urlTemplate: String
    let deletionURLTemplate: String
    let errorMessageTemplate: String
    let regexList: [String]

    init(sxcu data: Data) throws {
        guard data.count <= Self.maxFileBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CustomUploaderError.unreadableFile
        }
        var fields: [String: Any] = [:]
        for (key, value) in object { fields[key.lowercased()] = value }

        func string(_ key: String) -> String {
            Self.string(fields[key]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func dictionary(_ key: String) -> [String: String] {
            (fields[key] as? [String: Any] ?? [:]).mapValues { Self.string($0) }
        }

        requestURL = string("requesturl")
        guard !requestURL.isEmpty else { throw CustomUploaderError.unreadableFile }

        let destination = string("destinationtype").lowercased()
        if !destination.isEmpty, destination != "none",
           !destination.contains("imageuploader"), !destination.contains("fileuploader") {
            throw CustomUploaderError.notFileUploader
        }

        let requestedMethod = string("requestmethod").isEmpty ? string("requesttype") : string("requestmethod")
        method = requestedMethod.isEmpty ? "POST" : requestedMethod.uppercased()
        guard ["POST", "PUT", "PATCH"].contains(method) else {
            throw CustomUploaderError.unsupportedMethod(method)
        }

        fileFormName = string("fileformname")
        let bodyName = string("body")
        switch bodyName.lowercased() {
        case "multipartformdata": body = .multipart
        case "binary": body = .binary
        case "", "none":
            guard !fileFormName.isEmpty else { throw CustomUploaderError.unsupportedBody("None") }
            body = .multipart
        default: throw CustomUploaderError.unsupportedBody(bodyName)
        }
        if body == .multipart && fileFormName.isEmpty { throw CustomUploaderError.unreadableFile }

        parameters = dictionary("parameters")
        headers = dictionary("headers")
        arguments = dictionary("arguments")
        urlTemplate = string("url")
        deletionURLTemplate = string("deletionurl")
        errorMessageTemplate = string("errormessage")
        regexList = (fields["regexlist"] as? [Any] ?? []).map { Self.string($0) }

        guard let host = Self.endpoint(requestURL, filename: "file.png")?.host else {
            throw CustomUploaderError.invalidRequestURL
        }
        let givenName = string("name")
        name = givenName.isEmpty ? host : givenName
    }

    var host: String {
        Self.endpoint(requestURL, filename: "file.png")?.host ?? ""
    }

    func request(filename: String) throws -> URLRequest {
        guard var components = Self.endpoint(requestURL, filename: filename) else {
            throw CustomUploaderError.invalidRequestURL
        }
        if !parameters.isEmpty {
            components.queryItems = (components.queryItems ?? []) + parameters.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: Self.expand($0.value, filename: filename))
            }
        }
        guard let url = components.url else { throw CustomUploaderError.invalidRequestURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers where !["content-length", "content-type", "host"].contains(name.lowercased()) {
            request.setValue(Self.expand(value, filename: filename), forHTTPHeaderField: name)
        }
        return request
    }

    func formFields(filename: String) -> [(name: String, value: String)] {
        arguments.sorted { $0.key < $1.key }.map { (name: $0.key, value: Self.expand($0.value, filename: filename)) }
    }

    func result(from response: CustomUploaderResponse) throws -> ImageUploadResult {
        guard (200...299).contains(response.statusCode) else {
            var message = response.resolve(errorMessageTemplate, regexList: regexList)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty { message = String(response.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
            if message.isEmpty { message = "HTTP \(response.statusCode)" }
            throw CustomUploaderError.server(response.statusCode, message)
        }
        let link = urlTemplate.isEmpty ? response.text : response.resolve(urlTemplate, regexList: regexList)
        guard let validLink = Self.webLink(link) else { throw CustomUploaderError.noLinkInResponse }
        let deleteURL = Self.webLink(response.resolve(deletionURLTemplate, regexList: regexList)) ?? ""
        return ImageUploadResult(link: validLink, deleteURL: deleteURL)
    }

    static func expand(_ value: String, filename: String) -> String {
        value.replacingOccurrences(of: "{filename}", with: filename)
            .replacingOccurrences(of: "$filename$", with: filename)
    }

    private static func endpoint(_ template: String, filename: String) -> URLComponents? {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        guard let components = URLComponents(string: expand(template, filename: encoded)),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false else { return nil }
        return components
    }

    private static func webLink(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false else { return nil }
        return trimmed
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }
}

struct CustomUploaderResponse {
    static let maxTextBytes = 1 << 20

    let statusCode: Int
    let body: Data
    let headers: [String: String]
    let responseURL: String
    let filename: String

    init(statusCode: Int, body: Data, headers: [String: String] = [:], responseURL: String = "", filename: String = "") {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
        self.responseURL = responseURL
        self.filename = filename
    }

    init(body: Data, http: HTTPURLResponse, filename: String) {
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        self.init(statusCode: http.statusCode, body: body, headers: headers,
                  responseURL: http.url?.absoluteString ?? "", filename: filename)
    }

    var text: String {
        String(decoding: body.prefix(Self.maxTextBytes), as: UTF8.self)
    }

    private static let placeholder = try! NSRegularExpression(pattern:
        #"\{(json|regex|header|responseurl|response|filename)(?::((?:[^{}\\]|\\.)*))?\}"#
        + #"|\$(json|regex|header|responseurl|response|filename)(?::([^$]*))?\$"#)

    func resolve(_ template: String, regexList: [String] = []) -> String {
        guard !template.isEmpty else { return "" }
        let source = template as NSString
        var output = ""
        var cursor = 0
        for match in Self.placeholder.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let braces = match.range(at: 1).location != NSNotFound
            let nameRange = match.range(at: braces ? 1 : 3)
            let argumentRange = match.range(at: braces ? 2 : 4)
            let argument = argumentRange.location == NSNotFound ? "" : source.substring(with: argumentRange)
            output += value(of: source.substring(with: nameRange), argument: argument,
                            braces: braces, regexList: regexList)
        }
        output += source.substring(from: cursor)
        return output
    }

    private func value(of name: String, argument: String, braces: Bool, regexList: [String]) -> String {
        let parts = braces ? Self.splitEscaped(argument) : argument.components(separatedBy: ",")
        switch name {
        case "json":
            guard let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return "" }
            return Self.jsonValue(in: root, path: parts.last ?? "") ?? ""
        case "regex":
            let group = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if braces { return regexValue(pattern: parts.first ?? "", group: group) }
            guard let index = Int(parts.first?.trimmingCharacters(in: .whitespaces) ?? ""),
                  regexList.indices.contains(index - 1) else { return "" }
            return regexValue(pattern: regexList[index - 1], group: group)
        case "header":
            let wanted = (parts.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return headers.first { $0.key.lowercased() == wanted }?.value ?? ""
        case "responseurl": return responseURL
        case "response": return text
        case "filename": return filename
        default: return ""
        }
    }

    private func regexValue(pattern: String, group: String) -> String {
        guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let haystack = text as NSString
        guard let match = regex.firstMatch(in: haystack as String, range: NSRange(location: 0, length: haystack.length)) else {
            return ""
        }
        let range: NSRange
        if group.isEmpty {
            range = match.range
        } else if let index = Int(group) {
            guard index >= 0, index < match.numberOfRanges else { return "" }
            range = match.range(at: index)
        } else {
            range = match.range(withName: group)
        }
        return range.location == NSNotFound ? "" : haystack.substring(with: range)
    }

    static func splitEscaped(_ argument: String) -> [String] {
        var parts = [""]
        var escaped = false
        for character in argument {
            if escaped {
                parts[parts.count - 1].append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                parts.append("")
            } else {
                parts[parts.count - 1].append(character)
            }
        }
        return parts
    }

    static func jsonValue(in root: Any, path: String) -> String? {
        var remaining = Substring(path.trimmingCharacters(in: .whitespaces))
        if remaining.hasPrefix("$") { remaining = remaining.dropFirst() }
        var current: Any = root
        for component in remaining.split(whereSeparator: { $0 == "." || $0 == "[" }) {
            var key = String(component)
            let bracketed = key.hasSuffix("]")
            if bracketed {
                key = String(key.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            }
            if bracketed, let index = Int(key), let array = current as? [Any] {
                guard array.indices.contains(index) else { return nil }
                current = array[index]
            } else if let dictionary = current as? [String: Any], let next = dictionary[key] {
                current = next
            } else {
                return nil
            }
        }
        switch current {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}

final class CustomUploader {

    static let shared = CustomUploader()
    static let userDefaultsKey = "customUploaderConfig"

    private let session: URLSession
    private let configurationOverride: CustomUploaderConfig?

    init(session: URLSession = .shared, config: CustomUploaderConfig? = nil) {
        self.session = session
        self.configurationOverride = config
    }

    var config: CustomUploaderConfig? {
        if let configurationOverride { return configurationOverride }
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey) else { return nil }
        return try? CustomUploaderConfig(sxcu: data)
    }

    var isConfigured: Bool { config != nil }

    @discardableResult
    static func importFile(at url: URL) throws -> CustomUploaderConfig {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CustomUploaderConfig.maxFileBytes else { throw CustomUploaderError.unreadableFile }
        let data = try Data(contentsOf: url)
        let config = try CustomUploaderConfig(sxcu: data)
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
        return config
    }

    static func remove() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    func uploadImage(_ image: NSImage, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<ImageUploadResult, Error>) -> Void) {
        do {
            let pixels = try HistoryImageSnapshot.Image(image)
            let template = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
            upload(payload: .image(pixels), filename: FilenameFormatter.format(template: template) + ".png",
                   contentType: "image/png", progress: progress, completion: completion)
        } catch { completion(.failure(error)) }
    }

    func uploadVideo(url: URL, progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                     completion: @escaping (Result<ImageUploadResult, Error>) -> Void) {
        let types = ["gif": "image/gif", "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"]
        upload(payload: .file(url), filename: url.lastPathComponent,
               contentType: types[url.pathExtension.lowercased()] ?? "application/octet-stream",
               progress: progress, completion: completion)
    }

    func upload(payload: UploadPayload, filename: String, contentType: String,
                progress: (@MainActor @Sendable (Double) -> Void)? = nil,
                completion: @escaping (Result<ImageUploadResult, Error>) -> Void) {
        guard let cfg = config else { completion(.failure(CustomUploaderError.notConfigured)); return }
        let session = self.session
        UploadJob.start(filename: filename, operation: {
            var request = try cfg.request(filename: filename)
            let body: PreparedUploadBody
            switch cfg.body {
            case .binary:
                body = try await MediaExportIO.perform { try PreparedUploadBody(payload: payload) }
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            case .multipart:
                let boundary = UUID().uuidString
                let fieldName = cfg.fileFormName
                let fields = cfg.formFields(filename: filename)
                body = try await MediaExportIO.perform {
                    try PreparedUploadBody(formFile: payload, fieldName: fieldName, filename: filename,
                                           contentType: contentType, fields: fields, boundary: boundary)
                }
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            }
            request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
            let (data, response) = try await UploadTransport.upload(session: session, request: request, body: body, progress: progress)
            return try cfg.result(from: CustomUploaderResponse(body: data, http: response, filename: filename))
        }, completion: completion)
    }
}
#endif
