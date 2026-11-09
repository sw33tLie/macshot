import Foundation

/// One-time repair of image-effect state left behind by an older build.
///
/// Before the June 2026 "Vivid slider leakage" fix, selecting Vivid also wrote
/// the preset's boost into the persisted slider values (contrast 1.2,
/// saturation 1.5). Today's Vivid applies that boost internally and leaves the
/// sliders neutral, so those three values together are a fingerprint that can
/// only have been written by the old build.
///
/// The real damage wasn't the sliders, though — it was that `effectsPreset`
/// stayed set to Vivid across updates (effects are remembered along with the
/// last tool). Users who tried Vivid once months ago kept getting
/// over-saturated screenshots with crushed grays and no idea why, and reported
/// it as a colour-management bug (issue #345). Clearing the legacy state gets
/// them back to an unprocessed capture.
///
/// Deliberately narrow: it only fires on the exact legacy fingerprint, so
/// someone who chose Vivid in a current build keeps it.
enum EffectsMigration {

    static let migrationKey = "legacyVividEffectStateCleared"

    // The values the pre-fix build persisted when Vivid was selected.
    static let legacyVividContrast = 1.2
    static let legacyVividSaturation = 1.5

    private static let presetKey = "effectsPreset"
    private static let brightnessKey = "effectsBrightness"
    private static let contrastKey = "effectsContrast"
    private static let saturationKey = "effectsSaturation"
    private static let sharpnessKey = "effectsSharpness"

    /// Runs the migration if it hasn't run yet. Returns true when legacy state
    /// was found and cleared.
    @discardableResult
    static func runIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: migrationKey) else { return false }
        defer { defaults.set(true, forKey: migrationKey) }

        guard hasLegacyVividState(defaults: defaults) else { return false }

        defaults.removeObject(forKey: presetKey)
        defaults.removeObject(forKey: brightnessKey)
        defaults.removeObject(forKey: contrastKey)
        defaults.removeObject(forKey: saturationKey)
        defaults.removeObject(forKey: sharpnessKey)
        return true
    }

    /// Whether the stored effect state matches what the pre-fix build wrote for
    /// Vivid: the Vivid preset plus its boost mirrored into the sliders.
    static func hasLegacyVividState(defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: presetKey) != nil,
              defaults.integer(forKey: presetKey) == ImageEffectPreset.vivid.rawValue,
              let contrast = defaults.object(forKey: contrastKey) as? Double,
              let saturation = defaults.object(forKey: saturationKey) as? Double
        else { return false }

        return abs(contrast - legacyVividContrast) < 0.0001
            && abs(saturation - legacyVividSaturation) < 0.0001
    }
}
