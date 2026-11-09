import AppKit

/// Drain work in the normal event loop and retry Quit when it is safe.
/// `terminateLater` enters AppKit's modal termination loop, which stalled
/// MainActor continuations in the macOS 27 native export probe. Cancelling the
/// first request also cancels an OS logout/restart; the user can retry that
/// system action after saving finishes.
@MainActor
final class ApplicationTerminationCoordinator {
    private var task: Task<Void, Never>?
    var isWaiting: Bool { task != nil }

    func request(hasActiveWork: Bool,
                 drain: @escaping @MainActor () async -> Void,
                 terminate: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        guard hasActiveWork else { return .terminateNow }
        guard task == nil else { return .terminateCancel }
        task = Task {
            await drain()
            task = nil
            terminate()
        }
        return .terminateCancel
    }
}
