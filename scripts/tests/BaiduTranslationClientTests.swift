import Foundation

@main
struct BaiduTranslationClientTests {
    private static var failures = 0

    static func main() {
        expect(TranslationProvider(rawValue: "baidu") == .baidu,
               "declares Baidu as a translation provider")
        expect(SettingsPortability.looksSecret("baiduTranslateSecretKey"),
               "excludes the Baidu secret from settings export")
        expect(SettingsPortability.isPortable("baiduTranslateAppID"),
               "allows the non-secret Baidu APP ID in settings export")

        expect(BaiduTranslationClient.languageCode(for: "zh-CN") == "zh",
               "maps Simplified Chinese")
        expect(BaiduTranslationClient.languageCode(for: "zh-TW") == "cht",
               "maps Traditional Chinese")
        expect(BaiduTranslationClient.languageCode(for: "ja") == "jp",
               "maps Japanese")
        expect(BaiduTranslationClient.languageCode(for: "en") == "en",
               "passes through Baidu-compatible codes")

        let signature = BaiduTranslationClient.signature(
            appID: "2015063000000001",
            query: "apple",
            salt: "65478",
            secret: "1234567890"
        )
        expect(signature == "a1a7461d92e5194c5cae3182b5b24de1",
               "matches Baidu's documented signature")

        let successJSON = Data("""
        {
          "from": "en",
          "to": "zh",
          "trans_result": [
            {"src": "apple", "dst": "苹果"},
            {"src": "banana", "dst": "香蕉"}
          ]
        }
        """.utf8)
        do {
            let translations = try BaiduTranslationClient.decodeTranslations(
                data: successJSON,
                expectedCount: 2
            )
            expect(translations == ["苹果", "香蕉"],
                   "decodes ordered translation results")
        } catch {
            fail("decodes ordered translation results: \(error)")
        }

        let apiErrorJSON = Data("""
        {"error_code": "54001", "error_msg": "Invalid Sign"}
        """.utf8)
        expectThrows("surfaces Baidu API errors") {
            _ = try BaiduTranslationClient.decodeTranslations(
                data: apiErrorJSON,
                expectedCount: 1
            )
        }

        expectThrows("rejects mismatched result counts") {
            _ = try BaiduTranslationClient.decodeTranslations(
                data: successJSON,
                expectedCount: 1
            )
        }

        let indexed = BaiduTranslationClient.indexedNonEmptyTexts([
            " hello ", "", " \n ", "world",
        ])
        expect(indexed.map(\.index) == [0, 3],
               "preserves indexes for non-empty text")
        expect(indexed.map(\.text) == ["hello", "world"],
               "trims non-empty source text")

        let multiline = BaiduTranslationClient.indexedNonEmptyTexts([
            "first line\nsecond line",
        ])
        expect(multiline.map(\.text) == ["first line second line"],
               "normalizes embedded newlines before batching")

        let split = BaiduTranslationClient.preparedTexts(
            ["abcdefghijk"],
            maxUTF8Bytes: 5
        )
        expect(split.map(\.index) == [0, 0, 0],
               "keeps the source index when splitting long text")
        expect(split.allSatisfy { $0.text.lengthOfBytes(using: .utf8) <= 5 },
               "splits a long source text at UTF-8-safe boundaries")

        let throttle = BaiduTranslationClient.RequestThrottle(interval: 1.05)
        let firstDelay = throttle.reserveDelay(now: 100)
        let secondDelay = throttle.reserveDelay(now: 100)
        expect(firstDelay == 0 && abs(secondDelay - 1.05) < 0.000_1,
               "reserves globally spaced request start times")

        expect(
            BaiduTranslationClient.configurationError(appID: "", secret: "secret") != nil,
            "requires a Baidu APP ID"
        )
        expect(
            BaiduTranslationClient.configurationError(appID: "appid", secret: " ") != nil,
            "requires a Baidu Secret Key"
        )
        expect(
            BaiduTranslationClient.configurationError(appID: "appid", secret: "secret") == nil,
            "accepts complete Baidu credentials"
        )

        let chunks = BaiduTranslationClient.makeChunks(
            from: [
                .init(index: 0, text: "1234"),
                .init(index: 1, text: "5678"),
                .init(index: 2, text: "90"),
            ],
            maxUTF8Bytes: 9
        )
        expect(chunks.map { $0.map(\.index) } == [[0, 1], [2]],
               "chunks at source item boundaries")

        do {
            let settingsSource = try String(
                contentsOfFile: "macshot/UI/Windows/SettingsWindowController.swift",
                encoding: .utf8
            )
            expect(
                settingsSource.contains(
                    "stack.setCustomSpacing(6, after: baiduAppIDRow)"
                ),
                "separates the Baidu APP ID and Secret Key rows"
            )
        } catch {
            fail("reads settings source for Baidu row spacing: \(error)")
        }

        if failures == 0 {
            print("BaiduTranslationClientTests: all checks passed")
        } else {
            fputs("BaiduTranslationClientTests: \(failures) failure(s)\n", stderr)
            exit(1)
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ name: String
    ) {
        if condition() {
            print("PASS: \(name)")
        } else {
            fail(name)
        }
    }

    private static func expectThrows(
        _ name: String,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            fail(name)
        } catch {
            print("PASS: \(name)")
        }
    }

    private static func fail(_ name: String) {
        failures += 1
        fputs("FAIL: \(name)\n", stderr)
    }
}
