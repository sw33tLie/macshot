import Foundation

/// Import / export of app settings (issues #265, #280).
///
/// macshot stores all preferences in `UserDefaults.standard`, which lives inside the
/// sandbox container plist — hard to find and copy by hand (#280). This service serializes
/// the *portable* subset of those preferences to a JSON file the user can move to a clean
/// install or another machine (#265).
///
/// ## How we decide what's portable
/// The app's UserDefaults domain is polluted with OS/framework keys that macOS injects into
/// every app (e.g. `METAL_*`, `AKLastLocale`, `Country`, `KB_*`). A plain denylist can't keep
/// up with these — it fails open, and a real export confirmed ~15 such keys leaked through.
/// A hand-maintained allowlist of every macshot key is the opposite failure: every new feature
/// must remember to register its key or it silently doesn't export.
///
/// Instead we filter by **key shape**, which cleanly separates the two in practice:
///   - macshot's own keys are author-written `camelCase` / `snake_case`, starting lowercase.
///   - Injected OS keys are `SCREAMING_CASE`, or carry a stable system prefix (`NS`, `Apple`,
///     `AK`, `ACD`, `KB_`, `METAL_`, …), or are bare capitalized system nouns (`Country`).
/// So a NEW macshot feature is exported with zero maintenance, while OS junk is excluded by
/// construction. On top of that:
///   - `looksSecret` fails **closed**: any credential-named key (even a future provider's) is
///     never exported, so the shape rule can't accidentally leak a secret.
///   - `excludedKeys` lists the handful of macshot-owned keys that DO match the shape rule but
///     are machine-specific (bookmarks, geometry, device UIDs) or migration bookkeeping.
enum SettingsPortability {

    // MARK: - Envelope

    static let fileType = "macshot-settings"
    static let schemaVersion = 1

    /// A dated, human-friendly default filename, e.g. `macshot-settings-2026-07-08.json`.
    /// The payload is plain JSON, so a `.json` extension is honest and previewable in Finder.
    static func suggestedExportFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "macshot-settings-\(fmt.string(from: Date())).json"
    }

    /// Size cap for a single Data blob (2 MB). Larger blobs (e.g. a big custom beautify
    /// background) are skipped on export and reported, never silently dropped.
    static let maxDataValueBytes = 2 * 1024 * 1024

    // MARK: - Exclusions

    /// Keys that must never transfer: machine-/path-specific state, hardware IDs, transient
    /// geometry, and internal migration bookkeeping. (Secrets are handled by `looksSecret`.)
    static let excludedKeys: Set<String> = [
        // Save directories: paths + security-scoped bookmarks are machine-specific.
        "saveDirectory", "saveDirectoryBookmark",
        "recordingSaveDirectory", "recordingSaveDirectoryBookmark",
        // Selection geometry / last-used resolution: tied to this machine's displays.
        "lastSelectionRect", "lastSelectionScreenFrame",
        "preSelectionResolutionPresetKind", "preSelectionResolutionPresetAspect",
        "preSelectionResolutionPresetWidth", "preSelectionResolutionPresetHeight",
        // Hardware device identifiers.
        "selectedCameraDeviceUID", "selectedMicDeviceUID",
        // Internal migration bookkeeping — transferring stale values hides new tools/actions
        // or wrongly re-enables ones the user disabled. (enabledTools/enabledActions DO transfer.)
        "knownToolRawValues", "knownActionTags",
        "suppressMoveToApplications", "useWindowTitleInFilename",
        // Account PII / history that isn't credential-named but shouldn't leave the machine.
        "gdriveUserEmail",
        "imgbbUploads",   // uploaded image links + delete URLs
    ]

    /// Prefixes of OS/framework key families macOS injects into every app's domain. Stable —
    /// Apple doesn't churn these. Anything starting with one of these is not a macshot setting.
    static let systemPrefixes: [String] = [
        "NS", "Apple", "com.apple", "kCI", "_",
        "AK", "ACD", "KB_", "METAL_",
    ]

    /// Bare system keys that are lowercase/camelCase enough to slip past the shape rule but are
    /// injected by macOS, not macshot. Kept small; add only when a real export surfaces one.
    static let systemExactKeys: Set<String> = [
        "Country", "NavPanelFileListModeForOpenMode", "shouldShowRSVPDataDetectors",
    ]

    /// Substrings that mark a key as a credential/secret. Case-insensitive. This guard fails
    /// CLOSED: even a future provider's key is excluded automatically as long as it's named
    /// like a secret — so the shape rule can never accidentally export a credential.
    static let secretSubstrings: [String] = [
        "apikey", "secret", "token", "password", "credential",
        "bookmark",
        // All S3 config (keys, bucket, endpoint, region, prefix, public URL) reveals the
        // user's private storage infrastructure — treat the whole family as sensitive.
        "s3",
    ]

    static func looksSecret(_ key: String) -> Bool {
        let lower = key.lowercased()
        return secretSubstrings.contains { lower.contains($0) }
    }

    /// A key "looks like a macshot setting" if it's author-written: starts with a lowercase
    /// letter and isn't `SCREAMING_CASE`. OS-injected keys are SCREAMING or capitalized.
    static func looksAppAuthored(_ key: String) -> Bool {
        guard let first = key.first, first.isLetter, first.isLowercase else { return false }
        // SCREAMING_SNAKE_CASE (e.g. METAL_ERROR_MODE) — all letters upper + underscores.
        let letters = key.filter { $0.isLetter }
        if key.contains("_") && !letters.isEmpty && letters.allSatisfy({ $0.isUppercase }) {
            return false
        }
        return true
    }

    /// macshot-owned settings whose names don't fit the lowercase shape rule (e.g. the Sparkle
    /// pref, which macshot deliberately reuses). Explicitly allowed so they still export.
    static let forcedIncludeKeys: Set<String> = [
        "SUEnableAutomaticChecks",
    ]

    /// Whether a key is safe to export/import.
    static func isPortable(_ key: String) -> Bool {
        // Machine-specific / migration macshot keys that would otherwise pass the shape rule.
        if excludedKeys.contains(key) { return false }
        // Secrets (fails closed) — checked before the allow-list so a secret can't be forced in.
        if looksSecret(key) { return false }
        // Explicitly-allowed macshot keys that don't match the lowercase shape rule.
        if forcedIncludeKeys.contains(key) { return true }
        // OS/framework injected keys.
        if systemExactKeys.contains(key) { return false }
        if systemPrefixes.contains(where: { key.hasPrefix($0) }) { return false }
        // Finally: only export things shaped like a macshot-authored setting.
        return looksAppAuthored(key)
    }

    /// Portable keys currently present in defaults. Used by import to clear existing portable
    /// state ("replace portable" semantics).
    static func portableKeysPresentInDefaults() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys.filter(isPortable)
    }

    // MARK: - JSON value coding
    //
    // JSONSerialization handles Bool/Int/Double/String/Array/Dictionary directly. The only
    // UserDefaults type it can't represent is Data (archived NSColor, custom bg image), which
    // we wrap as a tagged base64 object so import can round-trip it exactly.

    private static let dataTag = "__macshotData__"

    /// Convert a UserDefaults value into something JSONSerialization accepts, or nil to skip.
    private static func jsonEncode(_ value: Any, key: String, skipped: inout [String]) -> Any? {
        if let d = value as? Data {
            if d.count > maxDataValueBytes { skipped.append(key); return nil }
            return [dataTag: d.base64EncodedString()]
        }
        // Recurse into containers so nested Data (rare) is handled and non-JSON leaves are dropped.
        if let arr = value as? [Any] {
            return arr.compactMap { jsonEncode($0, key: key, skipped: &skipped) }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if let e = jsonEncode(v, key: key, skipped: &skipped) { out[k] = e }
            }
            return out
        }
        // Plain JSON scalars pass through; anything else (dates, etc.) is dropped.
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return nil
    }

    /// Reverse of `jsonEncode`: turn tagged base64 objects back into Data.
    private static func jsonDecode(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            if let b64 = dict[dataTag] as? String, let d = Data(base64Encoded: b64) {
                return d
            }
            return dict.mapValues { jsonDecode($0) }
        }
        if let arr = value as? [Any] {
            return arr.map { jsonDecode($0) }
        }
        return value
    }

    // MARK: - Export

    struct ExportResult {
        let data: Data
        /// Data values skipped because they exceeded `maxDataValueBytes`.
        let skippedLargeKeys: [String]
        let keyCount: Int
    }

    static func exportData() throws -> ExportResult {
        let all = UserDefaults.standard.dictionaryRepresentation()
        var settings: [String: Any] = [:]
        var skipped: [String] = []

        for (key, value) in all where isPortable(key) {
            if let encoded = jsonEncode(value, key: key, skipped: &skipped) {
                settings[key] = encoded
            }
        }

        let envelope: [String: Any] = [
            "type": fileType,
            "schemaVersion": schemaVersion,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "settings": settings,
        ]

        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        return ExportResult(data: data, skippedLargeKeys: skipped, keyCount: settings.count)
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case notJSON
        case wrongFileType
        case newerSchema(found: Int)
        case missingSettings

        var errorDescription: String? {
            switch self {
            case .notJSON, .wrongFileType:
                return L("This file is not a valid macshot settings file.")
            case .newerSchema:
                return L("This settings file was made by a newer version of macshot. Please update macshot first.")
            case .missingSettings:
                return L("This settings file contains no settings.")
            }
        }
    }

    struct ImportResult {
        let appliedCount: Int
        /// Keys in the file that were ignored (non-portable / excluded / secret-named).
        let skippedKeys: [String]
        let sourceAppVersion: String?
    }

    /// Validate and apply an imported settings file using **replace-portable** semantics:
    /// clear every portable key in defaults, then write the file's portable keys. Local /
    /// secret / migration keys on this machine are left untouched.
    @discardableResult
    static func importData(_ data: Data) throws -> ImportResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notJSON
        }
        guard (obj["type"] as? String) == fileType else { throw ImportError.wrongFileType }
        let foundSchema = (obj["schemaVersion"] as? Int) ?? 0
        if foundSchema > schemaVersion { throw ImportError.newerSchema(found: foundSchema) }
        guard let settings = obj["settings"] as? [String: Any] else { throw ImportError.missingSettings }

        // Decode everything before mutating defaults, so a bad file can't half-apply. Re-check
        // isPortable on the way in: a hand-edited/cross-version file can't inject an excluded
        // or secret key even if it's present in the JSON.
        var toWrite: [String: Any] = [:]
        var skipped: [String] = []
        for (key, jsonValue) in settings {
            guard isPortable(key) else { skipped.append(key); continue }
            toWrite[key] = jsonDecode(jsonValue)
        }

        let defaults = UserDefaults.standard
        for key in portableKeysPresentInDefaults() {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in toWrite {
            defaults.set(value, forKey: key)
        }

        return ImportResult(
            appliedCount: toWrite.count,
            skippedKeys: skipped.sorted(),
            sourceAppVersion: obj["appVersion"] as? String
        )
    }
}
