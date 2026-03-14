import Foundation

enum TranslationService {

    // MARK: - Target language

    static var targetLanguage: String {
        get { UserDefaults.standard.string(forKey: "translateTargetLang") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "translateTargetLang") }
    }

    static let availableLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("ru", "Russian"),
        ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("ar", "Arabic"),
        ("tr", "Turkish"),
        ("sv", "Swedish"),
        ("da", "Danish"),
        ("fi", "Finnish"),
        ("nb", "Norwegian"),
        ("uk", "Ukrainian"),
        ("cs", "Czech"),
        ("ro", "Romanian"),
        ("hu", "Hungarian"),
        ("sk", "Slovak"),
        ("bg", "Bulgarian"),
        ("hr", "Croatian"),
        ("id", "Indonesian"),
        ("hi", "Hindi"),
        ("th", "Thai"),
        ("vi", "Vietnamese"),
    ]

    // MARK: - Translate a batch of strings (auto-detect source)

    /// Translates multiple strings concurrently using the unofficial Google Translate endpoint.
    /// Calls completion on the main queue.
    static func translateBatch(
        texts: [String],
        targetLang: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard !texts.isEmpty else {
            completion(.success([]))
            return
        }

        var results = Array(repeating: "", count: texts.count)
        let group = DispatchGroup()
        var firstError: Error?
        let lock = NSLock()

        for (i, text) in texts.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                results[i] = text
                continue
            }
            group.enter()
            translateOne(text: trimmed, targetLang: targetLang) { result in
                lock.lock()
                switch result {
                case .success(let translated):
                    results[i] = translated
                case .failure(let error):
                    if firstError == nil { firstError = error }
                    results[i] = ""
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if let error = firstError {
                completion(.failure(error))
            } else {
                completion(.success(results))
            }
        }
    }

    // MARK: - Single string

    private static func translateOne(
        text: String,
        targetLang: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // Unofficial Google Translate endpoint — same neural backend as translate.google.com
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl",     value: "auto"),
            URLQueryItem(name: "tl",     value: targetLang),
            URLQueryItem(name: "dt",     value: "t"),
            URLQueryItem(name: "q",      value: text),
        ]
        guard let url = components.url else {
            completion(.failure(TranslationError.badURL))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(TranslationError.noData))
                return
            }
            // Response: [[[translated, original, ...], ...], ...]
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let outer = json.first as? [[Any]] else {
                completion(.failure(TranslationError.parseError))
                return
            }
            // Concatenate all translated segments
            let translated = outer.compactMap { $0.first as? String }.joined()
            guard !translated.isEmpty else {
                completion(.failure(TranslationError.emptyResult))
                return
            }
            completion(.success(translated))
        }.resume()
    }
}

enum TranslationError: LocalizedError {
    case badURL, noData, parseError, emptyResult
    var errorDescription: String? {
        switch self {
        case .badURL:      return "Invalid translation URL"
        case .noData:      return "No response from translation service"
        case .parseError:  return "Could not parse translation response"
        case .emptyResult: return "Translation returned empty result"
        }
    }
}
