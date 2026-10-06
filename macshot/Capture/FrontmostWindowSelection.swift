import CoreGraphics
import Foundation

struct WindowSelectionCandidate: Equatable {
    let id: UInt32
    let ownerPID: Int32
    let layer: Int
    let bounds: CGRect
    let title: String?
}

struct DisplaySelectionCandidate: Equatable {
    let id: UInt32
    let bounds: CGRect
}

struct FrontmostWindowSelectionResult: Equatable {
    let window: WindowSelectionCandidate
    let displayID: UInt32
}

enum FrontmostWindowSelection {
    /// Selects from windows already ordered front-to-back by Quartz.
    static func select(
        windows: [WindowSelectionCandidate],
        displays: [DisplaySelectionCandidate],
        ownPID: Int32,
        preferredPID: Int32?
    ) -> FrontmostWindowSelectionResult? {
        for (index, window) in windows.enumerated() {
            guard window.layer == 0,
                  window.ownerPID != ownPID,
                  preferredPID == nil || window.ownerPID == preferredPID,
                  window.bounds.width > 1,
                  window.bounds.height > 1,
                  let displayID = displayContainingMost(of: window.bounds, displays: displays),
                  !isTinyGenericAuxiliary(
                    window,
                    windowsBehind: windows.dropFirst(index + 1),
                    displays: displays
                  )
            else { continue }

            return FrontmostWindowSelectionResult(window: window, displayID: displayID)
        }
        return nil
    }

    /// AppKit can expose a field-editor window as a layer-zero Quartz window
    /// immediately above the application's normal window. Reject only a
    /// generic-titled candidate that is dramatically smaller in both
    /// dimensions than a usable same-process window behind it.
    private static func isTinyGenericAuxiliary(
        _ candidate: WindowSelectionCandidate,
        windowsBehind: ArraySlice<WindowSelectionCandidate>,
        displays: [DisplaySelectionCandidate]
    ) -> Bool {
        let title = candidate.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.isEmpty || title.caseInsensitiveCompare("Window") == .orderedSame else {
            return false
        }

        let minimumDimensionRatio: CGFloat = 4
        let maximumOriginInset: CGFloat = 16
        return windowsBehind.contains { window in
            let leadingInset = candidate.bounds.minX - window.bounds.minX
            let topInset = candidate.bounds.minY - window.bounds.minY
            return window.ownerPID == candidate.ownerPID
                && window.layer == 0
                && window.bounds.contains(candidate.bounds)
                && leadingInset >= 0
                && topInset >= 0
                && leadingInset <= maximumOriginInset
                && topInset <= maximumOriginInset
                && window.bounds.width >= candidate.bounds.width * minimumDimensionRatio
                && window.bounds.height >= candidate.bounds.height * minimumDimensionRatio
                && displayContainingMost(of: window.bounds, displays: displays) != nil
        }
    }

    private static func displayContainingMost(
        of windowBounds: CGRect,
        displays: [DisplaySelectionCandidate]
    ) -> UInt32? {
        var best: (id: UInt32, area: CGFloat)?
        for display in displays {
            let intersection = display.bounds.intersection(windowBounds)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if let current = best {
                if area > current.area { best = (display.id, area) }
            } else {
                best = (display.id, area)
            }
        }
        guard let best, best.area > 0 else { return nil }
        return best.id
    }
}
