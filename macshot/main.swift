import Cocoa

// Disable "AutomaticAppKit" layer content format introduced in Big Sur.
// With automatic format, the window server's compositor applies ordered
// dithering to draw()-based layer content during compositing, which alters
// pixel values in solid-color areas. Setting this to false forces RGBA8
// format, giving pixel-perfect color reproduction — critical for a
// screenshot tool where captured colors must be exact.
UserDefaults.standard.set(false, forKey: "NSViewUsesAutomaticLayerBackingStores")

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
