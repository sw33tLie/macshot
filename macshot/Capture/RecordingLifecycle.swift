import Foundation

/// Session identity travels with every asynchronous operation. Finishing an
/// older session can never reset a new one or deliver its completion twice.
struct RecordingLifecycle {
    enum State { case idle, preparing, recording, paused, stopping }
    private(set) var state: State = .idle
    private(set) var sessionID: UUID?

    mutating func begin() -> UUID? {
        guard state == .idle else { return nil }
        let id = UUID()
        sessionID = id
        state = .preparing
        return id
    }

    func isCurrent(_ id: UUID) -> Bool { sessionID == id }
    func isPreparing(_ id: UUID) -> Bool { isCurrent(id) && state == .preparing }

    mutating func didStart(_ id: UUID) -> Bool {
        guard isPreparing(id) else { return false }
        state = .recording
        return true
    }

    mutating func pause() -> Bool {
        guard state == .recording else { return false }
        state = .paused
        return true
    }

    mutating func resume() -> Bool {
        guard state == .paused else { return false }
        state = .recording
        return true
    }

    mutating func requestStop() -> UUID? {
        guard state != .idle, state != .stopping, let id = sessionID else { return nil }
        state = .stopping
        return id
    }

    mutating func finish(_ id: UUID) -> Bool {
        guard isCurrent(id), state == .stopping else { return false }
        state = .idle
        sessionID = nil
        return true
    }
}
