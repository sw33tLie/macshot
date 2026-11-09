import Cocoa
import XCTest

/// The preset list drives the selection-size popover. A mislabelled ratio locks
/// the selection to proportions that don't match what the menu says.
final class ResolutionPresetTests: XCTestCase {

    func testEveryRatioLabelMatchesItsValue() throws {
        for preset in ResolutionPresetCatalog.ratios {
            guard case .ratio(let label, let value) = preset else { continue }
            let parts = label.split(separator: ":").map {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            let width = try XCTUnwrap(parts.first ?? nil, "unparseable ratio label \(label)")
            let height = try XCTUnwrap(parts.last ?? nil, "unparseable ratio label \(label)")
            XCTAssertEqual(Double(value), width / height, accuracy: 0.0001,
                           "\"\(label)\" locks the selection to \(value)")
        }
    }

    func testEveryResolutionLabelMatchesItsPixels() throws {
        for preset in ResolutionPresetCatalog.resolutions {
            guard case .resolution(let label, let w, let h) = preset else { continue }
            let digits = label.split(whereSeparator: { !$0.isNumber }).map(String.init)
            XCTAssertEqual(digits.count, 2, "unparseable resolution label \(label)")
            XCTAssertEqual(Int(digits[0]), w, "\"\(label)\" would set width \(w)")
            XCTAssertEqual(Int(digits[1]), h, "\"\(label)\" would set height \(h)")
        }
    }

    func testFreeformComesFirstAndLocksNothing() {
        guard case .freeform = ResolutionPresetCatalog.ratios.first else {
            return XCTFail("Freeform should head the ratio list")
        }
        XCTAssertNil(ResolutionPresetCatalog.ratios.first?.aspectValue)
    }

    func testRatiosAreDistinct() {
        let values = ResolutionPresetCatalog.ratios.compactMap(\.aspectValue)
        XCTAssertEqual(Set(values.map { Double($0) }).count, values.count,
                       "two presets lock the same proportions")
    }

    func testResolutionsArePositiveAndDistinct() {
        var seen = Set<String>()
        for preset in ResolutionPresetCatalog.resolutions {
            guard case .resolution(let label, let w, let h) = preset else { continue }
            XCTAssertGreaterThan(w, 0, label)
            XCTAssertGreaterThan(h, 0, label)
            XCTAssertTrue(seen.insert("\(w)x\(h)").inserted, "\(label) is listed twice")
        }
    }

    func testEveryPresetHasALabel() {
        for preset in ResolutionPresetCatalog.ratios + ResolutionPresetCatalog.resolutions {
            XCTAssertFalse(preset.label.isEmpty)
        }
    }

    func testPortraitAndLandscapePairsAreBothOffered() {
        // 16:9 and 9:16 (and 4:3 / 3:4) should both be there, or rotating a
        // selection means leaving the menu.
        let values = ResolutionPresetCatalog.ratios.compactMap(\.aspectValue).map { Double($0) }
        for pair in [(16.0 / 9.0, 9.0 / 16.0), (4.0 / 3.0, 3.0 / 4.0)] {
            XCTAssertTrue(values.contains { abs($0 - pair.0) < 0.001 }, "missing \(pair.0)")
            XCTAssertTrue(values.contains { abs($0 - pair.1) < 0.001 }, "missing \(pair.1)")
        }
    }
}
