import XCTest
@testable import macshot

final class TranslationServiceTests: XCTestCase {
    func testExplicitProviderDoesNotChangeSavedProvider() {
        let savedProvider = TranslationService.provider
        let completion = expectation(description: "translation completes")

        TranslationService.translateBatch(
            texts: [], targetLang: "zh-CN", provider: .deepLX, requestScope: UUID()
        ) { result in
            guard case .success(let translations) = result else {
                XCTFail("Expected an empty successful result")
                completion.fulfill()
                return
            }
            XCTAssertTrue(translations.isEmpty)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
        XCTAssertEqual(TranslationService.provider, savedProvider)
    }

    func testCompletionReturnsOnMainThreadWhenCalledFromBackground() {
        let completion = expectation(description: "main-thread completion")

        DispatchQueue.global(qos: .userInitiated).async {
            TranslationService.translateBatch(
                texts: [], targetLang: "zh-CN", provider: .deepLX, requestScope: UUID()
            ) { _ in
                XCTAssertTrue(Thread.isMainThread)
                completion.fulfill()
            }
        }

        wait(for: [completion], timeout: 1)
    }

    func testDeepLXEndpointEncodesAPIKeyPlaceholder() throws {
        let resolved = try TranslationService.resolveDeepLXEndpoint(
            template: "https://example.com/translate?token={{apiKey}}",
            apiKey: "a+b/c?= &%")

        XCTAssertTrue(resolved.embedsAPIKey)
        XCTAssertEqual(
            resolved.url.absoluteString,
            "https://example.com/translate?token=a%2Bb%2Fc%3F%3D%20%26%25")
    }

    func testDeepLXEndpointRequiresKeyForPlaceholder() {
        XCTAssertThrowsError(try TranslationService.resolveDeepLXEndpoint(
            template: "https://example.com/translate?token={{apiKey}}",
            apiKey: ""))
    }

    func testLLMTranslationParserAcceptsJSONAndMarkdownFence() {
        assertTranslations(
            TranslationService.parseLLMTranslations(
                "[\"你好\",\"世界\"]", expectedCount: 2),
            equal: ["你好", "世界"])
        assertTranslations(
            TranslationService.parseLLMTranslations(
                "```json\n[\"你好\"]\n```", expectedCount: 1),
            equal: ["你好"])
    }

    func testLLMTranslationParserRejectsWrongJSONItemCount() {
        let result = TranslationService.parseLLMTranslations(
            "[\"你好\",\"世界\"]", expectedCount: 1)

        guard case .failure = result else {
            XCTFail("Expected an item-count error")
            return
        }
    }

    func testLLMTranslationParserRejectsMalformedSingleResults() {
        let outputs = [
            "[\"hello", "[123]", "{\"translation\":\"hello\"}",
            "null", "\"hello\"", "Translation failed", "",
            "```json\n[\"hello\"]", "```json\n[\"hello\"]\nnot a closing fence",
        ]
        for output in outputs {
            guard case .failure = TranslationService.parseLLMTranslations(
                output, expectedCount: 1) else {
                XCTFail("Expected rejection of: \(output)")
                continue
            }
        }
    }

    func testLLMTranslationParserAcceptsSingleJSONStringArray() {
        assertTranslations(
            TranslationService.parseLLMTranslations("[\"hello\"]", expectedCount: 1),
            equal: ["hello"])
    }

    private func assertTranslations(
        _ result: Result<[String], Error>,
        equal expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let translations):
            XCTAssertEqual(translations, expected, file: file, line: line)
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)", file: file, line: line)
        }
    }
}
