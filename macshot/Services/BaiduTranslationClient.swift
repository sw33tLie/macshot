import CryptoKit
import Foundation

/// Baidu General Text Translation API adapter.
///
/// Baidu accepts newline-separated text as one batch and returns one
/// `trans_result` entry per source line. Keeping that behavior here avoids
/// coupling provider-specific language codes and rate limits to UI callers.
enum BaiduTranslationClient {
    struct IndexedText {
        let index: Int
        let text: String
    }

    private final class BatchState: @unchecked Sendable {
        nonisolated(unsafe) var output: [String]

        nonisolated init(texts: [String], translatedIndexes: Set<Int>) {
            output = texts
            for index in translatedIndexes {
                output[index] = ""
            }
        }

        nonisolated func append(_ translation: String, at index: Int) {
            if output[index].isEmpty {
                output[index] = translation
            } else {
                output[index] += " \(translation)"
            }
        }
    }

    final class RequestThrottle: @unchecked Sendable {
        nonisolated let interval: TimeInterval
        nonisolated private let lock = NSLock()
        nonisolated(unsafe) private var nextStart: TimeInterval = 0

        nonisolated init(interval: TimeInterval) {
            self.interval = interval
        }

        nonisolated func reserveDelay(now: TimeInterval) -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }

            let start = max(now, nextStart)
            nextStart = start + interval
            return start - now
        }

        nonisolated func schedule(_ work: @escaping @Sendable () -> Void) {
            let delay = reserveDelay(now: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + delay,
                execute: work
            )
        }
    }

    enum ClientError: LocalizedError {
        case notConfigured
        case invalidResponse
        case resultCountMismatch(expected: Int, actual: Int)
        case httpError(Int)
        case apiError(code: String, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Configure Baidu Translate APP ID and Secret Key in Settings."
            case .invalidResponse:
                return "Could not parse the Baidu Translate response."
            case .resultCountMismatch(let expected, let actual):
                return "Baidu Translate returned \(actual) result(s) for \(expected) source text(s)."
            case .httpError(let status):
                return "Baidu Translate returned HTTP \(status)."
            case .apiError(let code, let message):
                return "Baidu Translate error \(code): \(message)"
            }
        }
    }

    nonisolated private static let endpoint = URL(
        string: "https://fanyi-api.baidu.com/api/trans/vip/translate"
    )!
    nonisolated private static let maxChunkUTF8Bytes = 5_500
    nonisolated private static let requestThrottle = RequestThrottle(interval: 1.05)

    nonisolated private static let languageCodes: [String: String] = [
        "zh-CN": "zh",
        "zh-TW": "cht",
        "ja": "jp",
        "ko": "kor",
        "fr": "fra",
        "es": "spa",
        "ar": "ara",
        "sv": "swe",
        "da": "dan",
        "fi": "fin",
        "nb": "nor",
        "uk": "ukr",
        "ro": "rom",
        "bg": "bul",
        "hr": "hrv",
        "vi": "vie",
    ]

    nonisolated static func languageCode(for code: String) -> String {
        languageCodes[code] ?? code
    }

    nonisolated static func signature(
        appID: String,
        query: String,
        salt: String,
        secret: String
    ) -> String {
        let source = Data("\(appID)\(query)\(salt)\(secret)".utf8)
        return Insecure.MD5.hash(data: source)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func indexedNonEmptyTexts(_ texts: [String]) -> [IndexedText] {
        texts.enumerated().compactMap { index, text in
            let normalized = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return normalized.isEmpty ? nil : IndexedText(index: index, text: normalized)
        }
    }

    nonisolated static func preparedTexts(
        _ texts: [String],
        maxUTF8Bytes: Int
    ) -> [IndexedText] {
        indexedNonEmptyTexts(texts).flatMap { item in
            splitText(item.text, maxUTF8Bytes: maxUTF8Bytes).map {
                IndexedText(index: item.index, text: $0)
            }
        }
    }

    private nonisolated static func splitText(
        _ text: String,
        maxUTF8Bytes: Int
    ) -> [String] {
        guard !text.isEmpty, maxUTF8Bytes > 0 else { return [] }

        var parts: [String] = []
        var current = ""
        var currentBytes = 0

        for character in text {
            let characterBytes = String(character).lengthOfBytes(using: .utf8)
            if !current.isEmpty && currentBytes + characterBytes > maxUTF8Bytes {
                parts.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += characterBytes
        }

        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }

    nonisolated static func configurationError(
        appID: String,
        secret: String
    ) -> ClientError? {
        let cleanAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanAppID.isEmpty || cleanSecret.isEmpty ? .notConfigured : nil
    }

    nonisolated static func makeChunks(
        from texts: [IndexedText],
        maxUTF8Bytes: Int
    ) -> [[IndexedText]] {
        guard !texts.isEmpty else { return [] }

        var chunks: [[IndexedText]] = []
        var current: [IndexedText] = []
        var currentBytes = 0

        for item in texts {
            let itemBytes = item.text.lengthOfBytes(using: .utf8)
            let separatorBytes = current.isEmpty ? 0 : 1
            if !current.isEmpty && currentBytes + separatorBytes + itemBytes > maxUTF8Bytes {
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            current.append(item)
            currentBytes += (current.count == 1 ? 0 : 1) + itemBytes
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    nonisolated static func decodeTranslations(
        data: Data,
        expectedCount: Int
    ) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }

        if let rawCode = object["error_code"] {
            let code = String(describing: rawCode)
            let message = object["error_msg"] as? String ?? "Unknown error"
            throw ClientError.apiError(code: code, message: message)
        }

        guard let rawResults = object["trans_result"] as? [[String: Any]] else {
            throw ClientError.invalidResponse
        }
        guard rawResults.count == expectedCount else {
            throw ClientError.resultCountMismatch(
                expected: expectedCount,
                actual: rawResults.count
            )
        }

        return try rawResults.map { item in
            guard let translated = item["dst"] as? String else {
                throw ClientError.invalidResponse
            }
            return translated
        }
    }

    nonisolated static func translateBatch(
        texts: [String],
        targetLang: String,
        appID: String,
        secret: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let cleanAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = configurationError(appID: cleanAppID, secret: cleanSecret) {
            completeOnMain(.failure(error), completion: completion)
            return
        }

        let indexed = preparedTexts(texts, maxUTF8Bytes: maxChunkUTF8Bytes)
        guard !indexed.isEmpty else {
            completeOnMain(.success(texts), completion: completion)
            return
        }

        let chunks = makeChunks(from: indexed, maxUTF8Bytes: maxChunkUTF8Bytes)
        let state = BatchState(
            texts: texts,
            translatedIndexes: Set(indexed.map(\.index))
        )

        func processChunk(at chunkIndex: Int) {
            guard chunkIndex < chunks.count else {
                completeOnMain(.success(state.output), completion: completion)
                return
            }

            let chunk = chunks[chunkIndex]
            request(
                chunk: chunk,
                targetLang: targetLang,
                appID: cleanAppID,
                secret: cleanSecret
            ) { result in
                switch result {
                case .failure(let error):
                    completeOnMain(.failure(error), completion: completion)

                case .success(let translations):
                    for (item, translated) in zip(chunk, translations) {
                        state.append(translated, at: item.index)
                    }
                    processChunk(at: chunkIndex + 1)
                }
            }
        }

        processChunk(at: 0)
    }

    private nonisolated static func request(
        chunk: [IndexedText],
        targetLang: String,
        appID: String,
        secret: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let query = chunk.map(\.text).joined(separator: "\n")
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let sign = signature(appID: appID, query: query, salt: salt, secret: secret)

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: languageCode(for: targetLang)),
            URLQueryItem(name: "appid", value: appID),
            URLQueryItem(name: "salt", value: salt),
            URLQueryItem(name: "sign", value: sign),
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 15
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let preparedRequest = request

        requestThrottle.schedule {
            URLSession.shared.dataTask(with: preparedRequest) { data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    completion(.failure(ClientError.httpError(http.statusCode)))
                    return
                }
                guard let data else {
                    completion(.failure(ClientError.invalidResponse))
                    return
                }

                do {
                    let translations = try decodeTranslations(
                        data: data,
                        expectedCount: chunk.count
                    )
                    completion(.success(translations))
                } catch {
                    completion(.failure(error))
                }
            }.resume()
        }
    }

    private nonisolated static func completeOnMain<T>(
        _ result: Result<T, Error>,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        if Thread.isMainThread {
            completion(result)
        } else {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}
