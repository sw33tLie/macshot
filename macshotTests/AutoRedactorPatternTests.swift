import XCTest

/// Auto-redact is a privacy feature: a pattern that stops matching means a user
/// publishes a screenshot believing their API key is covered when it isn't.
/// These cover the regex layer — the part that decides what gets a black box —
/// without needing OCR.
final class AutoRedactorPatternTests: XCTestCase {

    private func matches(_ text: String, types: [String]? = nil) -> [String] {
        AutoRedactor.sensitiveMatches(in: text, enabledTypes: types).map(\.name)
    }

    private func matchedText(_ text: String, types: [String]? = nil) -> [String] {
        AutoRedactor.sensitiveMatches(in: text, enabledTypes: types).map { String(text[$0.range]) }
    }

    private func assertRedacted(_ text: String, as type: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(matches(text).contains(type),
                      "\"\(text)\" was not detected as \(type) — it would be left visible",
                      file: file, line: line)
    }

    private func assertNotRedacted(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = matches(text)
        XCTAssertTrue(found.isEmpty,
                      "\"\(text)\" was covered as \(found) — a false positive hides real content",
                      file: file, line: line)
    }

    // MARK: - Emails

    func testEmailsAreDetected() {
        for email in ["user@example.com", "first.last+tag@sub.domain.co.uk",
                      "UPPER@EXAMPLE.COM", "a_b-c%d@example.io"] {
            assertRedacted(email, as: "email")
        }
    }

    func testEmailInSentenceIsDetectedButOnlyTheAddress() {
        let text = "Contact me at jane@example.com about the invoice"
        XCTAssertEqual(matchedText(text, types: ["email"]), ["jane@example.com"])
    }

    func testTextThatIsNotAnEmailIsLeftAlone() {
        for text in ["just text", "@handle", "user@", "@example.com"] {
            XCTAssertFalse(matches(text, types: ["email"]).contains("email"), "\(text) matched as email")
        }
    }

    // MARK: - Credentials

    func testAWSAccessKeysAreDetected() {
        assertRedacted("AKIAIOSFODNN7EXAMPLE", as: "aws_key")
        assertRedacted("ASIAY34FZKBOKMUTVV7A", as: "aws_key")
    }

    func testBearerTokensAreDetected() {
        assertRedacted("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc-_123=", as: "bearer")
        assertRedacted("Authorization: Bearer sk_live_abc123", as: "bearer")
    }

    func testSecretAssignmentsAreDetected() {
        for line in ["password: hunter2", "api_key=abcd1234", "API-KEY: xyz",
                     "secret = s3cr3t", "access_key=AKIA...", "private_key: -----BEGIN",
                     "token=ghp_abcdefg"] {
            assertRedacted(line, as: "secret_assignment")
        }
    }

    func testLongHexStringsAreDetected() {
        assertRedacted("d41d8cd98f00b204e9800998ecf8427e", as: "hex_key")           // 32 chars
        assertRedacted(String(repeating: "a1b2", count: 16), as: "hex_key")          // 64 chars
    }

    func testShortHexIsNotTreatedAsAKey() {
        // A colour code or a short id shouldn't be covered.
        XCTAssertFalse(matches("#a1b2c3", types: ["hex_key"]).contains("hex_key"))
        XCTAssertFalse(matches("deadbeef", types: ["hex_key"]).contains("hex_key"))
    }

    // MARK: - Numbers

    func testCreditCardNumbersAreDetected() {
        for card in ["4111 1111 1111 1111", "4111-1111-1111-1111", "4111111111111111",
                     "3782 822463 10005", "5500 0000 0000 0004",
                     "4111 1111 1111 111"] {   // OCR dropped a digit
            assertRedacted(card, as: "credit_card")
        }
    }

    func testOrdinaryNumberPairsAreNotMistakenForCards() {
        // Two short groups of digits are everywhere — years, resolutions,
        // totals. Covering them hides content the user wanted to show.
        for text in ["2026 2026", "1024 768", "Total 1234 5678", "1920 1080 60", "192 168 1 1"] {
            XCTAssertFalse(matches(text, types: ["credit_card"]).contains("credit_card"),
                           "\"\(text)\" was covered as a credit card")
        }
    }

    func testSocialSecurityNumbersAreDetected() {
        assertRedacted("123-45-6789", as: "ssn")
        assertRedacted("123 45 6789", as: "ssn")
    }

    func testPhoneNumbersAreDetected() {
        for phone in ["555-123-4567", "(555) 123-4567", "+1 555 123 4567", "555.123.4567"] {
            assertRedacted(phone, as: "phone")
        }
    }

    func testIPAddressesAreDetected() {
        assertRedacted("192.168.1.100", as: "ipv4")
        assertRedacted("10.0.0.1", as: "ipv4")
        assertRedacted("Server at 203.0.113.42 responded", as: "ipv4")
    }

    func testCVVAndExpiryAreDetected() {
        assertRedacted("CVV: 123", as: "cvv")
        assertRedacted("CVC 4567", as: "cvv")
        assertRedacted("12/26", as: "expiry")
        assertRedacted("2026-12", as: "expiry")
    }

    // MARK: - Enabled types

    func testOnlyEnabledTypesMatch() {
        let text = "jane@example.com and 192.168.0.1"
        XCTAssertEqual(Set(matches(text, types: ["email"])), ["email"],
                       "a type the user turned off must not redact")
        XCTAssertEqual(Set(matches(text, types: ["ipv4"])), ["ipv4"])
    }

    func testNoEnabledTypesMeansNothingIsRedacted() {
        XCTAssertTrue(matches("jane@example.com", types: []).isEmpty)
    }

    func testNilEnabledTypesMeansEveryPatternIsActive() {
        let found = Set(matches("jane@example.com 192.168.0.1 AKIAIOSFODNN7EXAMPLE", types: nil))
        XCTAssertTrue(found.isSuperset(of: ["email", "ipv4", "aws_key"]))
    }

    func testEveryAdvertisedTypeCanActuallyMatchSomething() {
        // The settings list offers each of these; one that can never match would
        // be a checkbox that does nothing.
        let samples: [String: String] = [
            "email": "a@b.co",
            "phone": "555-123-4567",
            "ssn": "123-45-6789",
            "credit_card": "4111 1111 1111 1111",
            "cvv": "CVV: 321",
            "expiry": "11/28",
            "ipv4": "10.1.2.3",
            "aws_key": "AKIAIOSFODNN7EXAMPLE",
            "secret_assignment": "token=abc123",
            "hex_key": "d41d8cd98f00b204e9800998ecf8427e",
            "bearer": "Bearer abc123",
        ]
        for (type, _) in AutoRedactor.redactTypeNames.map({ ($0.key, $0.label) }) {
            guard let sample = samples[type] else {
                return XCTFail("no sample text for advertised redact type `\(type)`")
            }
            XCTAssertTrue(matches(sample, types: [type]).contains(type),
                          "`\(type)` is offered in settings but never matches \"\(sample)\"")
        }
    }

    func testEveryAdvertisedTypeHasALabel() {
        for entry in AutoRedactor.redactTypeNames {
            XCTAssertFalse(entry.label.isEmpty, "redact type \(entry.key) has no label")
        }
    }

    // MARK: - Ordinary content stays visible

    func testCommonUITextIsNotRedacted() {
        for text in ["Settings", "Save As...", "Hello world", "Chapter 4",
                     "macshot 4.2.1", "Press ⌘S to save"] {
            assertNotRedacted(text)
        }
    }

    func testEmptyAndWhitespaceTextMatchNothing() {
        assertNotRedacted("")
        assertNotRedacted("   \n\t ")
    }

    func testAVeryLongLineDoesNotHangTheScan() {
        // Pathological input shouldn't make the regexes backtrack forever.
        let long = String(repeating: "word ", count: 20_000) + "jane@example.com"
        let start = Date()
        let found = matches(long, types: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "pattern scan took too long")
        XCTAssertTrue(found.contains("email"))
    }

    func testContainsSensitiveTextAgreesWithTheMatchList() {
        XCTAssertTrue(AutoRedactor.containsSensitiveText("jane@example.com"))
        XCTAssertFalse(AutoRedactor.containsSensitiveText("nothing to see here"))
    }
}
