import XCTest

/// Exported settings files get shared, attached to bug reports and synced
/// between machines. The export filter is therefore a security boundary: it has
/// to fail closed for anything that looks like a credential.
final class SettingsPortabilityTests: XCTestCase {

    // MARK: - Secrets never leave the machine

    func testKnownCredentialKeysAreNeverPortable() {
        let credentials = [
            "imgbbAPIKey", "googleDriveRefreshToken", "googleDriveAccessToken",
            "s3AccessKey", "s3SecretKey", "s3Bucket", "s3Endpoint", "s3Region",
            "saveDirectoryBookmark", "recordingSaveDirectoryBookmark",
            "translationApiKey", "userPassword", "someCredential",
        ]
        for key in credentials {
            XCTAssertFalse(SettingsPortability.isPortable(key), "`\(key)` must never be exported")
        }
    }

    func testSecretDetectionIsCaseInsensitiveAndSubstringBased() {
        for key in ["myAPIKey", "MYAPIKEY", "providerToken", "TOKEN_store", "xSecrety", "oauthPassword"] {
            XCTAssertTrue(SettingsPortability.looksSecret(key), "`\(key)` should read as a secret")
        }
    }

    func testAFutureProvidersCredentialIsExcludedByName() {
        // The point of the substring rule: a provider added later is covered
        // without anyone remembering to update an exclusion list.
        for key in ["dropboxApiKey", "azureSecret", "newProviderAccessToken", "somethingPassword"] {
            XCTAssertFalse(SettingsPortability.isPortable(key), "`\(key)` slipped through the secret filter")
        }
    }

    func testSecretsWinOverTheForcedIncludeList() {
        for key in SettingsPortability.forcedIncludeKeys {
            XCTAssertFalse(SettingsPortability.looksSecret(key),
                           "`\(key)` is force-included, so it must not be secret-shaped")
        }
        // And the ordering itself: a secret-named key can't be forced in.
        XCTAssertFalse(SettingsPortability.isPortable("SUEnableAutomaticChecksToken"))
    }

    // MARK: - Machine-specific state stays behind

    func testMachineSpecificKeysAreNotPortable() {
        for key in SettingsPortability.excludedKeys {
            XCTAssertFalse(SettingsPortability.isPortable(key), "`\(key)` is machine-specific and must not transfer")
        }
    }

    func testUploadHistoryAndAccountEmailStayLocal() {
        XCTAssertFalse(SettingsPortability.isPortable("imgbbUploads"), "upload history includes delete URLs")
        XCTAssertFalse(SettingsPortability.isPortable("gdriveUserEmail"), "account email is PII")
    }

    // MARK: - System keys are filtered out

    func testSystemInjectedKeysAreNotPortable() {
        let systemKeys = [
            "NSWindowFrame main", "AppleLanguages", "com.apple.trackpad.scrolling",
            "kCIEnableCoreImage", "_internalThing", "AKLastIDMSEnvironment",
            "METAL_ERROR_MODE", "KB_Something", "Country",
        ]
        for key in systemKeys {
            XCTAssertFalse(SettingsPortability.isPortable(key), "`\(key)` is injected by macOS, not a macshot setting")
        }
    }

    func testScreamingSnakeCaseIsNotAppAuthored() {
        XCTAssertFalse(SettingsPortability.looksAppAuthored("METAL_DEVICE_WRAPPER_TYPE"))
        XCTAssertFalse(SettingsPortability.looksAppAuthored("SOME_OTHER_ENV"))
        XCTAssertTrue(SettingsPortability.looksAppAuthored("beautify_enabled"),
                      "a lowercase key with an underscore is still app-authored")
    }

    func testKeysStartingWithACapitalAreNotAppAuthored() {
        XCTAssertFalse(SettingsPortability.looksAppAuthored("Country"))
        XCTAssertFalse(SettingsPortability.looksAppAuthored("WindowState"))
        XCTAssertFalse(SettingsPortability.looksAppAuthored(""))
        XCTAssertFalse(SettingsPortability.looksAppAuthored("9lives"), "a key that doesn't start with a letter")
    }

    // MARK: - Real settings do transfer

    func testEverydaySettingsArePortable() {
        let settings = [
            "imageFormat", "imageQuality", "downscaleRetina", "recordingFormat", "recordingFPS",
            "historySize", "enabledTools", "beautifyEnabled", "beautifyStyleIndex",
            "currentStrokeWidth", "filenameTemplate", "appLanguage", "autoCopyToClipboard",
            "overlayToolShortcuts", "hotkeyKeyCode", "hotkeyModifiers",
        ]
        for key in settings {
            XCTAssertTrue(SettingsPortability.isPortable(key), "`\(key)` is a normal setting and should transfer")
        }
    }

    func testTheSparkleKeyIsForcedThroughDespiteItsShape() {
        XCTAssertTrue(SettingsPortability.isPortable("SUEnableAutomaticChecks"),
                      "macshot owns this pref even though it isn't lowercase")
    }

    // MARK: - Import validation

    func testImportRejectsNonJSON() {
        XCTAssertThrowsError(try SettingsPortability.importData(Data("not json".utf8))) { error in
            XCTAssertTrue(error is SettingsPortability.ImportError, "got \(error)")
        }
    }

    func testImportRejectsAFileFromADifferentApp() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "some-other-app-settings",
            "schemaVersion": 1,
            "settings": ["imageFormat": "png"],
        ])
        XCTAssertThrowsError(try SettingsPortability.importData(json))
    }

    func testImportRejectsANewerSchema() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": SettingsPortability.fileType,
            "schemaVersion": SettingsPortability.schemaVersion + 1,
            "settings": ["imageFormat": "png"],
        ])
        XCTAssertThrowsError(try SettingsPortability.importData(json),
                             "a file from a newer macshot must be refused, not half-applied")
    }

    func testImportRejectsAFileWithNoSettings() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": SettingsPortability.fileType,
            "schemaVersion": SettingsPortability.schemaVersion,
        ])
        XCTAssertThrowsError(try SettingsPortability.importData(json))
    }

    func testImportErrorsAllDescribeThemselves() {
        let errors: [SettingsPortability.ImportError] = [
            .notJSON, .wrongFileType, .newerSchema(found: 9), .missingSettings,
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) has no user-facing message")
        }
    }

    // MARK: - Export

    func testExportContainsOnlyPortableKeys() throws {
        let result = try SettingsPortability.exportData()
        let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let settings = try XCTUnwrap(object?["settings"] as? [String: Any])
        for key in settings.keys {
            XCTAssertTrue(SettingsPortability.isPortable(key), "export leaked `\(key)`")
        }
    }

    func testExportIsTaggedSoItCanBeRecognized() throws {
        let result = try SettingsPortability.exportData()
        let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, SettingsPortability.fileType)
        XCTAssertEqual(object?["schemaVersion"] as? Int, SettingsPortability.schemaVersion)
    }

    func testSuggestedFilenameIsAValidJSONName() {
        let name = SettingsPortability.suggestedExportFilename()
        XCTAssertTrue(name.hasSuffix(".json"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testExportedSecretKeysAreAbsentEvenWhenSet() throws {
        try withDefaults([
            "imgbbAPIKey": "secret-value-1234",
            "s3SecretKey": "another-secret",
            "imageFormat": "png",
        ]) {
            let result = try SettingsPortability.exportData()
            let text = String(decoding: result.data, as: UTF8.self)
            XCTAssertFalse(text.contains("secret-value-1234"), "an API key reached the export file")
            XCTAssertFalse(text.contains("another-secret"), "an S3 secret reached the export file")
        }
    }
}
