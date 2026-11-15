import Foundation
import NaturalLanguage
import Combine
import SwiftUI
import Security
@preconcurrency import Translation

enum TranslationProvider: String, CaseIterable {
    case apple = "apple"
    case google = "google"
    case deepLX = "deeplx"
    case openAICompletions = "openai-completions"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"

    var displayNameKey: String {
        switch self {
        case .apple: return "Apple (on-device)"
        case .google: return "Google Translate"
        case .deepLX: return "DeepLX"
        case .openAICompletions: return "OpenAI Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        }
    }

    var usesEndpoint: Bool {
        switch self {
        case .apple, .google: return false
        default: return true
        }
    }

    var usesModel: Bool {
        switch self {
        case .openAICompletions, .openAIResponses, .anthropicMessages: return true
        default: return false
        }
    }

    var usesAPIKey: Bool {
        switch self {
        case .deepLX, .openAICompletions, .openAIResponses, .anthropicMessages: return true
        default: return false
        }
    }
}

enum TranslationService {

    // MARK: - Provider

    static var provider: TranslationProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: "translationProvider"),
               let p = TranslationProvider(rawValue: raw) { return p }
            return .google  // Google by default — Apple requires language pack downloads
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "translationProvider") }
    }

    private static let endpointKeyPrefix = "translationEndpoint."
    private static let modelKeyPrefix = "translationModel."
    private static let keychainService =
        "\(Bundle.main.bundleIdentifier ?? "com.sw33tlie.macshot.macshot").translation"

    static func endpoint(for provider: TranslationProvider) -> String {
        let key = endpointKeyPrefix + provider.rawValue
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        switch provider {
        case .deepLX: return "http://localhost:1188/translate"
        case .openAICompletions: return "https://api.openai.com/v1/chat/completions"
        case .openAIResponses: return "https://api.openai.com/v1/responses"
        case .anthropicMessages: return "https://api.anthropic.com/v1/messages"
        case .apple, .google: return ""
        }
    }

    static func setEndpoint(_ endpoint: String, for provider: TranslationProvider) {
        UserDefaults.standard.set(
            endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: endpointKeyPrefix + provider.rawValue)
    }

    static func model(for provider: TranslationProvider) -> String {
        let key = modelKeyPrefix + provider.rawValue
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        return ""
    }

    static func setModel(_ model: String, for provider: TranslationProvider) {
        UserDefaults.standard.set(
            model.trimmingCharacters(in: .whitespacesAndNewlines),
            forKey: modelKeyPrefix + provider.rawValue)
    }

    static func apiKey(for provider: TranslationProvider) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func setAPIKey(_ apiKey: String, for provider: TranslationProvider) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: provider.rawValue,
        ]
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TranslationError.keychain(status)
            }
            return
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw TranslationError.configuration("Could not encode the API Key.")
        }
        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TranslationError.keychain(updateStatus)
        }

        var item = identity
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TranslationError.keychain(addStatus)
        }
    }

    /// Whether Apple Translation is available on this system.
    static var appleTranslationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// Cached Apple language availability — populated on first check,
    /// reused instantly for subsequent popover opens.
    private static var cachedAppleAvailability: [String: Bool]?

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

    /// Check which languages are available for Apple Translation.
    /// Returns a dict of language code → installed status.
    @available(macOS 15.0, *)
    static func checkAppleLanguageAvailability(completion: @escaping ([String: Bool]) -> Void) {
        // Return cache immediately if available
        if let cached = cachedAppleAvailability {
            completion(cached)
            return
        }

        Task {
            let availability = LanguageAvailability()
            let allLocales = availableLanguages.map { (code: $0.code, locale: appleLocale(from: $0.code)) }

            // Find the first installed pair to get a known-installed "probe" language.
            // Then check all remaining languages against that probe — O(n) instead of O(n²).
            var installed: [String: Bool] = [:]
            var probeLocale: Locale.Language?
            var probeCode: String?

            // Quick scan: find any installed pair
            outerLoop: for (i, lang) in allLocales.enumerated() {
                for other in allLocales[(i+1)...] {
                    let status = await availability.status(from: lang.locale, to: other.locale)
                    if status == .installed {
                        installed[lang.code] = true
                        installed[other.code] = true
                        probeLocale = lang.locale
                        probeCode = lang.code
                        break outerLoop
                    }
                }
            }

            // Check remaining languages against the probe
            if let probe = probeLocale, let pc = probeCode {
                for lang in allLocales where installed[lang.code] != true {
                    // Check both directions since the probe→lang direction
                    // might not be valid but lang→probe could be
                    let toStatus = await availability.status(from: probe, to: lang.locale)
                    let fromStatus = await availability.status(from: lang.locale, to: probe)
                    installed[lang.code] = (toStatus == .installed || fromStatus == .installed)
                }
                // Ensure the probe itself is marked
                installed[pc] = true
            }

            // Any language not checked stays false
            for lang in allLocales where installed[lang.code] == nil {
                installed[lang.code] = false
            }

            await MainActor.run {
                // Only cache if we found at least one installed language.
                // If the Translation framework wasn't ready (e.g. right after
                // launch), all languages come back as not-installed — don't
                // cache that or the popover stays empty for the whole session.
                if installed.values.contains(true) {
                    cachedAppleAvailability = installed
                }
                completion(installed)
            }
        }
    }

    // MARK: - Translate a batch of strings (auto-detect source)

    /// Translates multiple strings using the provider saved in Settings.
    /// Calls completion on the main queue.
    static func translateBatch(
        texts: [String],
        targetLang: String,
        requestScope: UUID,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        translateBatch(
            texts: texts,
            targetLang: targetLang,
            provider: provider,
            requestScope: requestScope,
            completion: completion)
    }

    /// Translates with an explicit provider without changing the saved provider.
    /// This supports transient choices such as the Quick Translation panel.
    static func translateBatch(
        texts: [String],
        targetLang: String,
        provider: TranslationProvider,
        requestScope: UUID,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let finish: (Result<[String], Error>) -> Void = { result in
            if Thread.isMainThread {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }

        guard !texts.isEmpty else {
            finish(.success([]))
            return
        }

        switch provider {
        case .apple:
            if #available(macOS 15.0, *) {
                translateBatchApple(
                    texts: texts,
                    targetLang: targetLang,
                    requestScope: requestScope,
                    completion: finish)
            } else {
                translateBatchGoogle(texts: texts, targetLang: targetLang, completion: finish)
            }
        case .google:
            translateBatchGoogle(texts: texts, targetLang: targetLang, completion: finish)
        case .deepLX:
            translateBatchDeepLX(texts: texts, targetLang: targetLang, completion: finish)
        case .openAICompletions, .openAIResponses, .anthropicMessages:
            translateBatchLLM(
                texts: texts, targetLang: targetLang, provider: provider, completion: finish)
        }
    }

    // MARK: - Google Translate (unofficial endpoint)

    private static func translateBatchGoogle(
        texts: [String],
        targetLang: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
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
            translateOneGoogle(text: trimmed, targetLang: targetLang) { result in
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

    private static func translateOneGoogle(
        text: String,
        targetLang: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
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
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let outer = json.first as? [[Any]] else {
                completion(.failure(TranslationError.parseError))
                return
            }
            let translated = outer.compactMap { $0.first as? String }.joined()
            guard !translated.isEmpty else {
                completion(.failure(TranslationError.emptyResult))
                return
            }
            completion(.success(translated))
        }.resume()
    }

    // MARK: - DeepLX

    private static func translateBatchDeepLX(
        texts: [String],
        targetLang: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let endpointConfiguration: (url: URL, embedsAPIKey: Bool)
        do {
            endpointConfiguration = try configuredDeepLXEndpoint()
        } catch {
            completion(.failure(error))
            return
        }

        // Initialize preserved blank entries before any asynchronous writes start.
        var results = texts
        let group = DispatchGroup()
        let lock = NSLock()
        var firstError: Error?

        for (index, text) in texts.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            group.enter()
            var request = URLRequest(url: endpointConfiguration.url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !endpointConfiguration.embedsAPIKey {
                addBearerTokenIfPresent(to: &request, provider: .deepLX)
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": trimmed,
                "source_lang": "auto",
                "target_lang": deepLXLanguageCode(targetLang),
            ])

            performJSONRequest(request) { result in
                lock.lock()
                defer {
                    lock.unlock()
                    group.leave()
                }
                switch result {
                case .success(let json):
                    if let translated = deepLXText(from: json), !translated.isEmpty {
                        results[index] = translated
                    } else if firstError == nil {
                        firstError = TranslationError.parseError
                    }
                case .failure(let error):
                    if firstError == nil { firstError = error }
                }
            }
        }

        group.notify(queue: .main) {
            if let firstError {
                completion(.failure(firstError))
            } else {
                completion(.success(results))
            }
        }
    }

    private static func deepLXLanguageCode(_ code: String) -> String {
        switch code {
        case "zh-CN", "zh-TW": return "ZH"
        default: return code.uppercased()
        }
    }

    private static func deepLXText(from json: [String: Any]) -> String? {
        if let data = json["data"] as? String { return data }
        if let translation = json["translation"] as? String { return translation }
        if let translations = json["translations"] as? [[String: Any]],
           let text = translations.first?["text"] as? String { return text }
        return nil
    }

    // MARK: - LLM protocols

    private static func translateBatchLLM(
        texts: [String],
        targetLang: String,
        provider: TranslationProvider,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard let url = configuredURL(for: provider) else {
            completion(.failure(TranslationError.configuration("Translation endpoint is invalid.")))
            return
        }
        let model = model(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            completion(.failure(TranslationError.configuration("A model name is required.")))
            return
        }

        let language = availableLanguages.first(where: { $0.code == targetLang })?.name
            ?? targetLang
        let payloadTexts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let inputData = try? JSONSerialization.data(withJSONObject: payloadTexts),
              let inputJSON = String(data: inputData, encoding: .utf8) else {
            completion(.failure(TranslationError.configuration("Could not encode translation input.")))
            return
        }

        let instructions = """
        You are a translation engine. Translate every item into \(language). Preserve meaning, \
        paragraph breaks, URLs, names, numbers, and formatting. Return only a JSON array of \
        translated strings in the same order and with the same item count. Do not add markdown \
        fences or explanations.
        """
        let input = "Input JSON array:\n\(inputJSON)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = apiKey(for: provider)

        let body: [String: Any]
        switch provider {
        case .openAICompletions:
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": input],
                ],
                "stream": false,
            ]
        case .openAIResponses:
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            body = ["model": model, "instructions": instructions, "input": input]
        case .anthropicMessages:
            if !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": 8192,
                "system": instructions,
                "messages": [["role": "user", "content": input]],
            ]
        default:
            completion(.failure(TranslationError.configuration("Unsupported LLM protocol.")))
            return
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        performJSONRequest(request) { result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let json):
                    guard let output = llmText(from: json, provider: provider) else {
                        completion(.failure(TranslationError.parseError))
                        return
                    }
                    completion(parseLLMTranslations(output, expectedCount: texts.count))
                }
            }
        }
    }

    private static func llmText(
        from json: [String: Any],
        provider: TranslationProvider
    ) -> String? {
        switch provider {
        case .openAICompletions:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else { return nil }
            if let content = message["content"] as? String { return content }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        case .openAIResponses:
            if let outputText = json["output_text"] as? String { return outputText }
            guard let output = json["output"] as? [[String: Any]] else { return nil }
            let texts = output.compactMap { item -> String? in
                guard let content = item["content"] as? [[String: Any]] else { return nil }
                return content.compactMap { part in
                    guard part["type"] as? String == "output_text" else { return nil }
                    return part["text"] as? String
                }.joined()
            }
            return texts.joined()
        case .anthropicMessages:
            guard let content = json["content"] as? [[String: Any]] else { return nil }
            return content.compactMap { part in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined()
        default:
            return nil
        }
        return nil
    }

    static func parseLLMTranslations(
        _ output: String,
        expectedCount: Int
    ) -> Result<[String], Error> {
        var trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            guard lines.count >= 3,
                  lines.last?.trimmingCharacters(in: .whitespaces) == "```" else {
                return .failure(TranslationError.parseError)
            }
            trimmed = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        if let data = trimmed.data(using: .utf8),
           let translations = try? JSONSerialization.jsonObject(with: data) as? [String] {
            guard translations.count == expectedCount else {
                return .failure(TranslationError.invalidItemCount)
            }
            return .success(translations)
        }
        return .failure(TranslationError.parseError)
    }

    private static func configuredURL(for provider: TranslationProvider) -> URL? {
        configuredURL(from: endpoint(for: provider))
    }

    private static func configuredDeepLXEndpoint() throws -> (url: URL, embedsAPIKey: Bool) {
        try resolveDeepLXEndpoint(
            template: endpoint(for: .deepLX), apiKey: apiKey(for: .deepLX))
    }

    static func resolveDeepLXEndpoint(
        template endpointTemplate: String,
        apiKey: String
    ) throws -> (url: URL, embedsAPIKey: Bool) {
        let placeholder = "{{apiKey}}"
        let embedsAPIKey = endpointTemplate.contains(placeholder)
        var resolvedEndpoint = endpointTemplate

        if embedsAPIKey {
            guard !apiKey.isEmpty else {
                throw TranslationError.configuration(
                    "DeepLX endpoint uses {{apiKey}}, but the API Key is empty.")
            }
            let unreserved = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let encodedKey = apiKey.addingPercentEncoding(
                withAllowedCharacters: unreserved) else {
                throw TranslationError.configuration("Could not encode the DeepLX API Key.")
            }
            resolvedEndpoint = endpointTemplate.replacingOccurrences(
                of: placeholder, with: encodedKey)
        }

        guard let url = configuredURL(from: resolvedEndpoint) else {
            throw TranslationError.configuration("DeepLX endpoint is invalid.")
        }
        return (url, embedsAPIKey)
    }

    private static func configuredURL(from endpoint: String) -> URL? {
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" {
            let host = url.host?.lowercased() ?? ""
            guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                return nil
            }
        } else if scheme != "https" {
            return nil
        }
        return url
    }

    private static func addBearerTokenIfPresent(
        to request: inout URLRequest,
        provider: TranslationProvider
    ) {
        let token = apiKey(for: provider)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func performJSONRequest(
        _ request: URLRequest,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(TranslationError.noData))
                return
            }
            guard let data else {
                completion(.failure(TranslationError.noData))
                return
            }

            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(TranslationError.httpStatus(
                    http.statusCode, responseMessage(from: json))))
                return
            }
            guard let json else {
                completion(.failure(TranslationError.parseError))
                return
            }
            completion(.success(json))
        }.resume()
    }

    private static func responseMessage(from json: [String: Any]?) -> String? {
        if let error = json?["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        if let message = json?["message"] as? String { return message }
        if let message = json?["msg"] as? String { return message }
        return nil
    }

    // MARK: - Apple Translation (macOS 15.0+ via SwiftUI bridge)

    @available(macOS 15.0, *)
    private static func translateBatchApple(
        texts: [String],
        targetLang: String,
        requestScope: UUID,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let target = appleLocale(from: targetLang)

        // Auto-detect source language to avoid Apple's "Choose Language" dialog
        let combined = texts.joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(combined)

        guard let detected = recognizer.dominantLanguage else {
            // Can't detect language (single word, ambiguous text). Report on the
            // main thread — this is invoked from a background OCR queue and the
            // completion handler mutates overlay UI (the success path below also
            // hops to main).
            DispatchQueue.main.async {
                completion(.failure(TranslationError.appleTranslation("Could not detect source language. Try selecting more text.")))
            }
            return
        }

        let source = Locale.Language(identifier: detected.rawValue)
        let config = TranslationSession.Configuration(source: source, target: target)
        // Must dispatch to main — TranslationBridge adds a SwiftUI view which requires main thread
        DispatchQueue.main.async {
            TranslationBridge.shared.translate(
                texts: texts,
                configuration: config,
                requestScope: requestScope,
                completion: completion)
        }
    }

    static func cancelTranslations(requestScope: UUID) {
        guard #available(macOS 15.0, *) else { return }
        DispatchQueue.main.async {
            TranslationBridge.shared.cancel(requestScope: requestScope)
        }
    }

    /// Map our language codes to Apple's Locale.Language.
    @available(macOS 15.0, *)
    private static func appleLocale(from code: String) -> Locale.Language {
        switch code {
        case "zh-CN": return Locale.Language(identifier: "zh-Hans")
        case "zh-TW": return Locale.Language(identifier: "zh-Hant")
        case "nb":    return Locale.Language(identifier: "no")
        default:      return Locale.Language(identifier: code)
        }
    }
}

// MARK: - SwiftUI bridge for Apple Translation

/// Uses a hidden SwiftUI view with .translationTask() to obtain a TranslationSession.
/// This is the supported way to use the Translation framework from AppKit.
@available(macOS 15.0, *)
@MainActor
final class TranslationBridge: ObservableObject {
    static let shared = TranslationBridge()

    private struct Request {
        let texts: [String]
        let configuration: TranslationSession.Configuration
        let scope: UUID
        let completion: (Result<[String], Error>) -> Void
    }

    @Published var config: TranslationSession.Configuration?
    private var hostingView: NSView?
    private var pendingTexts: [String] = []
    private var pendingCompletion: ((Result<[String], Error>) -> Void)?
    private var pendingRequestScope: UUID?
    private var translationID: UUID?
    private var queuedRequests: [Request] = []

    func translate(
        texts: [String],
        configuration: TranslationSession.Configuration,
        requestScope: UUID,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        let request = Request(
            texts: texts,
            configuration: configuration,
            scope: requestScope,
            completion: completion)

        if pendingRequestScope == requestScope, let activeID = translationID {
            finish(
                .failure(TranslationError.requestReplaced),
                requestID: activeID)
        }

        if let queuedIndex = queuedRequests.firstIndex(where: { $0.scope == requestScope }) {
            let replaced = queuedRequests[queuedIndex]
            queuedRequests[queuedIndex] = request
            replaced.completion(.failure(TranslationError.requestReplaced))
            return
        }

        if pendingCompletion != nil {
            queuedRequests.append(request)
        } else {
            start(request)
        }
    }

    func cancel(requestScope: UUID) {
        let queued = queuedRequests.filter { $0.scope == requestScope }
        queuedRequests.removeAll { $0.scope == requestScope }
        for request in queued {
            request.completion(.failure(TranslationError.requestReplaced))
        }

        if pendingRequestScope == requestScope, let activeID = translationID {
            finish(
                .failure(TranslationError.requestReplaced),
                requestID: activeID)
        }
    }

    private func start(_ request: Request) {
        let thisID = UUID()
        translationID = thisID
        pendingTexts = request.texts
        pendingCompletion = request.completion
        pendingRequestScope = request.scope

        // Create hidden SwiftUI view and attach to a window
        let view = TranslationBridgeView(bridge: self, requestID: thisID)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: -1, y: -1, width: 1, height: 1)
        if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            window.contentView?.addSubview(hosting)
        }
        hostingView = hosting

        // Setting config triggers .translationTask
        config = request.configuration

        // Timeout: if session doesn't respond in 10s, report error
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.translationID == thisID, self.pendingCompletion != nil else { return }
            self.finish(
                .failure(TranslationError.appleTranslation(
                    "Apple Translation timed out. The language pack may need to be downloaded in System Settings.")),
                requestID: thisID)
        }
    }

    fileprivate func sessionReady(_ session: TranslationSession, requestID: UUID) {
        // Ignore sessions delivered by a bridge view from a replaced request.
        guard pendingCompletion != nil, translationID == requestID else { return }
        let activeID = requestID
        let texts = pendingTexts
        Task {
            do {
                var results = Array(repeating: "", count: texts.count)
                for (i, text) in texts.enumerated() {
                    // Bail if a new translation was started while we're iterating
                    let stillActive = await MainActor.run { self.translationID == activeID }
                    guard stillActive else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        results[i] = text
                        continue
                    }
                    let response = try await session.translate(trimmed)
                    results[i] = response.targetText
                }
                await MainActor.run {
                    self.finish(.success(results), requestID: activeID)
                }
            } catch {
                await MainActor.run {
                    guard self.translationID == activeID else { return }
                    let desc = error.localizedDescription
                    let msg = "Apple Translation failed: \(desc). You can switch to Google Translate in Settings."
                    self.finish(
                        .failure(TranslationError.appleTranslation(msg)), requestID: activeID)
                }
            }
        }
    }

    private func finish(_ result: Result<[String], Error>, requestID: UUID) {
        guard translationID == requestID, let completion = pendingCompletion else { return }
        cleanupActiveRequest()
        startNextRequestIfNeeded()
        completion(result)
    }

    private func startNextRequestIfNeeded() {
        guard pendingCompletion == nil, !queuedRequests.isEmpty else { return }
        start(queuedRequests.removeFirst())
    }

    private func cleanupActiveRequest() {
        hostingView?.removeFromSuperview()
        hostingView = nil
        pendingTexts = []
        pendingCompletion = nil
        pendingRequestScope = nil
        translationID = nil
        config = nil
    }
}

@available(macOS 15.0, *)
private struct TranslationBridgeView: View {
    @ObservedObject var bridge: TranslationBridge
    let requestID: UUID

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.config) { session in
                await MainActor.run {
                    bridge.sessionReady(session, requestID: requestID)
                }
            }
    }
}

enum TranslationError: LocalizedError {
    case badURL, noData, parseError, emptyResult
    case invalidItemCount
    case keychain(OSStatus)
    case requestReplaced
    case configuration(String)
    case httpStatus(Int, String?)
    case appleTranslation(String)
    var errorDescription: String? {
        switch self {
        case .badURL:      return "Invalid translation URL"
        case .noData:      return "No response from translation service"
        case .parseError:  return "Could not parse translation response"
        case .emptyResult: return "Translation returned empty result"
        case .invalidItemCount:
            return "The translation response did not match the requested item count"
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Could not save API Key: \(message)"
            }
            return "Could not save API Key (Keychain error \(status))"
        case .requestReplaced:
            return "Translation request was replaced by a newer request"
        case .configuration(let message):
            return message
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty { return "HTTP \(status): \(message)" }
            return "Translation service returned HTTP \(status)"
        case .appleTranslation(let msg): return msg
        }
    }
}
