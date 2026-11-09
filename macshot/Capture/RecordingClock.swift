import Foundation

/// Elapsed recording time is derived from a monotonic clock, not the number
/// of UI timer callbacks. Menu tracking and a busy main thread cannot lose time.
struct RecordingClock {
    private var startedAt: TimeInterval?
    private var pausedAt: TimeInterval?
    private var totalPaused: TimeInterval = 0

    mutating func start(at time: TimeInterval) {
        startedAt = time.isFinite ? time : nil
        pausedAt = nil
        totalPaused = 0
    }

    mutating func pause(at time: TimeInterval) {
        guard startedAt != nil, pausedAt == nil, time.isFinite else { return }
        pausedAt = time
    }

    @discardableResult
    mutating func resume(at time: TimeInterval) -> TimeInterval {
        guard let pause = pausedAt, time.isFinite else { return 0 }
        let duration = max(0, time - pause)
        totalPaused += duration
        pausedAt = nil
        return duration
    }

    func elapsed(at time: TimeInterval) -> TimeInterval {
        guard let start = startedAt else { return 0 }
        let elapsed = (pausedAt ?? time) - start - totalPaused
        return elapsed.isFinite ? max(0, elapsed) : 0
    }
}
