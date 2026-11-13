import AppKit
import CoreText
import XCTest

/// The pieces of the out-of-process OCR path that run without the XPC service.
/// The service itself, its sandboxed launch and its recovery from a stuck
/// Vision request are exercised in the real app by scripts/probe-ocr-service.sh.
final class OCRServiceTests: XCTestCase {

    private func cgImage(_ image: NSImage) throws -> CGImage {
        try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func textImage(_ text: String) -> CGImage {
        let context = CGContext(data: nil, width: 900, height: 160, bitsPerComponent: 8, bytesPerRow: 900 * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 900, height: 160))
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black,
        ])
        context.textPosition = CGPoint(x: 24, y: 70)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        return context.makeImage()!
    }

    // MARK: - Pixels across the process boundary

    func testPixelsSurviveTheTrip() throws {
        let source = try cgImage(ImageProbe.quadrantImage(width: 64, height: 48))
        let packed = try XCTUnwrap(OCRServicePixels.pack(source))
        XCTAssertEqual(packed.width, 64)
        XCTAssertEqual(packed.height, 48)
        XCTAssertEqual(packed.data.count, packed.bytesPerRow * packed.height)

        let rebuilt = try XCTUnwrap(OCRServicePixels.unpack(packed.data, width: packed.width, height: packed.height,
                                                            bytesPerRow: packed.bytesPerRow))
        let before = NSImage(cgImage: source, size: NSSize(width: 64, height: 48))
        let after = NSImage(cgImage: rebuilt, size: NSSize(width: 64, height: 48))
        for (x, y) in [(5, 5), (60, 5), (5, 40), (60, 40)] {
            let a = try XCTUnwrap(ImageProbe.pixelColor(before, x: x, y: y))
            let b = try XCTUnwrap(ImageProbe.pixelColor(after, x: x, y: y))
            XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.01, "(\(x),\(y))")
            XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.01, "(\(x),\(y))")
            XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.01, "(\(x),\(y))")
        }
    }

    func testTheServiceRejectsInconsistentPixels() {
        let data = Data(count: 16 * 4 * 4)
        XCTAssertNotNil(OCRServicePixels.unpack(data, width: 16, height: 4, bytesPerRow: 64))
        XCTAssertNil(OCRServicePixels.unpack(data, width: 16, height: 5, bytesPerRow: 64), "buffer too short")
        XCTAssertNil(OCRServicePixels.unpack(data, width: 16, height: 4, bytesPerRow: 60), "row narrower than the image")
        XCTAssertNil(OCRServicePixels.unpack(data, width: 0, height: 4, bytesPerRow: 64))
        XCTAssertNil(OCRServicePixels.unpack(data, width: 16, height: -1, bytesPerRow: 64))
        XCTAssertNil(OCRServicePixels.unpack(data, width: 16, height: Int.max / 2, bytesPerRow: 64), "size overflows")
    }

    // MARK: - Substring boxes

    func testCharacterBoxesSkipWhitespace() {
        let boxes = OCRCharacterBoxes.compute(text: "ab c") { range in
            CGRect(x: CGFloat("ab c".distance(from: "ab c".startIndex, to: range.lowerBound)), y: 0, width: 1, height: 1)
        }
        XCTAssertEqual(boxes.count, 4)
        XCTAssertNotNil(boxes[0])
        XCTAssertNil(boxes[2], "Vision's box for a space spans to the image edge, so it's dropped")
    }

    func testSubstringBoxIsTheUnionOfItsCharacters() throws {
        let text = "pay jane@x.io now"
        let boxes = OCRCharacterBoxes.compute(text: text) { range in
            let offset = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound))
            return CGRect(x: offset * 0.05, y: 0.4, width: 0.04, height: 0.2)
        }
        let email = try XCTUnwrap(text.range(of: "jane@x.io"))
        let box = try XCTUnwrap(OCRCharacterBoxes.union(text: text, boxes: boxes, range: email))
        XCTAssertEqual(box.minX, 4 * 0.05, accuracy: 1e-9)
        XCTAssertEqual(box.maxX, 12 * 0.05 + 0.04, accuracy: 1e-9)

        // A range spanning a space ignores the space's (missing) box.
        let span = try XCTUnwrap(text.range(of: "y j"))
        let spanBox = try XCTUnwrap(OCRCharacterBoxes.union(text: text, boxes: boxes, range: span))
        XCTAssertEqual(spanBox.minX, 2 * 0.05, accuracy: 1e-9)
        XCTAssertEqual(spanBox.maxX, 4 * 0.05 + 0.04, accuracy: 1e-9)

        XCTAssertNil(OCRCharacterBoxes.union(text: text, boxes: boxes, range: try XCTUnwrap(text.range(of: " "))),
                     "only whitespace: the caller falls back to the line box")
        XCTAssertNil(OCRCharacterBoxes.union(text: text, boxes: [], range: email), "boxes not requested")
    }

    func testCharacterBoxesCountGraphemesNotCodeUnits() throws {
        let text = "e\u{301} 👍🏽 ok"
        let boxes = OCRCharacterBoxes.compute(text: text) { _ in CGRect(x: 0, y: 0, width: 1, height: 1) }
        XCTAssertEqual(boxes.count, text.count)
        let ok = try XCTUnwrap(text.range(of: "ok"))
        XCTAssertNotNil(OCRCharacterBoxes.union(text: text, boxes: boxes, range: ok))
    }

    func testResponseRoundTripKeepsMissingBoxes() throws {
        let response = OCRServiceResponse(lines: [
            OCRServiceLine(text: "a b", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
                           characterBoxes: [CGRect(x: 0.1, y: 0.2, width: 0.05, height: 0.4), nil,
                                            CGRect(x: 0.3, y: 0.2, width: 0.05, height: 0.4)]),
        ])
        let decoded = try JSONDecoder().decode(OCRServiceResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.lines.first?.text, "a b")
        XCTAssertEqual(decoded.lines.first?.boundingBox, response.lines[0].boundingBox)
        XCTAssertEqual(decoded.lines.first?.characterBoxes.count, 3)
        XCTAssertNil(decoded.lines[0].characterBoxes[1])
    }

    // MARK: - Routing without a usable service

    private func recognize(_ client: OCRServiceClient, _ image: CGImage) -> (text: String, route: OCRServiceClient.Route?) {
        let done = expectation(description: "OCR")
        var text = ""
        var route: OCRServiceClient.Route?
        client.recognize(cgImage: image, preferredLanguages: ["en-US"]) { lines, _, finishedRoute in
            text = lines.map(\.text).joined(separator: " ")
            route = finishedRoute
            done.fulfill()
        }
        wait(for: [done], timeout: 90)
        return (text, route)
    }

    func testWithoutAnEmbeddedServiceOCRRunsInProcess() {
        XCTAssertNil(OCRServiceClient.embeddedServiceName(), "the test runner embeds no service")
        let result = recognize(OCRServiceClient(serviceName: nil), textImage("Golden Gate Bridge"))
        XCTAssertEqual(result.route, .inProcess)
        XCTAssertTrue(result.text.contains("Golden Gate"), result.text)
    }

    func testAServiceThatCannotLaunchStillReturnsTextThenStopsBeingTried() {
        let client = OCRServiceClient(serviceName: "com.sw33tlie.macshot.tests.no-such-service")
        client.setTiming(.init(softTimeout: 10, hardDeadline: 120, fastTimeout: 10, relaunchThrottle: 0))
        let image = textImage("Invoice total due Friday")
        var routes: [OCRServiceClient.Route?] = []
        for _ in 0..<4 {
            let result = recognize(client, image)
            routes.append(result.route)
            XCTAssertTrue(result.text.contains("Invoice"), "the user still gets text: \(result.text)")
        }
        let withoutService: OCRServiceClient.Route =
            OCRServiceClient.inProcessAccurateIsUnsafe ? .fastWithoutService : .inProcess
        XCTAssertEqual(routes, [.fastAfterServiceFailure, .fastAfterServiceFailure, withoutService, withoutService],
                       "the third launch failure stops trying the service: the original in-process path, "
                       + "or only the fast model on macOS 27 where in-process accurate OCR can hang")
    }

    func testAReplacedYoungServiceIsNotWaitedOn() {
        let client = OCRServiceClient(serviceName: "com.sw33tlie.macshot.tests.no-such-service")
        let image = textImage("Invoice total due Friday")
        XCTAssertEqual(recognize(client, image).route, .fastAfterServiceFailure)
        let started = Date()
        let second = recognize(client, image)
        XCTAssertEqual(second.route, .fastWhileServiceRestarts, "launchd would hold the relaunch back")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
