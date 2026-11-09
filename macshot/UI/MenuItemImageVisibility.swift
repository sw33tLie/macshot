import AppKit

extension NSMenuItem {
    /// macOS 27 hides symbol images in menus unless an item asks to keep its
    /// image (#313). Apple's guidance is to use menu icons sparingly, so this is
    /// for the capture and record actions only, which people find by icon;
    /// everything else follows the system default.
    ///
    /// Set through key-value coding: `preferredImageVisibility` exists only in
    /// the macOS 27 SDK, and release builds use an older one. The behaviour
    /// change applies to every app on macOS 27 whatever SDK it was built with.
    func keepImageVisible() {
        guard #available(macOS 27.0, *),
              responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else { return }
        setValue(Self.imageVisibilityVisible, forKey: "preferredImageVisibility")
    }

    /// `NSMenuItem.ImageVisibility.visible`.
    static let imageVisibilityVisible = 1
}
