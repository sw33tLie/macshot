import AppKit
import CoreText
import Vision
import XCTest

final class VisionOCRTests: XCTestCase {
    private func line(_ text: String) -> OCRTextObservation {
        OCRTextObservation(text: text, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.3))
    }

    private func image(_ text: String) -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 160, bitsPerComponent: 8,
            bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 160))
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black
        ])
        context.textPosition = CGPoint(x: 24, y: 70)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        return context.makeImage()!
    }

    // Exercise the full production path from a cold process, including deadlines.
    func testRepeatedRecognitionAndSubstringGeometry() {
        let image = image("Contact hello@example.com today")
        for attempt in 1...6 {
            let done = expectation(description: "OCR attempt \(attempt)")
            let started = Date()
            VisionOCR.performTextRecognition(cgImage: image) { lines, error in
                XCTAssertNil(error)
                let text = lines.map(\.text).joined(separator: "\n")
                XCTAssertTrue(text.contains("hello@example.com"), text)
                if let line = lines.first(where: { $0.text.contains("hello@example.com") }),
                   let range = line.text.range(of: "hello@example.com") {
                    let box = line.boundingBox(for: range)
                    XCTAssertNotNil(box)
                    XCTAssertGreaterThan(box?.width ?? 0, 0)
                    XCTAssertLessThan(box?.width ?? 1, line.boundingBox.width)
                    XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(line.boundingBox))
                }
                let elapsed = Date().timeIntervalSince(started)
                XCTAssertLessThan(elapsed, 12)
                print("OCR production attempt \(attempt): \(elapsed)s")
                done.fulfill()
            }
            wait(for: [done], timeout: 12)
        }
    }

    // A fast fallback must not mask the legacy first-succeeds-then-fails bug.
    func testRepeatedRequestsThroughAccurateAPI() {
        let image = image("Accurate recognition")
        for attempt in 1...6 {
            let done = expectation(description: "primary accurate request \(attempt)")
            _ = VisionOCR.startTextRecognition(cgImage: image, recognitionLevel: .accurate) { result in
                switch result {
                case .failure(let error): XCTFail("Accurate request \(attempt) failed: \(error)")
                case .success(let lines):
                    let text = lines.map(\.text).joined(separator: "\n")
                    XCTAssertTrue(text.contains("Accurate recognition"), text)
                }
                done.fulfill()
            }
            // This unbounded single-attempt entry point intentionally bypasses
            // recovery. The production deadline is tested independently.
            wait(for: [done], timeout: 60)
        }
    }

    func testTextRecognitionPreservesCyrillic() throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("Modern Vision language support") }
        let done = expectation(description: "Cyrillic OCR")
        _ = VisionOCR.startTextRecognition(cgImage: image("Привет мир"), recognitionLevel: .accurate) { result in
            switch result {
            case .failure(let error): XCTFail("Cyrillic OCR failed: \(error)")
            case .success(let lines):
                let text = lines.map(\.text).joined(separator: "\n")
                XCTAssertTrue(text.contains("Привет"), text)
            }
            done.fulfill()
        }
        // Cold accurate model compilation can still take >30s on macOS 27.
        // The production deadline/fallback is exercised separately above.
        wait(for: [done], timeout: 60)
    }

    func testEmptyAccurateResultRetriesFast() {
        assertRetry(for: .success([]))
        assertRetry(for: .success([line(" \n ")]))
    }

    func testAccurateErrorRetriesFast() {
        assertRetry(for: .failure(NSError(domain: "E5RT", code: 13)))
    }

    func testRecognitionLanguagesPutTheUsersScriptBeforeEnglish() {
        let supported = ["en-US", "fr-FR", "zh-Hans", "zh-Hant", "yue-Hant", "ja-JP", "pt-BR", "nb-NO", "vi-VT"]
        let languages = { VisionOCR.recognitionLanguages(preferred: $0, supported: supported) }
        XCTAssertEqual(languages(["zh-Hans-CN", "en-GB"]), ["zh-Hans", "en-US"])
        XCTAssertEqual(languages(["zh-TW"]), ["zh-Hant", "en-US"])
        XCTAssertEqual(languages(["zh_HK", "ja"]), ["zh-Hant", "ja-JP", "en-US"])
        XCTAssertEqual(languages(["en-US", "ja-JP"]), ["en-US", "ja-JP"])
        XCTAssertEqual(languages(["pt-PT", "nb", "vi-VN"]), ["pt-BR", "nb-NO", "vi-VT", "en-US"])
        // English only, or nothing Vision supports: keep Vision's default.
        XCTAssertEqual(languages(["en-GB"]), [])
        XCTAssertEqual(languages(["ko-KR", "xx"]), [])
        XCTAssertEqual(languages([]), [])
    }

    // #462: a line mixing Chinese and English came back as "42 Privacy & Security"
    // or "#*#I Screen Recording EA" while only English was listed.
    func testMixedChineseAndEnglishLineKeepsTheChinese() throws {
        guard #available(macOS 13.0, *) else { throw XCTSkip("Language list needs macOS 13") }
        let done = expectation(description: "Chinese OCR")
        _ = VisionOCR.startTextRecognition(cgImage: image("隐私与安全性 Privacy & Security"),
                                           recognitionLevel: .accurate,
                                           preferredLanguages: ["zh-Hans-CN", "en-US"]) { result in
            switch result {
            case .failure(let error): XCTFail("Chinese OCR failed: \(error)")
            case .success(let lines):
                let text = lines.map(\.text).joined(separator: "\n")
                XCTAssertTrue(text.contains("隐私与安全性"), text)
                XCTAssertTrue(text.contains("Privacy"), text)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
    }

    private func assertRetry(for firstResult: Result<[OCRTextObservation], Error>) {
        let done = expectation(description: "fast recovery")
        var levels: [VNRequestTextRecognitionLevel] = []
        OCRRecognitionSession(timeout: 1, startAttempt: { level, callback in
            levels.append(level)
            callback(level == .accurate ? firstResult : .success([self.line("Recovered")]))
            return {}
        }, completion: { observations, error in
            XCTAssertNil(error)
            XCTAssertEqual(observations.map(\.text), ["Recovered"])
            XCTAssertEqual(levels, [.accurate, .fast])
            done.fulfill()
        }).start()
        wait(for: [done], timeout: 2)
    }

    func testAccurateSuccessDoesNotRetry() {
        let done = expectation(description: "accurate success")
        OCRRecognitionSession(timeout: 1, startAttempt: { level, callback in
            XCTAssertEqual(level, .accurate)
            callback(.success([self.line("Recognized")]))
            return {}
        }, completion: { lines, error in
            XCTAssertNil(error)
            XCTAssertEqual(lines.map(\.text), ["Recognized"])
            done.fulfill()
        }).start()
        wait(for: [done], timeout: 2)
    }

    func testTimedOutAttemptIsCancelledAndLateDuplicateResultsAreIgnored() {
        let done = expectation(description: "fast result delivered once")
        done.assertForOverFulfill = true
        let late = expectation(description: "late primary results delivered")
        let cancelled = expectation(description: "primary cancelled")
        OCRRecognitionSession(timeout: 0.03, startAttempt: { level, callback in
            if level == .accurate {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) {
                    callback(.success([self.line("Obsolete")]))
                    callback(.failure(NSError(domain: "E5RT", code: 13)))
                    late.fulfill()
                }
                return { cancelled.fulfill() }
            }
            callback(.success([self.line("Fast")]))
            callback(.success([self.line("Duplicate")]))
            return {}
        }, completion: { lines, error in
            XCTAssertNil(error)
            XCTAssertEqual(lines.map(\.text), ["Fast"])
            done.fulfill()
        }).start()
        wait(for: [done, cancelled, late], timeout: 2)
        // Drain the serial queue's late callbacks before ending this test.
        let drained = expectation(description: "late callbacks drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testBothStalledAttemptsFinishWithTimeout() {
        let done = expectation(description: "bounded failure")
        let cancelled = expectation(description: "both cancelled")
        cancelled.expectedFulfillmentCount = 2
        let started = Date()
        OCRRecognitionSession(timeout: 0.03, startAttempt: { _, _ in
            return { cancelled.fulfill() }
        }, completion: { lines, error in
            XCTAssertTrue(lines.isEmpty)
            XCTAssertTrue(error is OCRRecognitionSession.Failure)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            done.fulfill()
        }).start()
        wait(for: [done, cancelled], timeout: 2)
    }

    func testFastEmptyResultDoesNotLoop() {
        let done = expectation(description: "blank image")
        var attempts = 0
        OCRRecognitionSession(timeout: 1, startAttempt: { _, callback in
            attempts += 1
            callback(.success([]))
            return {}
        }, completion: { lines, error in
            XCTAssertEqual(attempts, 2)
            XCTAssertNil(error)
            XCTAssertTrue(lines.isEmpty)
            done.fulfill()
        }).start()
        wait(for: [done], timeout: 2)
    }

    func testFastFailureIsReportedAfterOneRetry() {
        let done = expectation(description: "final failure")
        let failure = NSError(domain: "E5RT", code: 13)
        var attempts = 0
        OCRRecognitionSession(timeout: 1, startAttempt: { _, callback in
            attempts += 1
            callback(.failure(failure))
            return {}
        }, completion: { lines, error in
            XCTAssertEqual(attempts, 2)
            XCTAssertTrue(lines.isEmpty)
            XCTAssertEqual(error as NSError?, failure)
            done.fulfill()
        }).start()
        wait(for: [done], timeout: 2)
    }

    func testFastRecognitionWorksAndQRPayloadFallbackRemains() {
        let done = expectation(description: "fast OCR")
        _ = VisionOCR.startTextRecognition(cgImage: image("Hello World"), recognitionLevel: .fast) { result in
            switch result {
            case .failure(let error): XCTFail("Fast OCR failed: \(error)")
            case .success(let lines): XCTAssertTrue(lines.map(\.text).joined().contains("Hello"))
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 12)
        XCTAssertEqual(OCRScanResult(text: "", qrCodes: [QRCodePayload(value: "https://example.com")]).copyText,
                       "https://example.com")
    }
}
