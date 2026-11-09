import Foundation

/// A player item owns the mapping that was built with its composition. New
/// editor changes must not reinterpret the old item's current playback time.
struct VideoTimelineMapping: Sendable {
    let entries: [EffectsCompositionInstruction.TimeMapEntry]

    nonisolated func sourceTime(at compositionTime: Double) -> Double {
        guard let first = entries.first, let last = entries.last else { return compositionTime }
        guard compositionTime.isFinite, compositionTime >= first.compStart else { return first.sourceStart }
        for entry in entries where compositionTime < entry.compEnd {
            return entry.sourceStart + max(0, compositionTime - entry.compStart) * entry.factor
        }
        return last.sourceStart + (last.compEnd - last.compStart) * last.factor
    }

    nonisolated func compositionTime(at sourceTime: Double) -> Double {
        guard let first = entries.first, let last = entries.last else { return sourceTime }
        guard sourceTime.isFinite else { return first.compStart }
        for entry in entries {
            if sourceTime <= entry.sourceStart { return entry.compStart }
            let sourceEnd = entry.sourceStart + (entry.compEnd - entry.compStart) * entry.factor
            if entry.factor > 0, sourceTime <= sourceEnd {
                return entry.compStart + (sourceTime - entry.sourceStart) / entry.factor
            }
        }
        return last.compEnd
    }
}
