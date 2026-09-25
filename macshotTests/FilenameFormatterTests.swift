import XCTest

/// Filenames come from a user-editable template and go straight to disk, so a
/// bad render means a failed save, an overwritten capture, or a name macOS
/// quietly mangles.
final class FilenameFormatterTests: XCTestCase {

    /// 2026-03-14 09:26:53 UTC, formatted in whatever zone the machine runs in.
    private let fixedDate = Date(timeIntervalSince1970: 1_773_480_413)

    private func expectedDate(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: fixedDate)
    }

    // MARK: - Tokens

    func testDefaultTemplateRendersDateAndTime() {
        let name = FilenameFormatter.format(template: FilenameFormatter.defaultTemplate, date: fixedDate)
        XCTAssertEqual(name, "Screenshot \(expectedDate("yyyy-MM-dd")) at \(expectedDate("HH-mm-ss"))")
    }

    func testEachTokenExpands() {
        let cases: [(String, String)] = [
            ("{date}", expectedDate("yyyy-MM-dd")),
            ("{time}", expectedDate("HH-mm-ss")),
            ("{timestamp}", "\(expectedDate("yyyy-MM-dd"))_\(expectedDate("HH-mm-ss"))"),
            ("{unix}", String(Int(fixedDate.timeIntervalSince1970))),
        ]
        for (template, expected) in cases {
            XCTAssertEqual(FilenameFormatter.format(template: template, date: fixedDate), expected,
                           "token \(template) rendered wrong")
        }
    }

    func testWindowAndIndexTokens() {
        XCTAssertEqual(
            FilenameFormatter.format(template: "{window}-{index}", windowTitle: "Safari", index: 3, date: fixedDate),
            "Safari-3")
    }

    func testInsertedWindowTitlesAreLiteralNotMoreTemplateTokens() {
        XCTAssertEqual(FilenameFormatter.format(template: "Capture {window}-{index}",
            windowTitle: "{date} {random} {index}", index: 7, date: fixedDate), "Capture {date} {random} {index}-7")
    }

    func testUnicodeClustersAndTrailingDotsSurviveLengthCappingCleanly() {
        let family = "👩‍👩‍👦"
        let name = FilenameFormatter.format(template: "abc" + String(repeating: family, count: 40), date: fixedDate)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertEqual(name, "abc" + String(repeating: family, count: 10))
        XCTAssertEqual(FilenameFormatter.format(template: String(repeating: "a", count: 199) + ".tail", date: fixedDate),
                       String(repeating: "a", count: 199))
    }

    func testMissingWindowAndIndexRenderEmptyRatherThanPlaceholders() {
        XCTAssertEqual(
            FilenameFormatter.format(template: "shot{window}{index}", date: fixedDate),
            "shot")
    }

    func testRandomTokenIsEightLowercaseBase36Characters() {
        let name = FilenameFormatter.format(template: "{random}", date: fixedDate)
        XCTAssertEqual(name.count, 8)
        XCTAssertTrue(name.allSatisfy { $0.isNumber || ($0.isLetter && $0.isLowercase) }, "got \(name)")
    }

    func testEachRandomTokenGetsItsOwnValue() {
        let name = FilenameFormatter.format(template: "{random}-{random}", date: fixedDate)
        let parts = name.split(separator: "-")
        XCTAssertEqual(parts.count, 2)
        XCTAssertNotEqual(parts[0], parts[1], "two {random} tokens produced the same value")
    }

    func testRandomTokensDifferBetweenCaptures() {
        let names = Set((0..<20).map { _ in FilenameFormatter.format(template: "{random}", date: fixedDate) })
        XCTAssertGreaterThan(names.count, 15, "{random} must not repeat across captures")
    }

    func testUnknownTokensAreLeftVisible() {
        XCTAssertEqual(
            FilenameFormatter.format(template: "shot-{notAToken}", date: fixedDate),
            "shot-{notAToken}",
            "a typo should be visible in the filename, not silently swallowed")
        XCTAssertEqual(FilenameFormatter.format(template: "Capture {unfinished", date: fixedDate), "Capture {unfinished")
    }

    func testTokensAreCaseSensitive() {
        XCTAssertEqual(FilenameFormatter.format(template: "{DATE}", date: fixedDate), "{DATE}")
    }

    // MARK: - Sanitizing

    func testPathSeparatorsCannotEscapeTheSaveDirectory() {
        let name = FilenameFormatter.format(template: "../../etc/passwd", date: fixedDate)
        XCTAssertFalse(name.contains("/"), "a slash in the template would write outside the save directory: \(name)")
        XCTAssertEqual(name, "..-..-etc-passwd")
    }

    func testWindowTitleWithSlashesIsNeutralized() {
        let name = FilenameFormatter.format(template: "{window}", windowTitle: "docs/README: draft", date: fixedDate)
        XCTAssertEqual(name, "docs-README- draft")
    }

    func testColonsAreReplacedBecauseFinderShowsThemAsSlashes() {
        XCTAssertEqual(FilenameFormatter.format(template: "a:b", date: fixedDate), "a-b")
    }

    func testControlCharactersAreStripped() {
        let name = FilenameFormatter.format(template: "shot\u{7}\u{1}name", date: fixedDate)
        XCTAssertEqual(name, "shotname")
    }

    func testNullBytesAreNeutralized() {
        let name = FilenameFormatter.format(template: "shot\0name", date: fixedDate)
        XCTAssertFalse(name.contains("\0"))
    }

    func testTrailingDotsAreTrimmed() {
        XCTAssertEqual(FilenameFormatter.format(template: "screenshot...", date: fixedDate), "screenshot",
                       "macOS hides trailing dots, so they'd produce a confusing filename")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(FilenameFormatter.format(template: "   shot   ", date: fixedDate), "shot")
    }

    func testNewlinesInAWindowTitleAreStripped() {
        let name = FilenameFormatter.format(template: "{window}", windowTitle: "line1\nline2", date: fixedDate)
        XCTAssertFalse(name.contains("\n"))
    }

    // MARK: - Length

    func testLongNamesAreCappedToAWritableLength() {
        let name = FilenameFormatter.format(template: String(repeating: "a", count: 500), date: fixedDate)
        XCTAssertLessThanOrEqual(name.utf8.count, 200, "macOS rejects filenames longer than 255 bytes")
    }

    func testCappingDoesNotSplitAMultiByteCharacter() {
        // 150 emoji = 600 UTF-8 bytes; the cut has to land on a boundary.
        let name = FilenameFormatter.format(template: String(repeating: "😀", count: 150), date: fixedDate)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertFalse(name.isEmpty)
        XCTAssertEqual(name, String(name.unicodeScalars.map(Character.init)), "result must still be valid text")
        XCTAssertTrue(name.allSatisfy { $0 == "😀" }, "a truncated scalar would show as a replacement character")
    }

    func testAVeryLongWindowTitleStillLeavesAUsableName() {
        let name = FilenameFormatter.format(
            template: "{window}", windowTitle: String(repeating: "Document ", count: 100), date: fixedDate)
        XCTAssertFalse(name.isEmpty)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
    }

    // MARK: - Fallbacks

    func testEmptyTemplateFallsBackToTheDefault() {
        XCTAssertEqual(
            FilenameFormatter.format(template: "", date: fixedDate),
            FilenameFormatter.format(template: FilenameFormatter.defaultTemplate, date: fixedDate))
    }

    func testWhitespaceOnlyTemplateFallsBackToTheDefault() {
        XCTAssertEqual(
            FilenameFormatter.format(template: "   \n ", date: fixedDate),
            FilenameFormatter.format(template: FilenameFormatter.defaultTemplate, date: fixedDate))
    }

    func testTemplateThatSanitizesToNothingFallsBack() {
        // Only control characters: renders to an empty string.
        let name = FilenameFormatter.format(template: "\u{1}\u{2}", date: fixedDate)
        XCTAssertFalse(name.isEmpty, "an empty filename can't be saved")
        XCTAssertTrue(name.hasPrefix("Screenshot"), "expected the default template, got \(name)")
    }

    func testAFallbackThatAlsoRendersEmptyEndsAtUntitled() {
        let name = FilenameFormatter.format(template: "\u{1}", date: fixedDate, fallback: "\u{2}")
        XCTAssertEqual(name, "Untitled", "there must always be some name to save under")
    }

    func testRecordingTemplateDefaultIsDistinct() {
        XCTAssertNotEqual(FilenameFormatter.defaultRecordingTemplate, FilenameFormatter.defaultTemplate)
        XCTAssertTrue(FilenameFormatter.format(
            template: FilenameFormatter.defaultRecordingTemplate, date: fixedDate).hasPrefix("Recording"))
    }

    // MARK: - Defaults-driven convenience

    func testDefaultImageFilenameUsesTheSavedTemplateAndExtension() {
        withDefaults([FilenameFormatter.userDefaultsKey: "capture-{index}", "imageFormat": "jpeg"]) {
            XCTAssertEqual(FilenameFormatter.defaultImageFilename(index: 7), "capture-7.jpg")
        }
    }

    func testDefaultImageFilenameWithoutASavedTemplate() {
        withDefaults([FilenameFormatter.userDefaultsKey: nil, "imageFormat": "png"]) {
            XCTAssertTrue(FilenameFormatter.defaultImageFilename().hasPrefix("Screenshot "))
            XCTAssertTrue(FilenameFormatter.defaultImageFilename().hasSuffix(".png"))
        }
    }

    // MARK: - Determinism

    func testTheSameInputsRenderTheSameName() {
        let first = FilenameFormatter.format(template: "{timestamp}-{window}", windowTitle: "App", date: fixedDate)
        let second = FilenameFormatter.format(template: "{timestamp}-{window}", windowTitle: "App", date: fixedDate)
        XCTAssertEqual(first, second)
    }

    func testTimeFormatUsesDashesSoTheNameStaysValid() {
        let name = FilenameFormatter.format(template: "{time}", date: fixedDate)
        XCTAssertFalse(name.contains(":"), "HH:mm:ss would be mangled by the filesystem")
        XCTAssertEqual(name.filter { $0 == "-" }.count, 2)
    }
    // MARK: - App token, date parts, subfolders

    func testAppAndDatePartTokens() {
        let millis = Date(timeIntervalSince1970: 1_773_480_413.042)
        XCTAssertEqual(
            FilenameFormatter.format(template: "{app}-{HH}.{mm}.{ss}.{ms}", appName: "Safari", date: millis),
            "Safari-\(expectedDate("HH")).\(expectedDate("mm")).\(expectedDate("ss")).042")
        XCTAssertEqual(FilenameFormatter.format(template: "{yyyy}{MM}{dd}", date: fixedDate),
                       expectedDate("yyyyMMdd"))
    }

    func testSlashesBecomeSubfolders() {
        let path = FilenameFormatter.formatRelativePath(
            template: "{yyyy}/{MM}/{dd}/{app}-{HH}.{mm}.{ss}", appName: "Safari", date: fixedDate)
        XCTAssertEqual(path, [expectedDate("yyyy"), expectedDate("MM"), expectedDate("dd"),
                              "Safari-\(expectedDate("HH.mm.ss"))"])
    }

    func testNoAppTemplateIsUsedOnlyWhenAppIsUnknown() {
        let template = "{yyyy}/{app}-{HH}"
        let noApp = "{yyyy}/{HH}.{ms}"
        XCTAssertEqual(FilenameFormatter.formatRelativePath(template: template, noAppTemplate: noApp,
                                                            appName: "Xcode", date: fixedDate),
                       [expectedDate("yyyy"), "Xcode-\(expectedDate("HH"))"])
        XCTAssertEqual(FilenameFormatter.formatRelativePath(template: template, noAppTemplate: noApp,
                                                            appName: "  ", date: fixedDate),
                       [expectedDate("yyyy"), "\(expectedDate("HH")).000"])
        // Without a no-app template the main one still renders.
        XCTAssertEqual(FilenameFormatter.formatRelativePath(template: template, appName: nil, date: fixedDate).count, 2)
    }

    func testRelativePathCannotEscapeTheSaveFolder() {
        let path = FilenameFormatter.formatRelativePath(template: "../../{app}/./x//{window}",
                                                        windowTitle: "a/b", appName: "..", date: fixedDate)
        XCTAssertFalse(path.contains(".."))
        XCTAssertFalse(path.contains("."))
        XCTAssertFalse(path.contains(""))
        XCTAssertEqual(path.last, "a-b", "slashes inside a token value never create folders")
    }

    func testEmptyRelativePathFallsBack() {
        XCTAssertEqual(FilenameFormatter.formatRelativePath(template: "{app}/{window}", date: fixedDate),
                       [FilenameFormatter.format(template: FilenameFormatter.defaultTemplate, date: fixedDate)])
    }
}
