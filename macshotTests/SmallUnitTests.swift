import Cocoa
import XCTest

/// Number badges: the label a user sees on each numbered annotation.
final class NumberFormatTests: XCTestCase {

    func testDecimalIsJustTheNumber() {
        XCTAssertEqual(NumberFormat.decimal.format(1), "1")
        XCTAssertEqual(NumberFormat.decimal.format(42), "42")
    }

    func testRomanNumerals() {
        let expected: [Int: String] = [
            1: "I", 4: "IV", 9: "IX", 14: "XIV", 40: "XL", 90: "XC",
            400: "CD", 900: "CM", 1987: "MCMLXXXVII", 3999: "MMMCMXCIX",
        ]
        for (value, numeral) in expected {
            XCTAssertEqual(NumberFormat.roman.format(value), numeral, "roman \(value)")
        }
    }

    func testRomanClampsOutOfRangeValues() {
        // There is no Roman numeral for zero or for 4000+, so the badge falls
        // back to the nearest representable value instead of rendering blank.
        XCTAssertEqual(NumberFormat.roman.format(0), "I")
        XCTAssertEqual(NumberFormat.roman.format(-5), "I")
        XCTAssertEqual(NumberFormat.roman.format(4000), "MMMCMXCIX")
        XCTAssertEqual(NumberFormat.roman.format(99999), "MMMCMXCIX")
    }

    func testAlphabeticBadges() {
        XCTAssertEqual(NumberFormat.alpha.format(1), "A")
        XCTAssertEqual(NumberFormat.alpha.format(26), "Z")
        XCTAssertEqual(NumberFormat.alphaLower.format(1), "a")
        XCTAssertEqual(NumberFormat.alphaLower.format(26), "z")
    }

    func testAlphabeticBadgesWrapAfterZ() {
        XCTAssertEqual(NumberFormat.alpha.format(27), "A", "the 27th badge wraps rather than breaking")
        XCTAssertEqual(NumberFormat.alpha.format(52), "Z")
    }

    func testAlphabeticBadgesHandleZeroAndNegatives() {
        XCTAssertEqual(NumberFormat.alpha.format(0), "A")
        XCTAssertEqual(NumberFormat.alpha.format(-3), "A")
    }

    func testEveryFormatProducesSomethingForEveryBadge() {
        for format in NumberFormat.allCases {
            for number in [-10, 0, 1, 26, 27, 100, 3999, 4000, 10_000] {
                XCTAssertFalse(format.format(number).isEmpty, "\(format) rendered \(number) as an empty badge")
            }
        }
    }
}

/// Dashed and dotted strokes are fitted to the path length so the pattern ends
/// cleanly instead of being cut off mid-dash.
final class LineStyleTests: XCTestCase {

    private func path(lineWidth: CGFloat = 4) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: .zero)
        path.line(to: NSPoint(x: 100, y: 0))
        path.lineWidth = lineWidth
        return path
    }

    func testSolidLeavesThePathAlone() {
        let solid = path()
        LineStyle.solid.apply(to: solid)
        XCTAssertEqual(solid.lineWidth, 4)
    }

    func testDottedUsesRoundCapsSoDotsAreCircles() {
        let dotted = path()
        LineStyle.dotted.apply(to: dotted)
        XCTAssertEqual(dotted.lineCapStyle, .round)
    }

    func testFittingToALengthDoesNotCrashOnDegenerateInput() {
        for length in [0, -10, 0.0001, 1_000_000] as [CGFloat] {
            for style in LineStyle.allCases {
                let p = path()
                style.applyFitted(to: p, pathLength: length)
            }
        }
    }

    func testFittingAZeroWidthPath() {
        for style in LineStyle.allCases {
            let p = path(lineWidth: 0)
            style.applyFitted(to: p, pathLength: 100)
        }
    }

    func testEveryStyleIsDistinct() {
        XCTAssertEqual(Set(LineStyle.allCases.map(\.rawValue)).count, LineStyle.allCases.count)
    }
}

/// The launch sweeper deletes files from shared directories. Deleting one file
/// too many means losing a user's capture, so its two guards — the filename
/// predicate and the age gate — are worth pinning down.
final class DirectorySweeperTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-sweeper-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeFile(_ name: String, ageInHours: Double = 0, bytes: Int = 16) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if ageInHours > 0 {
            let modified = Date().addingTimeInterval(-ageInHours * 3600)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    func testOnlyMatchingFilesAreDeleted() throws {
        try makeFile("scratch-1.png")
        try makeFile("keep-me.png")

        let result = DirectorySweeper.sweep(directory: directory, olderThan: nil) { $0.hasPrefix("scratch-") }
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(exists("scratch-1.png"))
        XCTAssertTrue(exists("keep-me.png"), "a file the predicate rejected must survive")
    }

    func testRecentFilesAreLeftAloneWhenAnAgeGateIsSet() throws {
        try makeFile("old.tmp", ageInHours: 48)
        try makeFile("fresh.tmp")

        let result = DirectorySweeper.sweep(directory: directory, olderThan: 3600) { $0.hasSuffix(".tmp") }
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(exists("old.tmp"))
        XCTAssertTrue(exists("fresh.tmp"), "a file being written right now must not be deleted underneath it")
    }

    func testFreedBytesAreReported() throws {
        try makeFile("a.tmp", ageInHours: 5, bytes: 100)
        try makeFile("b.tmp", ageInHours: 5, bytes: 250)

        let result = DirectorySweeper.sweep(directory: directory, olderThan: 60) { $0.hasSuffix(".tmp") }
        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(result.bytesFreed, 350)
    }

    func testSubdirectoriesAreNeverDeleted() throws {
        let subdirectory = directory.appendingPathComponent("nested.tmp")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

        let result = DirectorySweeper.sweep(directory: directory, olderThan: nil) { _ in true }
        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: subdirectory.path),
                      "a directory must not be swept away by a filename rule")
    }

    func testAMissingDirectoryIsNotAnError() {
        let missing = directory.appendingPathComponent("does-not-exist")
        let result = DirectorySweeper.sweep(directory: missing, olderThan: nil) { _ in true }
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.bytesFreed, 0)
    }

    func testAPredicateThatMatchesNothingDeletesNothing() throws {
        try makeFile("one.png")
        try makeFile("two.png")
        let result = DirectorySweeper.sweep(directory: directory, olderThan: nil) { _ in false }
        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(exists("one.png") && exists("two.png"))
    }
}

/// Text pinned from the clipboard is rendered to an image; these are the parts
/// that decide what that image contains.
final class ClipboardTextPinRendererTests: XCTestCase {

    func testPlainTextKeepsItsContent() {
        let attributed = ClipboardTextPinRenderer.plainAttributedString("hello\nworld")
        XCTAssertEqual(attributed.string, "hello\nworld")
        XCTAssertGreaterThan(attributed.length, 0)
    }

    func testPlainTextIsStyledForALightBackground() {
        let attributed = ClipboardTextPinRenderer.plainAttributedString("x")
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .black, "the pin renders on white, so the text has to be dark")
        XCTAssertNotNil(attributed.attribute(.font, at: 0, effectiveRange: nil))
    }

    func testEmptyTextIsHandled() {
        XCTAssertEqual(ClipboardTextPinRenderer.plainAttributedString("").string, "")
    }

    func testAttachmentsAreDetected() {
        let withImage = NSMutableAttributedString(string: "before ")
        let attachment = NSTextAttachment()
        attachment.image = ImageProbe.solidImage(width: 4, height: 4)
        withImage.append(NSAttributedString(attachment: attachment))
        XCTAssertTrue(ClipboardTextPinRenderer.containsAttachments(withImage))
    }

    func testPlainTextHasNoAttachments() {
        XCTAssertFalse(ClipboardTextPinRenderer.containsAttachments(NSAttributedString(string: "just text")))
        XCTAssertFalse(ClipboardTextPinRenderer.containsAttachments(NSAttributedString(string: "")))
    }

    func testRenderingProducesAnImageForOrdinaryText() {
        let image = ClipboardTextPinRenderer.render(ClipboardTextPinRenderer.plainAttributedString("Pinned note"))
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
        XCTAssertGreaterThan(image?.size.height ?? 0, 0)
    }

    func testRenderingHandlesAwkwardText() {
        for text in ["", "   ", "\n\n\n", String(repeating: "word ", count: 2_000), "🎉", "العربية"] {
            _ = ClipboardTextPinRenderer.render(ClipboardTextPinRenderer.plainAttributedString(text))
        }
    }
}

/// Build-variant flags decide whether upload UI exists at all.
final class BuildVariantTests: XCTestCase {

    func testTheVariantIsSelfConsistent() {
        XCTAssertFalse(BuildVariant.displayName.isEmpty)
        if BuildVariant.isOffline {
            XCTAssertTrue(BuildVariant.displayName.lowercased().contains("offline"),
                          "the offline build should say so in its name")
        } else {
            XCTAssertFalse(BuildVariant.displayName.lowercased().contains("offline"))
        }
    }

    func testUploadSettingsOnlyExistInTheOnlineBuild() {
        #if OFFLINE
        XCTAssertTrue(BuildVariant.isOffline)
        #else
        XCTAssertFalse(BuildVariant.isOffline)
        #endif
    }
}
