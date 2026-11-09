import CoreGraphics
import XCTest

final class RecordingConfigurationTests: XCTestCase {
    private func make(rect: CGRect = CGRect(x: 20, y: 100, width: 321, height: 213),
                      display: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
                      scale: CGFloat = 1, fps: Int = 30) throws -> RecordingConfiguration {
        try RecordingConfiguration(displayID: 42, rect: rect, displayBounds: display,
            backingScale: scale, frameRate: fps, microphone: true, systemAudio: true,
            microphoneDeviceID: "selected-device", excludedWindows: [123], filename: "Test recording")
    }

    func testPixelDimensionsAreEvenAndCropKeepsTheSelectedRegion() throws {
        let config = try make()
        XCTAssertEqual(config.sourceRect, CGRect(x: 20, y: 767, width: 321, height: 213))
        XCTAssertEqual(config.pixelWidth, 320)
        XCTAssertEqual(config.pixelHeight, 212)
        let retina = try make(scale: 2)
        XCTAssertEqual(retina.pixelWidth, 642)
        XCTAssertEqual(retina.pixelHeight, 426)
        XCTAssertEqual(retina.sourceRect, config.sourceRect)
    }

    func testSecondaryDisplayGeometryIsDisplayLocal() throws {
        let config = try make(rect: CGRect(x: -1400, y: 800, width: 200, height: 100),
                              display: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        XCTAssertEqual(config.displayID, 42)
        XCTAssertEqual(config.sourceRect, CGRect(x: 40, y: 0, width: 200, height: 100))
    }

    func testInvalidRegionsAndNonFiniteValuesFailBeforeAnEncoderIsCreated() {
        for rect in [CGRect.zero, CGRect(x: -10, y: 0, width: 100, height: 100),
                     CGRect(x: 1900, y: 0, width: 100, height: 100),
                     CGRect(x: 0, y: 0, width: 1, height: 100),
                     CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                     CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            XCTAssertThrowsError(try make(rect: rect))
        }
        for scale: CGFloat in [0, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            XCTAssertThrowsError(try make(scale: scale))
        }
    }

    func testFrameRateCannotOverflowCMTimeScaleOrRequestAnUnsupportedRate() {
        for fps in [0, -1, 121, Int.max, Int.min] { XCTAssertThrowsError(try make(fps: fps)) }
        for fps in [1, 15, 24, 30, 60, 120] { XCTAssertNoThrow(try make(fps: fps)) }
    }

    func testDeviceAndAudioChoicesTravelWithTheConfiguration() throws {
        let config = try make()
        XCTAssertTrue(config.microphone)
        XCTAssertTrue(config.systemAudio)
        XCTAssertEqual(config.microphoneDeviceID, "selected-device")
        XCTAssertEqual(config.excludedWindows, [123])
        XCTAssertEqual(config.filename, "Test recording")
    }
}

@MainActor
final class RecordingStartupCancellationTests: XCTestCase {
    func testImmediateStopAndRepeatedStartsDoNotInvokeCaptureOrCompleteTwice() async throws {
        // The fake display is never queried: every stop happens synchronously
        // before setup's first turn, including microphone permission work.
        let config = try RecordingConfiguration(displayID: UInt32.max,
            rect: CGRect(x: 0, y: 0, width: 100, height: 100),
            displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            backingScale: 1, frameRate: 30, microphone: true, systemAudio: false,
            microphoneDeviceID: nil, excludedWindows: [], filename: "unused")
        let engine = RecordingEngine()
        let completed = expectation(description: "50 cancelled sessions complete once each")
        completed.expectedFulfillmentCount = 50
        completed.assertForOverFulfill = true
        var count = 0
        engine.onCompletion = { url, error in
            XCTAssertNil(url)
            XCTAssertNotNil(error)
            XCTAssertEqual(engine.state, .idle)
            count += 1
            completed.fulfill()
            if count < 50 {
                engine.startRecording(configuration: config)
                XCTAssertEqual(engine.state, .preparing)
                engine.pauseRecording()
                XCTAssertEqual(engine.state, .preparing)
                engine.stopRecording()
                engine.stopRecording()
            }
        }
        engine.startRecording(configuration: config)
        engine.stopRecording()
        engine.stopRecording()
        await fulfillment(of: [completed], timeout: 5)
        engine.onCompletion = nil
        XCTAssertEqual(count, 50)
        XCTAssertEqual(engine.state, .idle)
    }
}
