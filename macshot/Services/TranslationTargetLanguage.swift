import Foundation

enum TranslationTargetLanguage {
    static let preferenceKey = "translateTargetLang"

    static func explicitLanguage(
        in defaults: UserDefaults,
        supportedCodes: Set<String>
    ) -> String? {
        guard
            let language = defaults.string(forKey: preferenceKey),
            supportedCodes.contains(language)
        else {
            return nil
        }

        return language
    }

    static func setExplicitLanguage(
        _ language: String?,
        in defaults: UserDefaults,
        supportedCodes: Set<String>
    ) {
        guard let language else {
            defaults.removeObject(forKey: preferenceKey)
            return
        }

        guard supportedCodes.contains(language) else { return }
        defaults.set(language, forKey: preferenceKey)
    }

    static func resolvedLanguage(
        defaults: UserDefaults,
        preferredLanguages: [String],
        supportedCodes: Set<String>,
        fallback: String = "en"
    ) -> String {
        explicitLanguage(in: defaults, supportedCodes: supportedCodes)
            ?? systemLanguage(
                preferredLanguages: preferredLanguages,
                supportedCodes: supportedCodes,
                fallback: fallback
            )
    }

    static func systemLanguage(
        preferredLanguages: [String],
        supportedCodes: Set<String>,
        fallback: String = "en"
    ) -> String {
        guard let preferredLanguage = preferredLanguages.first else { return fallback }

        let components = preferredLanguage
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map { $0.lowercased() }
        guard let baseCode = components.first else { return fallback }

        let language: String
        if baseCode == "zh" {
            let subtags = Set(components.dropFirst())
            if subtags.contains("hant") {
                language = "zh-TW"
            } else if subtags.contains("hans") {
                language = "zh-CN"
            } else if !subtags.isDisjoint(with: ["tw", "hk", "mo"]) {
                language = "zh-TW"
            } else {
                language = "zh-CN"
            }
        } else {
            language = baseCode
        }

        return supportedCodes.contains(language) ? language : fallback
    }
}
