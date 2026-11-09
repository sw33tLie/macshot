import XCTest

/// Users who tried the Vivid effect in an old build kept getting
/// over-saturated screenshots forever, because the preset stayed persisted
/// across updates and nothing in the UI made that obvious (issue #345).
final class EffectsMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "macshot-effects-migration-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func writeLegacyVividState() {
        defaults.set(ImageEffectPreset.vivid.rawValue, forKey: "effectsPreset")
        defaults.set(0.0, forKey: "effectsBrightness")
        defaults.set(EffectsMigration.legacyVividContrast, forKey: "effectsContrast")
        defaults.set(EffectsMigration.legacyVividSaturation, forKey: "effectsSaturation")
        defaults.set(0.0, forKey: "effectsSharpness")
    }

    private var storedPreset: Int? {
        defaults.object(forKey: "effectsPreset") as? Int
    }

    func testLegacyVividStateIsCleared() {
        writeLegacyVividState()
        XCTAssertTrue(EffectsMigration.runIfNeeded(defaults: defaults))
        XCTAssertNil(storedPreset, "the stuck Vivid preset must be cleared")
        XCTAssertNil(defaults.object(forKey: "effectsContrast"))
        XCTAssertNil(defaults.object(forKey: "effectsSaturation"))
    }

    func testVividChosenInACurrentBuildIsLeftAlone() {
        // Today's build writes neutral sliders alongside the preset, so this
        // is a deliberate choice, not legacy leakage.
        defaults.set(ImageEffectPreset.vivid.rawValue, forKey: "effectsPreset")
        defaults.set(1.0, forKey: "effectsContrast")
        defaults.set(1.0, forKey: "effectsSaturation")

        XCTAssertFalse(EffectsMigration.runIfNeeded(defaults: defaults))
        XCTAssertEqual(storedPreset, ImageEffectPreset.vivid.rawValue,
                       "a user who picked Vivid on purpose keeps it")
    }

    func testOtherPresetsAreNeverTouched() {
        for preset in ImageEffectPreset.allCases where preset != .vivid {
            defaults.removeObject(forKey: EffectsMigration.migrationKey)
            defaults.set(preset.rawValue, forKey: "effectsPreset")
            defaults.set(EffectsMigration.legacyVividContrast, forKey: "effectsContrast")
            defaults.set(EffectsMigration.legacyVividSaturation, forKey: "effectsSaturation")

            XCTAssertFalse(EffectsMigration.runIfNeeded(defaults: defaults), "\(preset)")
            XCTAssertEqual(storedPreset, preset.rawValue, "\(preset) was cleared by mistake")
        }
    }

    func testAnUntouchedInstallIsUnaffected() {
        XCTAssertFalse(EffectsMigration.runIfNeeded(defaults: defaults))
        XCTAssertNil(storedPreset)
    }

    func testTheMigrationRunsOnlyOnce() {
        writeLegacyVividState()
        XCTAssertTrue(EffectsMigration.runIfNeeded(defaults: defaults))

        // The user re-selects Vivid afterwards; it must survive the next launch.
        defaults.set(ImageEffectPreset.vivid.rawValue, forKey: "effectsPreset")
        defaults.set(EffectsMigration.legacyVividContrast, forKey: "effectsContrast")
        defaults.set(EffectsMigration.legacyVividSaturation, forKey: "effectsSaturation")

        XCTAssertFalse(EffectsMigration.runIfNeeded(defaults: defaults))
        XCTAssertEqual(storedPreset, ImageEffectPreset.vivid.rawValue)
    }

    func testTheMigrationIsRecordedEvenWhenThereIsNothingToClear() {
        XCTAssertFalse(EffectsMigration.runIfNeeded(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: EffectsMigration.migrationKey),
                      "an install with no legacy state shouldn't re-check on every launch")
    }

    func testDetectionIgnoresAPartiallyWrittenState() {
        defaults.set(ImageEffectPreset.vivid.rawValue, forKey: "effectsPreset")
        defaults.set(EffectsMigration.legacyVividContrast, forKey: "effectsContrast")
        // No saturation stored at all.
        XCTAssertFalse(EffectsMigration.hasLegacyVividState(defaults: defaults))
    }

    // MARK: - The effect itself

    func testAnIdentityConfigLeavesTheImageAlone() {
        let image = ImageProbe.quadrantImage(width: 20, height: 20)
        let result = ImageEffects.apply(to: image, config: ImageEffectsConfig())
        XCTAssertTrue(result === image, "no effect should mean no re-encode")
    }

    func testVividChangesMidGreyTheWayUsersNoticed() throws {
        // The complaint in #345 is crushed greys, so measure one.
        let grey = ImageProbe.solidImage(width: 20, height: 20,
                                         color: CGColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1))
        var config = ImageEffectsConfig()
        config.preset = .vivid

        let before = try XCTUnwrap(ImageProbe.pixelColor(grey, x: 10, y: 10))
        let after = try XCTUnwrap(ImageProbe.pixelColor(ImageEffects.apply(to: grey, config: config), x: 10, y: 10))

        XCTAssertLessThan(after.redComponent, before.redComponent - 0.02,
                          "Vivid's contrast boost should darken a mid grey — it was applied to every capture")
    }

    func testVividIgnoresLeftoverSliderValues() {
        // Vivid applies its own boost; stale slider values must not stack on top.
        let image = ImageProbe.solidImage(width: 20, height: 20,
                                          color: CGColor(srgbRed: 0.45, green: 0.5, blue: 0.55, alpha: 1))
        var plain = ImageEffectsConfig()
        plain.preset = .vivid
        var withStaleSliders = plain
        withStaleSliders.contrast = Float(EffectsMigration.legacyVividContrast)
        withStaleSliders.saturation = Float(EffectsMigration.legacyVividSaturation)

        XCTAssertEqual(FieldDescriber.describe(ImageEffects.apply(to: image, config: plain)),
                       FieldDescriber.describe(ImageEffects.apply(to: image, config: withStaleSliders)))
    }
}
