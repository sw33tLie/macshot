import XCTest

final class MicrophoneDeviceSelectionTests: XCTestCase {
    func testLegacyProcessSpecificDefaultIDsResolveToCurrentDefault() {
        for id in [nil, "", "CADefaultDeviceAggregate-30911-0", "CADefaultDeviceAggregate-84343-1"] as [String?] {
            XCTAssertNil(MicrophoneDeviceSelection.persistentDeviceID(id))
            let device = MicrophoneDeviceSelection.resolve(savedID: id,
                lookup: { _ -> String? in XCTFail("Temporary ID must not be looked up"); return nil },
                defaultDevice: { "BuiltInMicrophoneDevice" })
            XCTAssertEqual(device, "BuiltInMicrophoneDevice")
        }
    }

    func testRealDeviceIDsArePreservedAndDoNotFallBackWhenDisconnected() {
        for id in ["BuiltInMicrophoneDevice", "AppleUSBAudioEngine:USB:Microphone:1234", "MSLoopbackDriverDevice_UID"] {
            XCTAssertEqual(MicrophoneDeviceSelection.persistentDeviceID(id), id)
            let missing: String? = MicrophoneDeviceSelection.resolve(savedID: id,
                lookup: { XCTAssertEqual($0, id); return nil },
                defaultDevice: { XCTFail("Must not record a different microphone"); return "other" })
            XCTAssertNil(missing)
            let found = MicrophoneDeviceSelection.resolve(savedID: id, lookup: { $0 },
                defaultDevice: { XCTFail("Explicit device must win"); return "other" })
            XCTAssertEqual(found, id)
        }
    }

    @MainActor
    func testMigrationClearsOnlyLegacyDefaultSelectionAndKeepsRecordingEnabled() {
        withDefaults(["selectedMicDeviceUID": "CADefaultDeviceAggregate-30911-0", "recordMicAudio": true]) {
            MicrophoneDeviceSelection.repairLegacyPreference()
            XCTAssertNil(UserDefaults.standard.string(forKey: "selectedMicDeviceUID"))
            XCTAssertTrue(UserDefaults.standard.bool(forKey: "recordMicAudio"))
            MicrophoneDeviceSelection.repairLegacyPreference()
            XCTAssertNil(UserDefaults.standard.string(forKey: "selectedMicDeviceUID"))
        }
        withDefaults(["selectedMicDeviceUID": "disconnected-real-microphone", "recordMicAudio": false]) {
            MicrophoneDeviceSelection.repairLegacyPreference()
            XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedMicDeviceUID"), "disconnected-real-microphone")
            XCTAssertFalse(UserDefaults.standard.bool(forKey: "recordMicAudio"))
        }
    }

    func testRecordingConfigurationCannotKeepAnEphemeralDefaultDevice() throws {
        let config = try RecordingConfiguration(displayID: 42, rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100), backingScale: 1,
            frameRate: 30, microphone: true, systemAudio: false,
            microphoneDeviceID: "CADefaultDeviceAggregate-30911-0", excludedWindows: [], filename: "Mic test")
        XCTAssertNil(config.microphoneDeviceID)
        XCTAssertTrue(config.microphone)
    }
}
