import AVFoundation
import Cocoa
import XCTest

/// The recorder crops what SCStream captures. AppKit measures from the
/// bottom-left of the whole desktop; SCStream measures from the top-left of one
/// display. Getting that wrong records the wrong part of the screen — and on a
/// second display, often nothing at all.
final class RecordingCropRectTests: XCTestCase {

    /// A typical primary display: 1920x1080 at the origin.
    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testARegionIsFlippedToTopLeftOrigin() {
        // 200pt tall region whose top edge sits 100pt below the top of the screen.
        let selection = NSRect(x: 50, y: 780, width: 400, height: 200)
        let crop = RecordingEngine.cropRect(for: selection, displayBounds: primary)
        XCTAssertEqual(crop, CGRect(x: 50, y: 100, width: 400, height: 200))
    }

    func testARegionAtTheBottomOfTheScreenMapsToTheBottomOfTheCrop() {
        let selection = NSRect(x: 0, y: 0, width: 100, height: 100)
        let crop = RecordingEngine.cropRect(for: selection, displayBounds: primary)
        XCTAssertEqual(crop.origin.y, 980, "the bottom of the desktop is the bottom of the frame")
    }

    func testARegionAtTheTopOfTheScreenMapsToTheOrigin() {
        let selection = NSRect(x: 0, y: 980, width: 100, height: 100)
        let crop = RecordingEngine.cropRect(for: selection, displayBounds: primary)
        XCTAssertEqual(crop.origin, CGPoint(x: 0, y: 0))
    }

    func testFullScreenSelectionCoversTheWholeDisplay() {
        let crop = RecordingEngine.cropRect(for: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                                            displayBounds: primary)
        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testASecondDisplayToTheRightIsMadeDisplayLocal() {
        // Second display placed to the right of the primary.
        let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let selection = NSRect(x: 2020, y: 1240, width: 300, height: 200)
        let crop = RecordingEngine.cropRect(for: selection, displayBounds: secondary)
        XCTAssertEqual(crop, CGRect(x: 100, y: 0, width: 300, height: 200),
                       "coordinates must be relative to the display being recorded")
    }

    func testADisplayToTheLeftOfThePrimaryHasANegativeOrigin() {
        // macOS gives a display placed left of the primary a negative x.
        let leftDisplay = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let selection = NSRect(x: -1400, y: 800, width: 200, height: 100)
        let crop = RecordingEngine.cropRect(for: selection, displayBounds: leftDisplay)
        XCTAssertEqual(crop, CGRect(x: 40, y: 0, width: 200, height: 100))
        XCTAssertGreaterThanOrEqual(crop.origin.x, 0, "a display-local crop can't start at a negative offset")
    }

    func testADisplayAboveThePrimaryIsHandled() {
        let aboveDisplay = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let selection = NSRect(x: 10, y: 2000, width: 100, height: 100)
        let crop = RecordingEngine.cropRect(for: selection, displayBounds: aboveDisplay)
        XCTAssertEqual(crop, CGRect(x: 10, y: 60, width: 100, height: 100))
    }

    func testTheSelectionSizeIsNeverChanged() {
        for bounds in [primary,
                       CGRect(x: 1920, y: 0, width: 2560, height: 1440),
                       CGRect(x: -1440, y: -200, width: 1440, height: 900)] {
            let selection = NSRect(x: bounds.minX + 5, y: bounds.minY + 5, width: 321, height: 213)
            let crop = RecordingEngine.cropRect(for: selection, displayBounds: bounds)
            XCTAssertEqual(crop.size, CGSize(width: 321, height: 213))
        }
    }

    func testFlippingTwiceReturnsTheOriginalRect() {
        // Flipping is its own inverse, which is the property that keeps the
        // recorded region aligned with what the overlay showed.
        let bounds = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let selection = NSRect(x: 300, y: 400, width: 200, height: 150)
        let crop = RecordingEngine.cropRect(for: selection, displayBounds: bounds)
        let backToAppKit = NSRect(
            x: crop.minX + bounds.minX,
            y: bounds.maxY - crop.maxY,
            width: crop.width, height: crop.height)
        XCTAssertEqual(backToAppKit, selection)
    }
}

/// Encoder settings decide file size and whether the file is even valid —
/// H.264 and HEVC both reject odd dimensions.
final class VideoEncodingSettingsTests: XCTestCase {

    private let qualities: [VideoQuality] = [.low, .medium, .high]

    func testDimensionsAreForcedEven() {
        XCTAssertEqual(VideoEncodingSettings.evenDimensions(width: 1921, height: 1081) == (1920, 1080), true)
        XCTAssertEqual(VideoEncodingSettings.evenDimensions(width: 101, height: 99) == (100, 98), true)
    }

    func testEvenDimensionsNeverCollapseToZero() {
        // A zero-size frame can't be encoded at all.
        XCTAssertEqual(VideoEncodingSettings.evenDimensions(width: 0, height: 0) == (2, 2), true)
        XCTAssertEqual(VideoEncodingSettings.evenDimensions(width: 1, height: 1) == (2, 2), true)
        XCTAssertEqual(VideoEncodingSettings.evenDimensions(width: -50, height: -50) == (2, 2), true)
    }

    func testFractionalSizesAreRoundedBeforeBeingMadeEven() {
        XCTAssertEqual(VideoEncodingSettings.evenDimensions(width: 100.6, height: 50.4) == (100, 50), true)
    }

    func testDegenerateInputsFallBackToTheQualityFloor() {
        for quality in qualities {
            for (width, height, fps) in [(0, 1080, 30), (1920, 0, 30), (1920, 1080, 0), (-4, -4, -4)] {
                XCTAssertEqual(
                    VideoEncodingSettings.bitrate(width: width, height: height, fps: fps,
                                                  codec: .h264, quality: quality),
                    quality.minBitrate,
                    "\(width)x\(height)@\(fps) must not produce a computed bitrate")
            }
        }
    }

    func testBitrateStaysInsideTheQualityRange() {
        for quality in qualities {
            for codec in [VideoCodec.h264, .hevc] {
                for (width, height, fps) in [(64, 64, 15), (1920, 1080, 30), (3840, 2160, 60), (7680, 4320, 120)] {
                    let bitrate = VideoEncodingSettings.bitrate(width: width, height: height, fps: fps,
                                                                codec: codec, quality: quality)
                    XCTAssertGreaterThanOrEqual(bitrate, quality.minBitrate, "\(width)x\(height) \(codec)")
                    XCTAssertLessThanOrEqual(bitrate, quality.maxBitrate, "\(width)x\(height) \(codec)")
                }
            }
        }
    }

    func testBiggerFramesAndHigherFrameRatesCostMoreBits() {
        let small = VideoEncodingSettings.bitrate(width: 640, height: 480, fps: 30, codec: .h264, quality: .high)
        let large = VideoEncodingSettings.bitrate(width: 1920, height: 1080, fps: 30, codec: .h264, quality: .high)
        XCTAssertGreaterThan(large, small)

        let slow = VideoEncodingSettings.bitrate(width: 1280, height: 720, fps: 15, codec: .h264, quality: .high)
        let fast = VideoEncodingSettings.bitrate(width: 1280, height: 720, fps: 60, codec: .h264, quality: .high)
        XCTAssertGreaterThan(fast, slow)
    }

    func testTheOutputSettingsAreComplete() {
        let settings = VideoEncodingSettings.outputSettings(
            width: 1280, height: 720, fps: 30, codec: .h264, quality: .high)
        XCTAssertEqual(settings[AVVideoWidthKey] as? Int, 1280)
        XCTAssertEqual(settings[AVVideoHeightKey] as? Int, 720)
        XCTAssertNotNil(settings[AVVideoCodecKey])

        let compression = try? XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertNotNil(compression?[AVVideoAverageBitRateKey])
        XCTAssertEqual(compression?[AVVideoAllowFrameReorderingKey] as? Bool, false,
                       "B-frames add latency for little gain on screen content")
    }

    func testKeyframeIntervalIsNeverZero() {
        // A zero interval makes the encoder emit no keyframes, which breaks seeking.
        for fps in [0, 1, 30, 120] {
            let settings = VideoEncodingSettings.outputSettings(
                width: 640, height: 480, fps: fps, codec: .h264, quality: .medium)
            let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
            XCTAssertGreaterThanOrEqual(compression?[AVVideoMaxKeyFrameIntervalKey] as? Int ?? 0, 1,
                                        "fps \(fps) produced an unusable keyframe interval")
        }
    }

    func testMP4AlwaysUsesH264ForCompatibility() {
        XCTAssertEqual(VideoEncodingSettings.preferredCodec(for: .mp4), .h264,
                       "an MP4 with HEVC won't play everywhere")
    }
}
