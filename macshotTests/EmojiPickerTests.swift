import AppKit
import CoreText
import XCTest

/// The stamp tool's emoji picker offers every emoji the Mac can draw, not
/// only the curated set (#473: 🥹 couldn't be found).
@MainActor
final class EmojiPickerTests: XCTestCase {

    private let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)

    func testCatalogHoldsEmojiBeyondTheCuratedSet() {
        let all = Set(EmojiCatalog.all.map(\.emoji))
        XCTAssertGreaterThan(all.count, 1000)
        XCTAssertTrue(all.contains("🥹"), "the emoji from #473")
        XCTAssertTrue(all.contains("😀"))
        XCTAssertTrue(all.contains("❤️"), "text-style symbols get the emoji variation selector")
        XCTAssertTrue(all.contains("🇮🇹"), "flags")
        // Every curated emoji that is a single code point is in the catalog too.
        let curated = StampEmojis.categories.flatMap(\.1).filter { $0.unicodeScalars.count == 1 }
        XCTAssertEqual(curated.filter { !all.contains($0) && !all.contains($0 + "\u{FE0F}") }, [])
    }

    func testCatalogHasNoFragmentsOrDuplicates() {
        let entries = EmojiCatalog.all
        XCTAssertEqual(Set(entries.map(\.emoji)).count, entries.count, "duplicates")
        for entry in entries {
            let scalars = entry.emoji.unicodeScalars
            XCTAssertFalse(scalars.count == 1 && scalars.first!.properties.isEmojiModifier, "lone skin tone \(entry.emoji)")
            XCTAssertFalse(scalars.count == 1 && (0x1F1E6...0x1F1FF).contains(scalars.first!.value), "lone regional indicator")
            XCTAssertTrue(EmojiCatalog.canDraw(entry.emoji, font: font), "\(entry.name) can't be drawn")
            XCTAssertFalse(entry.name.isEmpty, "\(entry.emoji) has no name to search by")
        }
    }

    func testSearchMatchesEveryWordOfTheName() {
        XCTAssertTrue(EmojiCatalog.search("tears").map(\.emoji).contains("🥹"))
        XCTAssertTrue(EmojiCatalog.search("holding back tears").map(\.emoji).contains("🥹"))
        XCTAssertTrue(EmojiCatalog.search("FLAG italy").map(\.emoji).contains("🇮🇹"))
        XCTAssertTrue(EmojiCatalog.search("🥹").map(\.emoji).contains("🥹"), "a pasted emoji finds itself")
        XCTAssertEqual(EmojiCatalog.search("   ").count, EmojiCatalog.all.count)
        XCTAssertEqual(EmojiCatalog.search("zzqqxx"), [])
    }

    /// Glyph coverage, not the Unicode version, decides: a scalar the font
    /// lacks is left out.
    func testCanDrawReflectsTheFont() {
        XCTAssertTrue(EmojiCatalog.canDraw("😀", font: font))
        XCTAssertFalse(EmojiCatalog.canDraw("\u{E000}", font: font), "private use")
        XCTAssertFalse(EmojiCatalog.canDraw("", font: font))
    }

    // MARK: - Picker

    func testPickerStartsOnTheCuratedTabAndSearchesTheFullCatalog() {
        let picker = EmojiPickerView()
        XCTAssertEqual(picker.shownEmoji, StampEmojis.categories[0].1)
        let startSize = picker.preferredSize

        picker.applySearch("tears")
        XCTAssertTrue(picker.shownEmoji.contains("🥹"))
        XCTAssertLessThan(picker.shownEmoji.count, 50)

        picker.applySearch("")
        XCTAssertEqual(picker.shownEmoji, StampEmojis.categories[0].1, "clearing returns to the tab")
        XCTAssertEqual(picker.preferredSize, startSize)
    }

    func testChoosingAnEmojiFromTheGridReportsIt() throws {
        let picker = EmojiPickerView()
        var chosen: String?
        picker.onSelectEmoji = { chosen = $0 }
        picker.applySearch("holding back tears")
        let grid = try XCTUnwrap(picker.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? EmojiGridView }.first)
        let index = try XCTUnwrap(grid.emojis.firstIndex(of: "🥹"))
        let point = NSPoint(x: grid.cellRect(index).midX, y: grid.cellRect(index).midY)
        XCTAssertEqual(grid.index(at: point), index)
        grid.onSelect?(grid.emojis[index])
        XCTAssertEqual(chosen, "🥹")
    }

    /// The grid draws only the rows in view; a cell index maps back to itself.
    func testGridCellsRoundTrip() {
        let grid = EmojiGridView()
        grid.emojis = Array(EmojiCatalog.all.prefix(100).map(\.emoji))
        for index in [0, 7, 8, 63, 99] {
            let rect = grid.cellRect(index)
            XCTAssertEqual(grid.index(at: NSPoint(x: rect.midX, y: rect.midY)), index)
        }
        XCTAssertNil(grid.index(at: NSPoint(x: -1, y: 5)))
        XCTAssertNil(grid.index(at: NSPoint(x: 5, y: 32 * 13 + 1)), "past the last emoji")
    }
}
