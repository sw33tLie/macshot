import Cocoa

/// macshot is a menu bar app (LSUIElement). Settings and editor windows put it
/// in the Dock while they're open, unless "Hide Dock icon" keeps it out.
enum DockIconPolicy {
    static let hideKey = "hideDockIcon"

    static func policyForOpenWindow(defaults: UserDefaults = .standard) -> NSApplication.ActivationPolicy {
        defaults.bool(forKey: hideKey) ? .accessory : .regular
    }

    /// Call when a Settings or editor window opens.
    static func applyForOpenWindow() {
        NSApp.setActivationPolicy(policyForOpenWindow())
    }
}
