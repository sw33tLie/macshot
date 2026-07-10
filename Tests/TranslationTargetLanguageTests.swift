import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expectEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: T,
    _ message: String
) throws {
    let actualValue = actual()
    guard actualValue == expected else {
        throw TestFailure(
            description: "\(message): expected \(String(describing: expected)), got \(String(describing: actualValue))"
        )
    }
}

@main
private enum TranslationTargetLanguageTests {
    private static let supportedCodes: Set<String> = ["en", "pt", "zh-CN", "zh-TW"]

    static func main() {
        do {
            try testSystemLanguageResolution()
            try testExplicitLanguageOverridesSystemLanguage()
            try testClearingExplicitLanguageRestoresSystemResolution()
            try testInvalidStoredLanguageIsIgnoredAndPreserved()
            print("TranslationTargetLanguageTests: PASS")
        } catch {
            FileHandle.standardError.write(Data("TranslationTargetLanguageTests: FAIL - \(error)\n".utf8))
            exit(1)
        }
    }

    private static func testSystemLanguageResolution() throws {
        try expectSystemLanguage("en-US", equals: "en")
        try expectSystemLanguage("pt-BR", equals: "pt")
        try expectSystemLanguage("en_US", equals: "en")

        for language in ["zh-Hans-US", "zh-SG", "zh"] {
            try expectSystemLanguage(language, equals: "zh-CN")
        }

        for language in ["zh-Hant-HK", "zh-HK", "zh-MO"] {
            try expectSystemLanguage(language, equals: "zh-TW")
        }

        try expectEqual(
            TranslationTargetLanguage.systemLanguage(
                preferredLanguages: ["fr-FR", "pt-BR"],
                supportedCodes: supportedCodes,
                fallback: "en"
            ),
            "en",
            "an unsupported first preferred language should use the fallback"
        )
        try expectEqual(
            TranslationTargetLanguage.systemLanguage(
                preferredLanguages: [],
                supportedCodes: supportedCodes,
                fallback: "en"
            ),
            "en",
            "empty preferred languages should use the fallback"
        )
    }

    private static func testExplicitLanguageOverridesSystemLanguage() throws {
        try withIsolatedDefaults { defaults in
            TranslationTargetLanguage.setExplicitLanguage(
                "pt",
                in: defaults,
                supportedCodes: supportedCodes
            )

            try expectEqual(
                TranslationTargetLanguage.resolvedLanguage(
                    defaults: defaults,
                    preferredLanguages: ["zh-Hans-US"],
                    supportedCodes: supportedCodes,
                    fallback: "en"
                ),
                "pt",
                "a valid explicit language should override the system language"
            )
        }
    }

    private static func testClearingExplicitLanguageRestoresSystemResolution() throws {
        try withIsolatedDefaults { defaults in
            TranslationTargetLanguage.setExplicitLanguage(
                "pt",
                in: defaults,
                supportedCodes: supportedCodes
            )
            TranslationTargetLanguage.setExplicitLanguage(
                nil,
                in: defaults,
                supportedCodes: supportedCodes
            )

            try expectEqual(
                TranslationTargetLanguage.resolvedLanguage(
                    defaults: defaults,
                    preferredLanguages: ["zh-SG"],
                    supportedCodes: supportedCodes,
                    fallback: "en"
                ),
                "zh-CN",
                "clearing the explicit language should restore system resolution"
            )
            try expectEqual(
                defaults.object(forKey: TranslationTargetLanguage.preferenceKey) == nil,
                true,
                "clearing the explicit language should remove the stored preference"
            )
        }
    }

    private static func testInvalidStoredLanguageIsIgnoredAndPreserved() throws {
        try withIsolatedDefaults { defaults in
            defaults.set("fr", forKey: TranslationTargetLanguage.preferenceKey)

            try expectEqual(
                TranslationTargetLanguage.explicitLanguage(
                    in: defaults,
                    supportedCodes: supportedCodes
                ),
                nil,
                "an unsupported stored language should be ignored"
            )
            try expectEqual(
                TranslationTargetLanguage.resolvedLanguage(
                    defaults: defaults,
                    preferredLanguages: ["pt-BR"],
                    supportedCodes: supportedCodes,
                    fallback: "en"
                ),
                "pt",
                "an unsupported stored language should defer to system resolution"
            )
            try expectEqual(
                defaults.string(forKey: TranslationTargetLanguage.preferenceKey),
                "fr",
                "an unsupported stored language should not be deleted"
            )
        }
    }

    private static func expectSystemLanguage(_ preferredLanguage: String, equals expected: String) throws {
        try expectEqual(
            TranslationTargetLanguage.systemLanguage(
                preferredLanguages: [preferredLanguage],
                supportedCodes: supportedCodes,
                fallback: "en"
            ),
            expected,
            "system language \(preferredLanguage)"
        )
    }

    private static func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "TranslationTargetLanguageTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure(description: "could not create isolated UserDefaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
