import CoreMedia
import Foundation

/// `Int(someDouble)` traps when the value is NaN or infinite, which is not a
/// theoretical concern here: AVFoundation reports `nominalFrameRate` as NaN for
/// tracks it can't characterize (variable frame rate, or a file whose writer was
/// killed mid-write), `CMTimeGetSeconds` returns NaN for a zero timescale, and
/// Vision hands back a degenerate transform when image registration fails on
/// blank or repetitive content. Each of those reaches an `Int(...)` on a normal
/// user path, so the conversions go through here instead.
enum SafeNumerics {

    /// Rounds to an Int, substituting `fallback` for a non-finite value and
    /// clamping anything outside Int's range.
    static func int(_ value: Double, fallback: Int = 0) -> Int {
        guard value.isFinite else { return fallback }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    static func int(_ value: Float, fallback: Int = 0) -> Int {
        int(Double(value), fallback: fallback)
    }

    static func int(_ value: CGFloat, fallback: Int = 0) -> Int {
        int(Double(value), fallback: fallback)
    }

    /// Highest frame rate treated as real. Anything above this is a broken
    /// header, and the value still has to fit `CMTimeScale` (an Int32) because
    /// callers build `CMTime(value: 1, timescale: CMTimeScale(fps))`.
    static let maxFrameRate = 1000

    /// Frame rate of a video track, or `fallback` when the track doesn't report
    /// a usable one.
    static func frameRate(_ nominal: Float, fallback: Int = 30) -> Int {
        let rate = int(nominal, fallback: fallback)
        guard rate > 0, rate <= maxFrameRate else { return fallback }
        return rate
    }

    /// Duration in seconds, or `fallback` for an indefinite or invalid time.
    static func seconds(_ time: CMTime, fallback: Double = 0) -> Double {
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? value : fallback
    }
}
