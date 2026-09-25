import Cocoa
import CoreGraphics

struct FrontmostWindowTarget {
    let windowID: CGWindowID
    let applicationName: String
    let bundleIdentifier: String?
    let windowTitle: String?
    let screen: NSScreen
}

enum FrontmostWindowResolver {
    /// Resolves the frontmost app's first normal, on-screen window in Quartz
    /// z-order. Call this synchronously at trigger time so later activation or
    /// capture work cannot change the selected source window.
    static func resolve() -> FrontmostWindowTarget? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ownPID = NSRunningApplication.current.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let preferredPID = frontmost?.processIdentifier == ownPID
            ? nil
            : frontmost?.processIdentifier

        let windows = windowInfo.compactMap { info -> WindowSelectionCandidate? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDictionary["X"],
                  let y = boundsDictionary["Y"],
                  let width = boundsDictionary["Width"],
                  let height = boundsDictionary["Height"] else { return nil }
            return WindowSelectionCandidate(
                id: UInt32(number),
                ownerPID: ownerPID,
                layer: layer,
                bounds: CGRect(x: x, y: y, width: width, height: height),
                title: info[kCGWindowName as String] as? String
            )
        }
        let screenPairs: [(CGDirectDisplayID, NSScreen)] = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return nil }
            return (displayID, screen)
        }
        let screensByID = Dictionary(screenPairs, uniquingKeysWith: { first, _ in first })
        let displays = screenPairs.map { id, _ in
            DisplaySelectionCandidate(id: id, bounds: CGDisplayBounds(id))
        }
        guard let selection = FrontmostWindowSelection.select(
            windows: windows,
            displays: displays,
            ownPID: ownPID,
            preferredPID: preferredPID
        ), let screen = screensByID[selection.displayID],
           let application = NSRunningApplication(processIdentifier: selection.window.ownerPID)
        else { return nil }

        return FrontmostWindowTarget(
            windowID: CGWindowID(selection.window.id),
            applicationName: application.localizedName ?? "Unknown Application",
            bundleIdentifier: application.bundleIdentifier,
            windowTitle: selection.window.title,
            screen: screen
        )
    }
}
