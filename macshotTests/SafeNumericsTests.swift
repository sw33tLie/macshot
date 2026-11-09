import CoreMedia
import XCTest

/// `Int(someDouble)` traps on NaN and infinity. AVFoundation reports a NaN
/// frame rate for tracks it can't characterize, and Vision returns a
/// degenerate transform when registration fails — both reach an Int conversion
/// on ordinary user paths (export a GIF, run a scroll capture).
final class SafeNumericsTests: XCTestCase {

    func testOrdinaryValuesConvertNormally() {
        XCTAssertEqual(SafeNumerics.int(3.4), 3)
        XCTAssertEqual(SafeNumerics.int(3.6), 4)
        XCTAssertEqual(SafeNumerics.int(-2.5), -3, "rounds to nearest, ties away from zero")
        XCTAssertEqual(SafeNumerics.int(0.0), 0)
    }

    func testNonFiniteValuesUseTheFallbackInsteadOfTrapping() {
        for value in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            XCTAssertEqual(SafeNumerics.int(value, fallback: 7), 7, "\(value)")
        }
    }

    func testValuesBeyondIntRangeAreClamped() {
        XCTAssertEqual(SafeNumerics.int(1e300), Int.max)
        XCTAssertEqual(SafeNumerics.int(-1e300), Int.min)
    }

    func testFloatAndCGFloatOverloadsBehaveTheSame() {
        XCTAssertEqual(SafeNumerics.int(Float.nan, fallback: 5), 5)
        XCTAssertEqual(SafeNumerics.int(CGFloat.nan, fallback: 5), 5)
        XCTAssertEqual(SafeNumerics.int(Float(29.7)), 30)
    }

    // MARK: - Frame rates

    func testAUsableFrameRateIsKept() {
        XCTAssertEqual(SafeNumerics.frameRate(60), 60)
        XCTAssertEqual(SafeNumerics.frameRate(29.97), 30)
    }

    func testAnUnusableFrameRateFallsBack() {
        // A recording whose writer was killed mid-write reports these, and a
        // broken header can claim an absurd rate.
        for rate in [Float.nan, 0, -30, .infinity, 1e12] {
            XCTAssertEqual(SafeNumerics.frameRate(rate), 30, "\(rate)")
        }
    }

    func testTheFrameRateFallbackIsConfigurable() {
        XCTAssertEqual(SafeNumerics.frameRate(.nan, fallback: 15), 15)
    }

    func testAFrameRateIsAlwaysUsableAsATimescale() {
        // CMTimeScale is Int32; converting an out-of-range value traps.
        for rate in [Float.nan, 1e12, -1e12, 0, 24] {
            let fps = SafeNumerics.frameRate(rate)
            XCTAssertGreaterThan(fps, 0)
            XCTAssertLessThanOrEqual(fps, Int(Int32.max))
            _ = CMTime(value: 1, timescale: CMTimeScale(fps))
        }
    }

    // MARK: - Durations

    func testAValidDurationIsReadInSeconds() {
        XCTAssertEqual(SafeNumerics.seconds(CMTime(seconds: 12.5, preferredTimescale: 600)),
                       12.5, accuracy: 0.001)
    }

    func testAnInvalidDurationFallsBack() {
        XCTAssertEqual(SafeNumerics.seconds(.invalid), 0)
        XCTAssertEqual(SafeNumerics.seconds(.indefinite), 0)
        XCTAssertEqual(SafeNumerics.seconds(.positiveInfinity, fallback: -1), -1)
        XCTAssertEqual(SafeNumerics.seconds(CMTime(value: 100, timescale: 0)), 0,
                       "a zero timescale reads back as NaN")
    }

    func testAFrameEstimateFromABrokenClipStaysUsable() {
        // The GIF export path: duration x frame rate, both from the asset.
        let duration = SafeNumerics.seconds(CMTime(value: 100, timescale: 0))
        let fps = SafeNumerics.frameRate(.nan)
        let frames = max(1, SafeNumerics.int(duration * Double(fps), fallback: 1))
        XCTAssertGreaterThanOrEqual(frames, 1)
    }
}
