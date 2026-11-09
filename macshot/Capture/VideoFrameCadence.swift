import AVFoundation
import Foundation

enum VideoFrameCadence {
    nonisolated private static let softwarePrefix = "macshot; frame-duration="

    /// Store the intended render cadence separately from the shortest encoded
    /// sample. Idle heartbeats and the final tail make recordings variable-rate.
    nonisolated static func metadata(for duration: CMTime) -> [AVMetadataItem] {
        guard isUsable(duration) else { return [] }
        let item = AVMutableMetadataItem()
        // AVAssetWriter drops arbitrary QuickTime keys in MP4. The common
        // software field survives as ISO user data in both writer/export paths.
        item.identifier = .commonIdentifierSoftware
        item.value = "\(softwarePrefix)\(duration.value)/\(duration.timescale)" as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return [item]
    }

    nonisolated static func declaredDuration(in metadata: [AVMetadataItem]) -> CMTime? {
        for item in metadata where item.commonKey == .commonKeySoftware {
            guard let text = item.stringValue, text.utf8.count <= 96, text.hasPrefix(softwarePrefix) else { continue }
            let parts = text.dropFirst(softwarePrefix.count).split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let value = Int64(parts[0]), let scale = Int32(parts[1]),
                  value > 0, scale > 0 else { continue }
            let duration = CMTime(value: value, timescale: scale)
            if isUsable(duration) { return duration }
        }
        return nil
    }

    nonisolated static func isUsable(_ duration: CMTime) -> Bool {
        duration.isNumeric && duration.seconds >= 0.001 && duration.seconds <= 1
    }

    /// Read-only track ownership for a background metadata inspection. Cursors
    /// are created and consumed on that worker and never shared with playback.
    struct Inspection: @unchecked Sendable {
        nonisolated(unsafe) let track: AVAssetTrack
        nonisolated init(track: AVAssetTrack) { self.track = track }

        /// At most 9 * 128 presentation intervals, independent of file length.
        /// No pixel decoding and no full-file sample table allocation.
        nonisolated func duration() -> CMTime {
            let range = track.timeRange
            var intervals: [CMTime] = []
            var visited: Set<Double> = []
            if range.isValid, range.duration.isNumeric, range.duration.seconds > 0 {
                for index in 0..<9 {
                    let fraction = Double(index) / 8
                    let time = CMTimeAdd(range.start, CMTimeMultiplyByFloat64(range.duration, multiplier: fraction))
                    guard let cursor = track.makeSampleCursor(presentationTimeStamp: time) else { continue }
                    // Inspect backwards at the end so a long static tail does
                    // not conceal the preceding active cadence.
                    let direction: Int64 = index == 8 ? -1 : 1
                    for _ in 0..<128 {
                        let before = cursor.presentationTimeStamp
                        guard cursor.stepInPresentationOrder(byCount: direction) != 0 else { break }
                        let after = cursor.presentationTimeStamp
                        let start = CMTimeMinimum(before, after)
                        guard start.isNumeric, visited.insert(start.seconds).inserted else { continue }
                        intervals.append(CMTimeSubtract(CMTimeMaximum(before, after), start))
                    }
                }
            }
            return representativeDuration(intervals: intervals, minimum: track.minFrameDuration,
                                          nominalRate: track.nominalFrameRate)
        }
    }

    /// Select the fastest recurring interval, ignoring isolated tiny samples.
    /// A bounded sample cannot characterize every imported VFR clip; new
    /// macshot recordings carry an explicit cadence and bypass this inference.
    nonisolated static func representativeDuration(intervals: [CMTime], minimum: CMTime,
                                                   nominalRate: Float) -> CMTime {
        let samples = intervals.filter(isUsable).sorted { CMTimeCompare($0, $1) < 0 }
        guard !samples.isEmpty else { return duration(minimum: minimum, nominalRate: nominalRate) }
        let required = max(3, Int(ceil(Double(samples.count) * 0.05)))
        var start = 0
        while start < samples.count {
            var end = start + 1
            while end < samples.count, samples[end].seconds <= samples[start].seconds * 1.01 { end += 1 }
            if end - start >= required {
                return normalized(samples[start + (end - start) / 2])
            }
            start = end
        }
        // Very short clips lack a recurring group. The median is robust to a
        // single shortened tail; preferring the minimum recreates that bug.
        return normalized(samples[samples.count / 2])
    }

    nonisolated private static func normalized(_ duration: CMTime) -> CMTime {
        for rate: Int32 in [1, 5, 10, 12, 15, 20, 24, 25, 30, 48, 50, 60, 90, 100, 120, 240] {
            let standard = CMTime(value: 1, timescale: rate)
            if abs(duration.seconds / standard.seconds - 1) < 0.0002 { return standard }
        }
        for numerator: Int32 in [24_000, 30_000, 60_000, 120_000] {
            let standard = CMTime(value: 1001, timescale: numerator)
            if abs(duration.seconds / standard.seconds - 1) < 0.0002 { return standard }
        }
        return duration
    }

    /// Capture uses integer FPS. This clock preserves sub-frame timestamp
    /// precision and passes the eight-hour static-tail writer/decoder test.
    nonisolated static let captureTimeScale: CMTimeScale = 60_000

    /// Keep common rational frame periods exact when possible. Sample duration
    /// fields are 32-bit; AVAssetWriter also rejects the eight-hour static-tail
    /// fixture when its sample interval exceeds Int32.max ticks on this host.
    /// Bound the clock using the selected duration, including sparse video.
    nonisolated static func mediaTimeScale(frameDuration: CMTime, duration: CMTime) -> CMTimeScale {
        let seconds = duration.isNumeric && duration.seconds > 0 ? duration.seconds : 1
        let ceiling = Int64(max(1, min(120_000, floor(Double(Int32.max) / seconds))))
        guard frameDuration.isNumeric, frameDuration.value > 0, frameDuration.timescale > 0 else {
            return CMTimeScale(ceiling)
        }
        var a = frameDuration.value
        var b = Int64(frameDuration.timescale)
        while b != 0 { let remainder = a % b; a = b; b = remainder }
        let denominator = Int64(frameDuration.timescale) / a
        return CMTimeScale(denominator <= ceiling ? (ceiling / denominator) * denominator : ceiling)
    }

    /// Preserve rational rates such as 30000/1001 rather than rounding them to
    /// 30. Prefer sample timing when the track supplies a usable duration.
    nonisolated static func duration(minimum: CMTime, nominalRate: Float) -> CMTime {
        if minimum.isNumeric, minimum.seconds >= 0.001, minimum.seconds <= 1 { return minimum }
        let rate = Double(nominalRate)
        guard rate.isFinite, rate > 0, rate <= 1000 else { return CMTime(value: 1, timescale: 30) }
        for numerator: Int32 in [24_000, 30_000, 60_000, 120_000] {
            if abs(rate - Double(numerator) / 1001) < 0.0002 {
                return CMTime(value: 1001, timescale: numerator)
            }
        }
        return CMTime(seconds: 1 / rate, preferredTimescale: 1_000_000_000)
    }
}
