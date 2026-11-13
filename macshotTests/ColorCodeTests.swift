import Cocoa
import XCTest

/// The color picker's text field takes typed hex codes, so the parser has to
/// accept the shapes people actually paste and reject the rest rather than
/// silently picking black.
final class ColorCodeTests: XCTestCase {

    private func rgb(_ color: NSColor?) -> (Int, Int, Int)? {
        guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
        return (Int(round(srgb.redComponent * 255)),
                Int(round(srgb.greenComponent * 255)),
                Int(round(srgb.blueComponent * 255)))
    }

    func testHexWithAndWithoutHash() {
        XCTAssertEqual(rgb(ColorCode.color(from: "#FF3B30")).map { [$0.0, $0.1, $0.2] }, [255, 59, 48])
        XCTAssertEqual(rgb(ColorCode.color(from: "ff3b30")).map { [$0.0, $0.1, $0.2] }, [255, 59, 48])
        XCTAssertEqual(rgb(ColorCode.color(from: "  #ff3b30\n")).map { [$0.0, $0.1, $0.2] }, [255, 59, 48])
    }

    func testRejectsInputThatIsNotAHexColor() {
        for text in ["", "   ", "#", "red", "gggggg", "#12345", "#1234567", "255, 59, 48", "12, 34, 56", "rgb(1, 2, 3)"] {
            XCTAssertNil(ColorCode.color(from: text), "\"\(text)\" should not parse as a color")
        }
    }
}

/// The hex field lives in the picker's bottom row, so it has to stay inside
/// the popover and never cover the gradient or sliders.
final class ColorPickerHexFieldTests: XCTestCase {

    private func makePicker() -> (ColorPickerView, NSTextField) {
        let picker = ColorPickerView()
        picker.frame = NSRect(origin: .zero, size: picker.preferredSize)
        let field = picker.subviews.compactMap { $0 as? NSTextField }.first
        return (picker, field ?? NSTextField())
    }

    func testFieldIsInsideThePickerBottomRow() {
        let (picker, field) = makePicker()
        XCTAssertTrue(picker.subviews.contains(field), "the picker should host an editable field")
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(picker.bounds.contains(field.frame), "field \(field.frame) escaped \(picker.bounds)")
        XCTAssertLessThan(field.frame.minY, picker.bounds.height / 4, "the field belongs in the bottom row")
    }

    func testFieldSitsRightOfThePreviewCircle() {
        let (picker, field) = makePicker()
        // The pill must not swallow the color preview circle drawn on the left.
        XCTAssertGreaterThan(field.frame.minX, 24, "field overlaps the preview circle")
        XCTAssertGreaterThanOrEqual(field.frame.maxX, picker.bounds.maxX - 12, "field should span the pill")
    }

    func testFieldShowsTheCurrentColorAsHex() {
        let (picker, field) = makePicker()
        picker.setColor(NSColor(srgbRed: 1, green: 59 / 255, blue: 48 / 255, alpha: 1), opacity: 1)
        XCTAssertEqual(field.stringValue, "#FF3B30")
    }

    func testTypingACodeChangesTheColor() {
        let (picker, field) = makePicker()
        var changed: NSColor?
        picker.onColorChanged = { changed = $0 }

        field.stringValue = "0c2238"
        picker.commitHexField()

        let srgb = try? XCTUnwrap(changed?.usingColorSpace(.sRGB))
        XCTAssertEqual(Int((srgb?.redComponent ?? 0) * 255), 12)
        XCTAssertEqual(Int((srgb?.greenComponent ?? 0) * 255), 34)
        XCTAssertEqual(Int((srgb?.blueComponent ?? 0) * 255), 56)
        XCTAssertEqual(field.stringValue, "#0C2238", "the field normalizes to its display form after committing")
    }

    func testAnInvalidEntryRestoresTheCurrentColor() {
        let (picker, field) = makePicker()
        picker.setColor(.systemBlue, opacity: 1)
        var changes = 0
        picker.onColorChanged = { _ in changes += 1 }

        field.stringValue = "not a color"
        picker.commitHexField()

        XCTAssertEqual(changes, 0, "an unreadable entry must not change the color")
        XCTAssertEqual(field.stringValue, "#" + hex(of: .systemBlue))
    }

    private func hex(of color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}
