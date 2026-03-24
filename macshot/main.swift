import Cocoa

let app = NSApplication.shared
// main.swift always runs on the main thread. We use assumeIsolated on
// macOS 14+ (Swift 5.9 runtime) and fall back to an unchecked cast on
// older systems where the runtime doesn't enforce actor isolation.
let delegate: AppDelegate
if #available(macOS 14.0, *) {
    delegate = MainActor.assumeIsolated { AppDelegate() }
} else {
    delegate = unsafeBitCast(
        AppDelegate.init as @convention(thin) @MainActor () -> AppDelegate,
        to: (@convention(thin) () -> AppDelegate).self
    )()
}
app.delegate = delegate
app.run()
