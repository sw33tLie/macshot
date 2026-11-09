import Cocoa
import XCTest

/// Stamps are rendered from emoji into images that get baked into a capture.
@MainActor
final class StampEmojiTests: XCTestCase {

    func testEveryCategoryHasANameAndContent() {
        XCTAssertFalse(StampEmojis.categories.isEmpty)
        for (name, emoji) in StampEmojis.categories {
            XCTAssertFalse(name.isEmpty, "a category tab with no name")
            XCTAssertFalse(emoji.isEmpty, "category \(name) has no emoji")
        }
    }

    func testNoEmojiIsListedTwiceInTheSameCategory() {
        for (name, emoji) in StampEmojis.categories {
            XCTAssertEqual(Set(emoji).count, emoji.count, "category \(name) repeats an emoji")
        }
    }

    func testTheCommonListIsAvailableInTheCategories() {
        let all = Set(StampEmojis.categories.flatMap { $0.1 })
        for emoji in StampEmojis.common {
            XCTAssertTrue(all.contains(emoji), "\(emoji) is offered as a default but isn't in any category")
        }
    }

    func testRenderingProducesAVisibleImage() throws {
        let image = StampEmojis.renderEmoji("🎉", size: 64)
        XCTAssertEqual(image.size, NSSize(width: 64, height: 64))

        let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: image))
        var opaquePixels = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { opaquePixels += 1 }
            }
        }
        XCTAssertGreaterThan(opaquePixels, 10, "the stamp rendered blank")
    }

    func testEveryOfferedEmojiRenders() {
        // A stamp that renders blank would paste an invisible annotation.
        for (category, emoji) in StampEmojis.categories {
            for character in emoji {
                let image = StampEmojis.renderEmoji(character, size: 24)
                XCTAssertGreaterThan(image.size.width, 0, "\(character) in \(category) rendered no image")
            }
        }
    }

    func testOddInputDoesNotCrashTheRenderer() {
        for text in ["", " ", "not an emoji", "👨‍👩‍👧‍👦", "🇯🇵"] {
            _ = StampEmojis.renderEmoji(text, size: 32)
        }
    }

    func testSizeIsRespected() {
        for size in [8, 32, 256] as [CGFloat] {
            XCTAssertEqual(StampEmojis.renderEmoji("⭐️", size: size).size, NSSize(width: size, height: size))
        }
    }
}
