import CoreGraphics
import Foundation

/// Where the live webcam bubble sat during a take, so the editor can replay
/// the moves and resizes made while recording (#425).
///
/// Positions are normalized to the recorded area with a top-left origin, the
/// same space as the editor's content coordinates. `size` is the bubble's
/// side as a fraction of the recorded area's shorter side. Times are media
/// seconds on the screen recording's clock, with pauses removed.
nonisolated struct CameraPlacementTrack: Equatable, Sendable {
    nonisolated static let filename = "camera-placement.json"
    /// Upper bound on stored samples; a take can't need more than this.
    static let maxSamples = 50_000
    /// Consecutive samples closer than this are one continuous drag and are
    /// interpolated; wider gaps hold the earlier placement until the next one.
    static let interpolationGap = 0.25

    struct Sample: Codable, Equatable, Sendable {
        var time: Double
        var centerX: Double
        var centerY: Double
        var size: Double

        init(time: Double, centerX: Double, centerY: Double, size: Double) {
            self.time = time
            self.centerX = centerX
            self.centerY = centerY
            self.size = size
        }

        private enum CodingKeys: String, CodingKey { case time = "t", centerX = "x", centerY = "y", size = "s" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = c.decode(.time, or: 0)
            centerX = c.decode(.centerX, or: 0.5)
            centerY = c.decode(.centerY, or: 0.5)
            size = c.decode(.size, or: 0.2)
        }

        /// A bubble `frame` inside `bounds`, both in AppKit screen coordinates
        /// (bottom-left origin), as a sample at `time`.
        static func normalized(frame: CGRect, in bounds: CGRect, time: Double) -> Sample? {
            let short = min(bounds.width, bounds.height)
            guard bounds.width > 0, bounds.height > 0, short > 0 else { return nil }
            let x = (frame.midX - bounds.minX) / bounds.width
            let y = (bounds.maxY - frame.midY) / bounds.height
            let s = frame.width / short
            guard x.isFinite, y.isFinite, s.isFinite, s > 0 else { return nil }
            return Sample(time: time, centerX: Double(x), centerY: Double(y), size: Double(s))
        }

        var isValid: Bool {
            time.isFinite && time >= 0 && centerX.isFinite && centerY.isFinite && size.isFinite && size > 0
        }

        /// Clamped into the ranges the renderer accepts.
        var sanitized: Sample {
            Sample(time: time, centerX: min(max(centerX, 0), 1), centerY: min(max(centerY, 0), 1),
                   size: min(max(size, 0.01), 1))
        }
    }

    /// Sorted by time, strictly increasing.
    let samples: [Sample]

    init(samples: [Sample]) {
        var result: [Sample] = []
        // Sorted by time, then by write order so equal times keep the later one.
        let ordered = samples.enumerated().filter { $0.element.isValid }
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        for sample in ordered {
            let clean = sample.sanitized
            // Equal times: the later write wins.
            if let last = result.last, last.time == clean.time { result[result.count - 1] = clean } else {
                result.append(clean)
            }
        }
        self.samples = Array(result.prefix(Self.maxSamples))
    }

    var isEmpty: Bool { samples.isEmpty }

    /// Placement at source media `time`: held between separate moves,
    /// interpolated within a continuous drag.
    func sample(at time: Double) -> Sample? {
        guard let first = samples.first else { return nil }
        guard time.isFinite, time > first.time else { return first }
        // Last sample at or before `time`.
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        let a = samples[lo]
        guard lo + 1 < samples.count else { return a }
        let b = samples[lo + 1]
        let span = b.time - a.time
        guard span > 0, span <= Self.interpolationGap else { return a }
        let k = (time - a.time) / span
        return Sample(time: time, centerX: a.centerX + (b.centerX - a.centerX) * k,
                      centerY: a.centerY + (b.centerY - a.centerY) * k, size: a.size + (b.size - a.size) * k)
    }

    // MARK: File

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(samples)
    }

    /// Reads a track, salvaging readable samples from a damaged file.
    /// (Element-wise like `LenientArrayDecoder`, which is main-actor bound;
    /// this runs from the nonisolated editor document and tests.)
    static func decode(_ data: Data) -> CameraPlacementTrack? {
        guard let raw = try? JSONDecoder().decode([FailableSample].self, from: data) else { return nil }
        let track = CameraPlacementTrack(samples: raw.compactMap(\.value))
        return track.isEmpty ? nil : track
    }

    /// One unreadable sample costs that sample, not the whole track.
    private struct FailableSample: Decodable {
        let value: Sample?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Sample.self)
        }
    }

    static func load(url: URL) -> CameraPlacementTrack? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}
