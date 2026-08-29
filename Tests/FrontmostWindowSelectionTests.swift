import CoreGraphics
import Foundation

@main
struct FrontmostWindowSelectionTests {
    static func main() {
        prefersFrontmostApplicationAndFrontmostWindow()
        skipsTinyGenericAuxiliaryWindowWhenNormalWindowFollows()
        keepsLegitimateCompactWindowsEligible()
        fallsBackToTopNonSelfWindowWhenMenuOwnsFocus()
        rejectsIneligibleAndOffscreenWindows()
        choosesDisplayWithLargestIntersection()
    }

    private static func skipsTinyGenericAuxiliaryWindowWhenNormalWindowFollows() {
        let windows = [
            candidate(id: 50, pid: 200, x: 402, y: 109, width: 66, height: 20, title: "Window"),
            candidate(id: 51, pid: 200, x: 396, y: 103, width: 720, height: 672, title: "Mac Appshot Source Fixture"),
        ]
        let selection = FrontmostWindowSelection.select(
            windows: windows,
            displays: [display(id: 1, x: 0)],
            ownPID: 100,
            preferredPID: 200
        )
        precondition(selection?.window.id == 51)
    }

    private static func keepsLegitimateCompactWindowsEligible() {
        let onlyCompactWindow = FrontmostWindowSelection.select(
            windows: [candidate(id: 52, pid: 200, x: 20, width: 66, height: 20, title: "Window")],
            displays: [display(id: 1, x: 0)],
            ownPID: 100,
            preferredPID: 200
        )
        precondition(onlyCompactWindow?.window.id == 52)

        let titledCompactWindow = FrontmostWindowSelection.select(
            windows: [
                candidate(id: 53, pid: 200, x: 20, width: 66, height: 20, title: "Inspector"),
                candidate(id: 54, pid: 200, x: 20, width: 720, height: 672, title: "Document"),
            ],
            displays: [display(id: 1, x: 0)],
            ownPID: 100,
            preferredPID: 200
        )
        precondition(titledCompactWindow?.window.id == 53)

        let genericCompactWindow = FrontmostWindowSelection.select(
            windows: [
                candidate(id: 55, pid: 200, x: 300, y: 300, width: 66, height: 20, title: "Window"),
                candidate(id: 56, pid: 200, x: 20, y: 10, width: 720, height: 672, title: "Document"),
            ],
            displays: [display(id: 1, x: 0)],
            ownPID: 100,
            preferredPID: 200
        )
        precondition(genericCompactWindow?.window.id == 55)
    }

    private static func prefersFrontmostApplicationAndFrontmostWindow() {
        let windows = [
            candidate(id: 10, pid: 300, x: 10),
            candidate(id: 11, pid: 200, x: 20),
            candidate(id: 12, pid: 200, x: 30),
        ]
        let selection = FrontmostWindowSelection.select(
            windows: windows,
            displays: [display(id: 1, x: 0)],
            ownPID: 100,
            preferredPID: 200
        )
        precondition(selection?.window.id == 11)
    }

    private static func fallsBackToTopNonSelfWindowWhenMenuOwnsFocus() {
        let windows = [
            candidate(id: 20, pid: 100, x: 10),
            candidate(id: 21, pid: 300, x: 20),
            candidate(id: 22, pid: 200, x: 30),
        ]
        let selection = FrontmostWindowSelection.select(
            windows: windows,
            displays: [display(id: 1, x: 0)],
            ownPID: 100,
            preferredPID: nil
        )
        precondition(selection?.window.id == 21)
    }

    private static func rejectsIneligibleAndOffscreenWindows() {
        let windows = [
            candidate(id: 30, pid: 200, layer: 1, x: 10),
            candidate(id: 31, pid: 200, x: 10, width: 1),
            candidate(id: 32, pid: 200, x: 2_000),
        ]
        let selection = FrontmostWindowSelection.select(
            windows: windows,
            displays: [display(id: 1, x: 0)],
            ownPID: 100,
            preferredPID: 200
        )
        precondition(selection == nil)
    }

    private static func choosesDisplayWithLargestIntersection() {
        let window = candidate(id: 40, pid: 200, x: 900, width: 400)
        let selection = FrontmostWindowSelection.select(
            windows: [window],
            displays: [display(id: 1, x: 0), display(id: 2, x: 1_000)],
            ownPID: 100,
            preferredPID: 200
        )
        precondition(selection?.displayID == 2)
    }

    private static func candidate(
        id: UInt32,
        pid: Int32,
        layer: Int = 0,
        x: CGFloat,
        y: CGFloat = 10,
        width: CGFloat = 300,
        height: CGFloat = 200,
        title: String? = nil
    ) -> WindowSelectionCandidate {
        WindowSelectionCandidate(
            id: id,
            ownerPID: pid,
            layer: layer,
            bounds: CGRect(x: x, y: y, width: width, height: height),
            title: title ?? "Window \(id)"
        )
    }

    private static func display(id: UInt32, x: CGFloat) -> DisplaySelectionCandidate {
        DisplaySelectionCandidate(
            id: id,
            bounds: CGRect(x: x, y: 0, width: 1_000, height: 800)
        )
    }
}
