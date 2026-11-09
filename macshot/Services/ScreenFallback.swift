import AppKit

extension NSScreen {

    /// The screen transient UI should appear on, or nil when macOS reports no
    /// usable display.
    ///
    /// `NSScreen.screens` can be empty — while every display is asleep, during
    /// a display reconfiguration, or on a Mac running headless. Indexing it
    /// (`NSScreen.screens[0]`) traps, and for a menu-bar app that stays running
    /// for days that shows up as an unexplained quit: a thumbnail reflow or a
    /// toast fired from a timer while the displays were off.
    static var preferred: NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    /// `visibleFrame` of the preferred screen, or a plausible default when
    /// there is no display to ask.
    static var preferredVisibleFrame: NSRect {
        preferred?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
}
