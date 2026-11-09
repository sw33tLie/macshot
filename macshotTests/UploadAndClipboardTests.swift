import Cocoa
import XCTest

#if !OFFLINE
/// S3 configuration is entered by hand in Settings. A field that passes
/// validation but produces an unusable request sends the user chasing a
/// signature error that points nowhere near the field they got wrong.
final class S3ConfigTests: XCTestCase {

    private func config(endpoint: String = "https://example.r2.cloudflarestorage.com",
                        region: String = "auto",
                        bucket: String = "shots",
                        accessKeyID: String = "AKIAEXAMPLE",
                        secretAccessKey: String = "secret",
                        publicURLBase: String = "",
                        pathPrefix: String = "",
                        publicRead: Bool = false) -> S3Uploader.Config {
        S3Uploader.Config(endpoint: endpoint, region: region, bucket: bucket,
                          accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                          publicURLBase: publicURLBase, pathPrefix: pathPrefix, publicRead: publicRead)
    }

    func testAFullyFilledConfigIsValid() {
        XCTAssertTrue(config().isValid)
    }

    func testEachRequiredFieldIsRequired() {
        XCTAssertFalse(config(endpoint: "").isValid)
        XCTAssertFalse(config(bucket: "").isValid)
        XCTAssertFalse(config(accessKeyID: "").isValid)
        XCTAssertFalse(config(secretAccessKey: "").isValid)
    }

    func testAnEmptyRegionFallsBackInsteadOfSigningWithNothing() {
        // Clearing the field stores "", which used to sign a credential scope
        // with an empty region and fail as SignatureDoesNotMatch.
        XCTAssertEqual(config(region: "").effectiveRegion, "auto")
        XCTAssertEqual(config(region: "   ").effectiveRegion, "auto")
        XCTAssertTrue(config(region: "").isValid, "an empty region falls back rather than blocking upload")
    }

    func testAnExplicitRegionIsUsedAsTyped() {
        XCTAssertEqual(config(region: "us-east-1").effectiveRegion, "us-east-1")
        XCTAssertEqual(config(region: " eu-west-2 ").effectiveRegion, "eu-west-2", "surrounding spaces are trimmed")
    }

    func testPathPrefixPadsDateComponentsAndUsesCalendarYear() throws {
        // January 1 belongs to the previous ISO week-year in 2021.
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2021-01-01T12:00:00Z"))
        let prefix = config(pathPrefix: "screenshots/{year}/{month}/{day}/{year}-{month}-{day}/")
        XCTAssertEqual(prefix.resolvedPathPrefix(date: date, timeZone: TimeZone(secondsFromGMT: 0)!),
                       "screenshots/2021/01/01/2021-01-01/")
    }

    func testPathPrefixUsesLocalDateAcrossMidnightAndLeapDay() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-03-01T00:30:00Z"))
        let prefix = config(pathPrefix: "{year}/{month}/{day}")
        XCTAssertEqual(prefix.resolvedPathPrefix(date: date, timeZone: TimeZone(secondsFromGMT: -3600)!),
                       "2024/02/29")
        XCTAssertEqual(prefix.resolvedPathPrefix(date: date, timeZone: TimeZone(secondsFromGMT: 3600)!),
                       "2024/03/01")
    }

    func testPathPrefixPreservesLiteralPathsAndUnsupportedTokens() {
        for literal in ["", "screenshots/", "/folder+name//with spaces/", "yyyy/mm/dd",
                        "%year%/%month%/%day%", "{date}/{time}/{random}/{window}/{index}", "{Year}/{MONTH}/{DAY}"] {
            XCTAssertEqual(config(pathPrefix: literal).resolvedPathPrefix(), literal)
        }
    }
}
#endif

/// Pinned clipboard text is rendered on the main thread, and the HTML flavor is
/// parsed by WebKit. Both need limits.
final class ClipboardPinSafetyTests: XCTestCase {

    // MARK: - Size cap

    func testOrdinaryTextIsNotTruncated() {
        let text = "a short note"
        XCTAssertEqual(ClipboardTextPinRenderer.truncatedForPinning(text), text)
    }

    func testAHugePasteIsCappedBeforeLayout() {
        // Laying out a copied log file glyph by glyph on the main thread is
        // what made the app beachball, hotkeys included.
        let huge = String(repeating: "x", count: 500_000)
        let capped = ClipboardTextPinRenderer.truncatedForPinning(huge)
        XCTAssertLessThanOrEqual(capped.count, ClipboardTextPinRenderer.maxCharacters + 2)
        XCTAssertTrue(capped.hasSuffix("…"), "the pin should show the text was cut, not end mid-sentence")
    }

    func testAttributedTextIsCappedToo() {
        let attributed = NSAttributedString(string: String(repeating: "y", count: 400_000))
        let capped = ClipboardTextPinRenderer.truncatedForPinning(attributed)
        XCTAssertLessThanOrEqual(capped.length, ClipboardTextPinRenderer.maxCharacters + 2)
    }

    func testRenderingAHugePasteFinishesQuickly() {
        let attributed = ClipboardTextPinRenderer.plainAttributedString(String(repeating: "word ", count: 100_000))
        let start = Date()
        _ = ClipboardTextPinRenderer.render(attributed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0,
                          "a huge paste must not lock the main thread for minutes")
    }

    // MARK: - HTML sanitizing

    private func sanitized(_ html: String) -> String {
        String(decoding: ClipboardTextPinRenderer.sanitizedHTML(Data(html.utf8)), as: UTF8.self)
    }

    func testRemoteImagesAreStrippedFromPastedHTML() {
        // This is the tracking-pixel case: pinning an HTML email or a web
        // selection must not tell the sender the user opened it.
        let result = sanitized(#"<p>Hello</p><img src="https://tracker.example.com/pixel.gif">"#)
        XCTAssertFalse(result.lowercased().contains("<img"), "got: \(result)")
        XCTAssertFalse(result.contains("tracker.example.com"))
        XCTAssertTrue(result.contains("Hello"), "the text itself must survive")
    }

    func testRemoteStylesheetsAndScriptsAreStripped() {
        let result = sanitized("""
        <link rel="stylesheet" href="https://cdn.example.com/a.css">
        <script src="https://cdn.example.com/a.js"></script>
        <style>@import url(https://cdn.example.com/b.css);</style>
        <p>Body text</p>
        """)
        XCTAssertFalse(result.lowercased().contains("<link"))
        XCTAssertFalse(result.lowercased().contains("<script"))
        XCTAssertFalse(result.lowercased().contains("<style"))
        XCTAssertTrue(result.contains("Body text"))
    }

    func testRemoteBackgroundsInInlineStylesAreNeutralized() {
        let result = sanitized(#"<div style="background: url('https://example.com/bg.png')">text</div>"#)
        XCTAssertFalse(result.contains("https://example.com/bg.png"), "got: \(result)")
        XCTAssertTrue(result.contains("text"))
    }

    func testIframesAndMediaElementsAreStripped() {
        let result = sanitized("""
        <iframe src="https://example.com/frame"></iframe>
        <video src="https://example.com/v.mp4"></video>
        <p>kept</p>
        """)
        XCTAssertFalse(result.lowercased().contains("<iframe"))
        XCTAssertFalse(result.lowercased().contains("<video"))
        XCTAssertTrue(result.contains("kept"))
    }

    func testFormattingMarkupIsPreserved() {
        let result = sanitized("<p><b>bold</b> and <i>italic</i> and <span style=\"color:red\">red</span></p>")
        XCTAssertTrue(result.contains("<b>bold</b>"))
        XCTAssertTrue(result.contains("<i>italic</i>"))
        XCTAssertTrue(result.contains("color:red"), "styling that doesn't load anything stays")
    }

    func testSanitizedHTMLStillImports() throws {
        let data = Data("<p>Hello <b>world</b></p>".utf8)
        let attributed = try XCTUnwrap(ClipboardTextPinRenderer.attributedString(html: data))
        XCTAssertTrue(attributed.string.contains("Hello world"))
    }

    func testNonUTF8AndEmptyHTMLAreHandled() {
        XCTAssertNoThrow(ClipboardTextPinRenderer.sanitizedHTML(Data()))
        XCTAssertNoThrow(ClipboardTextPinRenderer.sanitizedHTML(Data([0xFF, 0xFE, 0x00, 0x01])))
    }

    func testGeneratedHTMLPreservesTextAndFormattingWithoutSourceAttributes() throws {
        let original = """
        <section class="article"><p title="a title">A &amp; B <a href="https://example.com/guide">guide</a></p>
        <p><span style="color:rgb(20,30,40);font-weight:bold;font-size:18px;background-image:none">styled</span></p>
        <ul><li>First</li><li>Second</li></ul><table><tr><td colspan="2">Cell</td></tr></table></section>
        """
        let safe = sanitized(original)
        XCTAssertFalse(safe.contains("href="))
        XCTAssertFalse(safe.contains("class="))
        XCTAssertFalse(safe.contains("title="))
        XCTAssertFalse(safe.contains("background-image"))
        XCTAssertTrue(safe.contains("<ul>"))
        XCTAssertTrue(safe.contains("<table>"))
        XCTAssertTrue(safe.contains("colspan=\"2\""))
        XCTAssertTrue(safe.contains("font-weight:bold"))
        let attributed = try XCTUnwrap(ClipboardTextPinRenderer.attributedString(html: Data(original.utf8)))
        XCTAssertTrue(attributed.string.contains("A & B guide"))
        XCTAssertTrue(attributed.string.contains("First"))
        XCTAssertTrue(attributed.string.contains("Cell"))
        let range = (attributed.string as NSString).range(of: "styled")
        XCTAssertNotEqual(range.location, NSNotFound)
        let font = try XCTUnwrap(attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    func testRichInputIsLimitedBeforeImportAndHTMLTextBeforeLayout() throws {
        let excessive = Data(repeating: 65, count: ClipboardHTML.maximumInputBytes + 1)
        XCTAssertNil(ClipboardTextPinRenderer.attributedString(html: excessive))
        XCTAssertNil(ClipboardTextPinRenderer.attributedString(rtf: excessive))
        XCTAssertNil(ClipboardTextPinRenderer.attributedString(rtfd: excessive))
        let html = Data(("<p>" + String(repeating: "text ", count: 10_000) + "</p>").utf8)
        let result = try XCTUnwrap(ClipboardTextPinRenderer.attributedString(html: html))
        XCTAssertLessThanOrEqual(result.length, ClipboardTextPinRenderer.maxCharacters + 2)
        XCTAssertTrue(result.string.contains("…"))
    }

    func testRichTextTruncationDoesNotSplitAnEmojiSequence() {
        let prefix = String(repeating: "a", count: ClipboardTextPinRenderer.maxCharacters - 1)
        let result = ClipboardTextPinRenderer.truncatedForPinning(NSAttributedString(string: prefix + "🧑🏽‍💻tail"))
        XCTAssertEqual(result.string, prefix + "\n…")
    }

    func testOversizedHTMLFlavorFallsBackToPlainTextInThePasteboardItem() {
        let item = NSPasteboardItem()
        item.setData(Data(repeating: 65, count: ClipboardHTML.maximumInputBytes + 1), forType: .html)
        item.setString("A normal plain-text fallback", forType: .string)
        if case .image(let image) = ClipboardPinService.image(from: item) {
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
        } else { XCTFail("Plain clipboard text must remain pinnable") }
    }
}

/// Share and drag files land in a scratch folder. Two shares of the same
/// capture name used to overwrite each other, swapping the attachment under an
/// already-open Mail draft.
final class TmpScratchDirectoryTests: XCTestCase {

    func testTwoSharesWithTheSameNameGetDistinctPaths() {
        let first = TmpScratchDirectory.makeURL(filename: "Screenshot 2026-09-19.png")
        let second = TmpScratchDirectory.makeURL(filename: "Screenshot 2026-09-19.png")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, second.lastPathComponent,
                       "the receiving app should still see the configured filename")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
    }

    func testTheContainingFolderExistsSoTheWriteSucceeds() throws {
        let url = TmpScratchDirectory.makeURL(filename: "note.txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try Data("hello".utf8).write(to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
    }

    func testAnEmptyFilenameStillProducesAUsablePath() {
        let url = TmpScratchDirectory.makeURL(filename: "")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertFalse(url.lastPathComponent.isEmpty)
    }

    func testScratchFoldersAreInsideTheScratchDirectory() {
        let url = TmpScratchDirectory.makeURL(filename: "x.png")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(url.path.hasPrefix(TmpScratchDirectory.url.path),
                      "a scratch file outside the swept folder would never be cleaned up")
    }
}

/// The launch sweep has to reach those per-share folders, or they pile up.
final class ScratchFolderSweepTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-sweepdir-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeFolder(_ name: String, ageInHours: Double, fileBytes: Int = 32) throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: fileBytes).write(to: folder.appendingPathComponent("file.png"))
        if ageInHours > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageInHours * 3600)],
                ofItemAtPath: folder.path)
        }
        return folder
    }

    func testStaleFoldersAreRemoved() throws {
        let old = try makeFolder("old", ageInHours: 2)
        let result = DirectorySweeper.sweepDirectories(in: directory, olderThan: 300)
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertGreaterThan(result.bytesFreed, 0)
    }

    func testAFolderStillInUseIsLeftAlone() throws {
        let fresh = try makeFolder("fresh", ageInHours: 0)
        let result = DirectorySweeper.sweepDirectories(in: directory, olderThan: 300)
        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "a share the user just started must not be deleted from under it")
    }

    func testLooseFilesAreNotTouchedByTheDirectorySweep() throws {
        let file = directory.appendingPathComponent("loose.png")
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: file.path)

        let result = DirectorySweeper.sweepDirectories(in: directory, olderThan: 300)
        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAMissingDirectoryIsNotAnError() {
        let result = DirectorySweeper.sweepDirectories(
            in: directory.appendingPathComponent("nope"), olderThan: 60)
        XCTAssertEqual(result.removed, 0)
    }
}
