import XCTest

final class FloatingThumbnailPreferenceTests: XCTestCase {

    // MARK: - Stored preferences

    func testClickActionDefaultsToDismiss() {
        withDefaults([ThumbnailClickAction.userDefaultsKey: nil]) {
            XCTAssertEqual(ThumbnailClickAction.current, .dismiss)
        }
    }

    func testClickActionReadsEveryStoredCase() {
        for action in ThumbnailClickAction.allCases {
            withDefaults([ThumbnailClickAction.userDefaultsKey: action.rawValue]) {
                XCTAssertEqual(ThumbnailClickAction.current, action)
            }
        }
    }

    func testClickActionFallsBackForUnknownValues() {
        for stored: Any in ["openInBrowser", "", 1, true] {
            withDefaults([ThumbnailClickAction.userDefaultsKey: stored]) {
                XCTAssertEqual(ThumbnailClickAction.current, .dismiss, "\(stored)")
            }
        }
    }

    func testEditBehaviorDefaultsToDismiss() {
        withDefaults([ThumbnailEditBehavior.userDefaultsKey: nil]) {
            XCTAssertEqual(ThumbnailEditBehavior.current, .dismiss)
        }
    }

    func testEditBehaviorReadsEveryStoredCase() {
        for behavior in ThumbnailEditBehavior.allCases {
            withDefaults([ThumbnailEditBehavior.userDefaultsKey: behavior.rawValue]) {
                XCTAssertEqual(ThumbnailEditBehavior.current, behavior)
            }
        }
    }

    func testEditBehaviorFallsBackForUnknownValues() {
        for stored: Any in ["returnLater", "", 2, false] {
            withDefaults([ThumbnailEditBehavior.userDefaultsKey: stored]) {
                XCTAssertEqual(ThumbnailEditBehavior.current, .dismiss, "\(stored)")
            }
        }
    }

    // MARK: - Editing bookkeeping

    func testCloseBehaviorLeavesNoEditingState() {
        var state = ThumbnailEditingState()
        XCTAssertEqual(state.editorWillOpen(.dismiss), .dismissPreview)
        XCTAssertFalse(state.isEditing)
        XCTAssertFalse(state.isSuspended)
        XCTAssertEqual(state.editorDidClose(), .ignored)
    }

    func testKeptPreviewStaysEditingUntilEveryEditorCloses() {
        var state = ThumbnailEditingState()
        XCTAssertEqual(state.editorWillOpen(.keep), .keepPreview)
        XCTAssertEqual(state.editorWillOpen(.keep), .keepPreview)
        XCTAssertEqual(state.openEditorCount, 2)
        XCTAssertTrue(state.isEditing)
        XCTAssertFalse(state.isSuspended)
        XCTAssertFalse(state.returnsOnNextEditorClose)

        XCTAssertEqual(state.editorDidClose(), .stillEditing)
        XCTAssertTrue(state.isEditing)
        XCTAssertEqual(state.editorDidClose(), .finishedEditing)
        XCTAssertFalse(state.isEditing)
        XCTAssertEqual(state.editorDidClose(), .ignored)
        XCTAssertEqual(state.openEditorCount, 0)
    }

    func testSuspendedPreviewReturnsOnlyAfterTheLastEditorCloses() {
        var state = ThumbnailEditingState()
        XCTAssertEqual(state.editorWillOpen(.returnAfterClose), .suspendPreview)
        XCTAssertTrue(state.isSuspended)
        XCTAssertTrue(state.returnsOnNextEditorClose)

        // A second editor for the same preview does not suspend it again.
        XCTAssertEqual(state.editorWillOpen(.returnAfterClose), .keepPreview)
        XCTAssertFalse(state.returnsOnNextEditorClose)

        XCTAssertEqual(state.editorDidClose(), .stillEditing)
        XCTAssertTrue(state.isSuspended)
        XCTAssertTrue(state.returnsOnNextEditorClose)

        XCTAssertEqual(state.editorDidClose(), .returnToStack)
        XCTAssertFalse(state.isSuspended)
        XCTAssertFalse(state.isEditing)
        XCTAssertEqual(state.editorDidClose(), .ignored)
    }

    func testPreviewCanBeEditedAgainAfterReturning() {
        var state = ThumbnailEditingState()
        _ = state.editorWillOpen(.returnAfterClose)
        XCTAssertEqual(state.editorDidClose(), .returnToStack)
        XCTAssertEqual(state.editorWillOpen(.returnAfterClose), .suspendPreview)
        XCTAssertEqual(state.editorDidClose(), .returnToStack)
        XCTAssertEqual(state, ThumbnailEditingState())
    }

    // MARK: - Stacking

    func testStackingAppendsWhenNoPreviewShowsTheEntry() {
        let plan = FloatingThumbnailStackPlan(
            existingEntryIDs: ["a", nil, "b"], newEntryID: "c", stacking: true)
        XCTAssertEqual(plan, FloatingThumbnailStackPlan(updateIndex: nil, dismissIndices: []))
    }

    func testStackingUpdatesThePreviewForTheSameEntry() {
        let plan = FloatingThumbnailStackPlan(
            existingEntryIDs: ["a", "b", "c"], newEntryID: "b", stacking: true)
        XCTAssertEqual(plan, FloatingThumbnailStackPlan(updateIndex: 1, dismissIndices: []))
    }

    func testPreviewsWithoutAnEntryAreNeverUpdatedInPlace() {
        let plan = FloatingThumbnailStackPlan(
            existingEntryIDs: [nil, nil], newEntryID: nil, stacking: true)
        XCTAssertNil(plan.updateIndex)
    }

    func testReplaceModeClosesEveryPreviewForANewCapture() {
        let plan = FloatingThumbnailStackPlan(
            existingEntryIDs: ["a", nil, "b"], newEntryID: "c", stacking: false)
        XCTAssertEqual(plan, FloatingThumbnailStackPlan(updateIndex: nil, dismissIndices: [0, 1, 2]))
    }

    func testReplaceModeKeepsOnlyThePreviewBeingUpdated() {
        let plan = FloatingThumbnailStackPlan(
            existingEntryIDs: ["a", "b", nil, "c"], newEntryID: "b", stacking: false)
        XCTAssertEqual(plan, FloatingThumbnailStackPlan(updateIndex: 1, dismissIndices: [0, 2, 3]))
    }

    func testOnlyTheFirstMatchingPreviewIsUpdated() {
        let plan = FloatingThumbnailStackPlan(
            existingEntryIDs: ["a", "b", "b"], newEntryID: "b", stacking: false)
        XCTAssertEqual(plan, FloatingThumbnailStackPlan(updateIndex: 1, dismissIndices: [0, 2]))
    }
}
