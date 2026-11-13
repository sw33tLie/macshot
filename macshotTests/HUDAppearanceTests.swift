import Cocoa
import XCTest

final class HUDAppearanceTests: XCTestCase {

    private func brightness(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        var value: CGFloat = 0
        rgb.getHue(nil, saturation: nil, brightness: &value, alpha: nil)
        return value
    }

    func testMissingAppearanceStaysOnTheDarkPalette() {
        withDefaults([HUDAppearance.defaultsKey: nil]) {
            XCTAssertEqual(HUDAppearance.current, .dark)
            let aqua = NSAppearance(named: .aqua)!
            XCTAssertEqual(HUDAppearance.current.resolved(using: aqua), .dark)
            let colors = ToolbarLayout.colors(using: aqua)
            XCTAssertEqual(brightness(colors.background), brightness(ToolbarLayout.defaultBgColor), accuracy: 0.001)
            XCTAssertLessThan(brightness(colors.background), 0.5)
            XCTAssertGreaterThan(brightness(colors.icon), 0.9)
            XCTAssertEqual(ToolbarLayout.appearance(matching: colors.background)?.name, .darkAqua)
        }
    }

    func testExplicitDarkKeepsStoredColors() {
        withDefaults([HUDAppearance.defaultsKey: HUDAppearance.dark.rawValue]) {
            let aqua = NSAppearance(named: .aqua)!
            XCTAssertEqual(HUDAppearance.dark.resolved(using: aqua), .dark)
            let colors = ToolbarLayout.colors(using: aqua)
            XCTAssertEqual(brightness(colors.background), brightness(ToolbarLayout.storedBgColor), accuracy: 0.001)
            XCTAssertEqual(brightness(colors.icon), brightness(ToolbarLayout.storedIconColor), accuracy: 0.001)
            XCTAssertLessThan(brightness(colors.background), 0.5)
        }
    }

    func testLightUsesFixedPaletteEvenWhenStoredIconIsWhite() {
        withDefaults([
            HUDAppearance.defaultsKey: HUDAppearance.light.rawValue,
            "toolbarIconColor": nil,
            "toolbarBgColor": nil,
        ]) {
            let darkAqua = NSAppearance(named: .darkAqua)!
            XCTAssertEqual(HUDAppearance.light.resolved(using: darkAqua), .light)
            XCTAssertGreaterThan(brightness(ToolbarLayout.storedIconColor), 0.9)
            let colors = ToolbarLayout.colors(using: darkAqua)
            XCTAssertGreaterThan(brightness(colors.background), 0.5)
            XCTAssertLessThan(brightness(colors.icon), 0.5)
            XCTAssertEqual(ToolbarLayout.appearance(matching: colors.background)?.name, .aqua)
        }
    }

    func testSystemFollowsTheInjectedAppearance() {
        withDefaults([HUDAppearance.defaultsKey: HUDAppearance.system.rawValue]) {
            let aqua = NSAppearance(named: .aqua)!
            let darkAqua = NSAppearance(named: .darkAqua)!
            XCTAssertEqual(HUDAppearance.system.resolved(using: aqua), .light)
            XCTAssertEqual(HUDAppearance.system.resolved(using: darkAqua), .dark)
            let light = ToolbarLayout.colors(using: aqua)
            let dark = ToolbarLayout.colors(using: darkAqua)
            XCTAssertGreaterThan(brightness(light.background), 0.5)
            XCTAssertLessThan(brightness(light.icon), 0.5)
            XCTAssertLessThan(brightness(dark.background), 0.5)
            XCTAssertGreaterThan(brightness(dark.icon), 0.9)
        }
    }

    /// Existing installs have no `hudAppearance` key: the chrome must paint
    /// exactly the stored theme colors, as before the setting existed.
    func testDefaultChromeColorsAreTheStoredTheme() {
        withDefaults([HUDAppearance.defaultsKey: nil]) {
            XCTAssertFalse(ToolbarLayout.usesLightPalette)
            XCTAssertEqual(ToolbarLayout.iconColor, ToolbarLayout.storedIconColor)
            XCTAssertEqual(ToolbarLayout.bgColor, ToolbarLayout.storedBgColor)
        }
    }

    func testUnknownStoredValueFallsBackToDark() {
        withDefaults([HUDAppearance.defaultsKey: "sepia"]) {
            XCTAssertEqual(HUDAppearance.current, .dark)
            XCTAssertFalse(ToolbarLayout.usesLightPalette)
        }
    }

    func testFixedLightUsesTheLightPaletteWithoutAnAppearance() {
        withDefaults([HUDAppearance.defaultsKey: HUDAppearance.light.rawValue]) {
            XCTAssertEqual(HUDAppearance.current.resolved, .light)
            XCTAssertTrue(ToolbarLayout.usesLightPalette)
            XCTAssertEqual(ToolbarLayout.bgColor, ToolbarLayout.lightBgColor)
            XCTAssertEqual(ToolbarLayout.iconColor, ToolbarLayout.lightIconColor)
            XCTAssertEqual(ToolbarLayout.appearance?.name, .aqua)
        }
    }
}
