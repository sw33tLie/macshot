import Cocoa
import XCTest

/// The preset swatches are a user setting with no fixed length, so they must
/// round-trip exactly, fall back to the shipped palette when unset, and never
/// lose colors when one entry is corrupt.
final class PresetColorPaletteTests: XCTestCase {

    private func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "nil" }
        return String(format: "%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    private func withEmptyPalette(_ body: () -> Void) {
        try? withDefaults([PresetColorPalette.defaultsKey: nil]) { body() }
    }

    func testUnsetPaletteUsesTheShippedColors() {
        withEmptyPalette {
            XCTAssertEqual(PresetColorPalette.colors.count, PresetColorPalette.defaultColors.count)
            XCTAssertEqual(hex(PresetColorPalette.colors[0]), hex(.systemRed))
        }
    }

    func testColorsReadBackExactly() {
        withEmptyPalette {
            PresetColorPalette.save([
                NSColor(srgbRed: 1, green: 0.4, blue: 0.2, alpha: 1),
                .systemTeal,
            ])
            let restored = PresetColorPalette.colors
            XCTAssertEqual(restored.count, 2)
            XCTAssertEqual(hex(restored[0]), "FF6633")
            XCTAssertEqual(hex(restored[1]), hex(.systemTeal))
        }
    }

    func testTheListCanGrowAndShrink() {
        withEmptyPalette {
            let expanded = PresetColorPalette.defaultColors + (0..<8).map {
                NSColor(srgbRed: CGFloat($0) / 8, green: 0.5, blue: 0.5, alpha: 1)
            }
            PresetColorPalette.save(expanded)
            XCTAssertEqual(PresetColorPalette.colors.count, expanded.count)

            PresetColorPalette.save(Array(PresetColorPalette.defaultColors.prefix(3)))
            XCTAssertEqual(PresetColorPalette.colors.count, 3)
        }
    }

    func testAnEmptyListStaysEmpty() {
        withEmptyPalette {
            PresetColorPalette.save([])
            XCTAssertTrue(PresetColorPalette.colors.isEmpty,
                          "a user who removed every swatch gets none back")
        }
    }

    func testAnEmptyListIsNotConfusedWithAnUnsetOne() {
        withEmptyPalette {
            PresetColorPalette.save([])
            XCTAssertTrue(PresetColorPalette.colors.isEmpty, "an explicit empty list survives")

            PresetColorPalette.reset()
            XCTAssertEqual(PresetColorPalette.colors, PresetColorPalette.defaultColors,
                           "reset restores the shipped colors, not an empty list")
        }
    }

    func testCorruptEntriesAreDroppedNotSubstituted() {
        withEmptyPalette {
            try? withDefaults([PresetColorPalette.defaultsKey: ["zzzzzz", "00FF00", "00112233"]]) {
                let colors = PresetColorPalette.colors
                XCTAssertEqual(colors.count, 1)
                XCTAssertEqual(hex(colors[0]), "00FF00")
            }
        }
    }

    func testTheListIsCappedOnSave() {
        withEmptyPalette {
            let many = (0..<(PresetColorPalette.maxCount + 10)).map {
                NSColor(srgbRed: CGFloat($0) / 40, green: 0.5, blue: 0.5, alpha: 1)
            }
            PresetColorPalette.save(many)
            let stored = UserDefaults.standard.array(forKey: PresetColorPalette.defaultsKey)
            XCTAssertEqual(stored?.count, PresetColorPalette.maxCount)
            XCTAssertEqual(PresetColorPalette.colors.count, PresetColorPalette.maxCount)
        }
    }

    func testAnOversizedStoredListIsCappedOnLoad() {
        // An imported settings file or hand-edited plist can carry any length.
        let stored = Array(repeating: "112233", count: PresetColorPalette.maxCount + 5)
        try? withDefaults([PresetColorPalette.defaultsKey: stored]) {
            XCTAssertEqual(PresetColorPalette.colors.count, PresetColorPalette.maxCount)
        }
    }

    func testNonStringEntriesDoNotDiscardTheList() {
        try? withDefaults([PresetColorPalette.defaultsKey: ["FF0000", 42, "0000FF"] as [Any]]) {
            XCTAssertEqual(PresetColorPalette.colors.map(hex), ["FF0000", "0000FF"])
        }
    }

    func testAValueThatIsNotAListFallsBackToTheShippedColors() {
        try? withDefaults([PresetColorPalette.defaultsKey: "FF0000"]) {
            XCTAssertEqual(PresetColorPalette.colors.count, PresetColorPalette.defaultColors.count)
        }
    }

    func testSignedHexIsRejected() {
        XCTAssertNil(NSColor(presetHex: "+FFFFF"))
        XCTAssertNil(NSColor(presetHex: "-00000"))
        XCTAssertNotNil(NSColor(presetHex: "abcdef"))
    }

    func testOpacityIsNotStored() {
        withEmptyPalette {
            PresetColorPalette.save([NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.3)])
            XCTAssertEqual(PresetColorPalette.colors.first?.alphaComponent, 1)
        }
    }

    func testResetClearsTheOverrides() {
        withEmptyPalette {
            PresetColorPalette.save([.systemTeal])
            PresetColorPalette.reset()
            XCTAssertEqual(PresetColorPalette.colors.count, PresetColorPalette.defaultColors.count)
        }
    }
}
