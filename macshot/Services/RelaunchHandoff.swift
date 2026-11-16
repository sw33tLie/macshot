import Foundation

/// Lets a replacement started by `AppDelegate.relaunchApp()` survive the
/// single-instance check at launch. The replacement starts while the outgoing
/// instance is still running, and a launch that finds another instance quits.
/// Launch arguments can't mark the replacement: macOS drops them when a
/// sandboxed app opens another app. Instead the outgoing instance leaves a
/// short-lived record in the defaults both processes share.
enum RelaunchHandoff {
    static let pidKey = "relaunchHandoffPID"
    static let dateKey = "relaunchHandoffDate"
    /// Long enough for a slow cold launch, short enough that a crash between
    /// recording and launching can't excuse a real duplicate much later.
    static let lifetime: TimeInterval = 30

    static func record(pid: pid_t = getpid(), now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(Int(pid), forKey: pidKey)
        defaults.set(now, forKey: dateKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pidKey)
        defaults.removeObject(forKey: dateKey)
    }

    /// Whether this launch replaces the instance(s) in `otherPIDs`: true only
    /// when every other running instance is the one that recorded a handoff
    /// within `lifetime`. Consumes the record, so it excuses one launch.
    static func claim(otherPIDs: [pid_t], now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        let pid = defaults.object(forKey: pidKey) as? Int
        let date = defaults.object(forKey: dateKey) as? Date
        clear(defaults: defaults)
        guard let pid, let date, !otherPIDs.isEmpty else { return false }
        let age = now.timeIntervalSince(date)
        guard age >= 0, age <= lifetime else { return false }
        return otherPIDs.allSatisfy { Int($0) == pid }
    }
}
