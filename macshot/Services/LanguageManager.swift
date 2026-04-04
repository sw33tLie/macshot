import Foundation

/// Manages the active language for the app.
/// Loads from UserDefaults ("appLanguage"), falls back to system language, then English.
/// Supports runtime switching without app restart by swapping the active bundle.
final class LanguageManager {
    static let shared = LanguageManager()

    static let changedNotification = Notification.Name("LanguageManagerDidChange")

    /// Language code -> display name (in that language)
    static let availableLanguages: [(code: String, name: String)] = [
        ("system", "System Default"),
        ("ar", "العربية"),
        ("bg", "Български"),
        ("bn", "বাংলা"),
        ("ca", "Català"),
        ("cs", "Čeština"),
        ("da", "Dansk"),
        ("de", "Deutsch"),
        ("el", "Ελληνικά"),
        ("en", "English"),
        ("es", "Español"),
        ("fa", "فارسی"),
        ("fi", "Suomi"),
        ("fil", "Filipino"),
        ("fr", "Français"),
        ("he", "עברית"),
        ("hi", "हिन्दी"),
        ("hr", "Hrvatski"),
        ("hu", "Magyar"),
        ("id", "Bahasa Indonesia"),
        ("it", "Italiano"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("ms", "Bahasa Melayu"),
        ("nb", "Norsk bokmål"),
        ("nl", "Nederlands"),
        ("pl", "Polski"),
        ("pt", "Português"),
        ("pt-BR", "Português (Brasil)"),
        ("ro", "Română"),
        ("ru", "Русский"),
        ("sk", "Slovenčina"),
        ("sr", "Српски"),
        ("sv", "Svenska"),
        ("ta", "தமிழ்"),
        ("th", "ไทย"),
        ("tr", "Türkçe"),
        ("uk", "Українська"),
        ("vi", "Tiếng Việt"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
    ]

    private var bundle: Bundle = .main

    private init() {
        reload()
    }

    /// The active language code. "system" means follow macOS preference.
    var currentLanguage: String {
        get { UserDefaults.standard.string(forKey: "appLanguage") ?? "system" }
        set {
            UserDefaults.standard.set(newValue, forKey: "appLanguage")
            reload()
            NotificationCenter.default.post(name: Self.changedNotification, object: nil)
        }
    }

    /// Resolves the actual language code (never "system").
    var resolvedLanguage: String {
        let lang = currentLanguage
        if lang == "system" {
            // Find first system language we support
            let supported = Self.availableLanguages.map(\.code).filter { $0 != "system" }
            for preferred in Locale.preferredLanguages {
                // Check full code first (e.g. "zh-Hans"), then base language (e.g. "de")
                let normalized = preferred.replacingOccurrences(of: "_", with: "-")
                if supported.contains(normalized) { return normalized }
                // Try with script subtag (zh-Hans-CN -> zh-Hans)
                let parts = normalized.split(separator: "-")
                if parts.count >= 2 {
                    let withScript = "\(parts[0])-\(parts[1])"
                    if supported.contains(withScript) { return withScript }
                }
                let base = String(parts[0])
                if supported.contains(base) { return base }
            }
            return "en"
        }
        return lang
    }

    func localizedString(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    private func reload() {
        let lang = resolvedLanguage
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let langBundle = Bundle(path: path) {
            bundle = langBundle
        } else {
            bundle = .main
        }
    }
}

/// Shorthand for localized string lookup.
func L(_ key: String) -> String {
    LanguageManager.shared.localizedString(key)
}
