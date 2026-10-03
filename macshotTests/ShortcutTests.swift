import Carbon
import Cocoa
import XCTest

/// Shortcut matching decides whether a keypress edits the capture or does
/// nothing. These tests drive the matcher with synthesized events, which is the
/// deterministic half — the ASCII fallback path reads the machine's live
/// keyboard layout and is exercised separately below.
final class KeyboardShortcutMatcherTests: XCTestCase {

    func testMatchesTheSameCharacterAndModifiers() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]))
    }

    func testCharacterComparisonIgnoresCase() {
        let event = TestKeyEvent.keyDown(characters: "Z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command, .shift]))
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "Z", modifiers: [.command, .shift]))
    }

    func testModifiersMustMatchExactly() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
        XCTAssertFalse(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]),
                       "⌘⇧Z must not trigger a plain ⌘Z binding — that's how redo would fire undo")
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command, .shift]))
    }

    func testIrrelevantModifiersAreIgnored() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z,
                                         modifiers: [.command, .capsLock, .function, .numericPad])
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]),
                      "caps lock shouldn't break a shortcut")
    }

    func testModifierExtractionKeepsOnlyTheFourThatMatter() {
        let event = TestKeyEvent.keyDown(characters: "a", keyCode: TestKeyEvent.Code.a,
                                         modifiers: [.command, .option, .capsLock, .help])
        XCTAssertEqual(KeyboardShortcutMatcher.modifiers(in: event), [.command, .option])
    }

    func testADifferentCharacterDoesNotMatch() {
        let event = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.y, modifiers: [.command])
        XCTAssertFalse(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]))
    }

    func testSemanticCharacterFollowsTheLayoutsCharacterNotTheKeyCode() {
        // A QWERTZ keyboard reports "y" from the key that is Z on QWERTY. The
        // matcher must follow the printed character, so ⌘Z stays ⌘Z.
        let qwertz = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
        XCTAssertEqual(KeyboardShortcutMatcher.semanticCharacter(for: qwertz), "y")
        XCTAssertTrue(KeyboardShortcutMatcher.matches(qwertz, character: "y", modifiers: [.command]))
    }

    func testToolCharactersIncludeTheTypedCharacter() {
        let event = TestKeyEvent.keyDown(characters: "r", keyCode: 15)
        XCTAssertTrue(KeyboardShortcutMatcher.toolCharacters(for: event).contains("r"))
    }

    func testToolCharactersAreLowercased() {
        let event = TestKeyEvent.keyDown(characters: "R", keyCode: 15, modifiers: [.shift])
        XCTAssertTrue(KeyboardShortcutMatcher.toolCharacters(for: event).contains("r"))
    }

    func testNonLatinInputStillOffersAnASCIIFallback() {
        // Cyrillic "я" — the app's Latin defaults have to stay reachable, so the
        // matcher offers the ASCII-capable layout's character as well.
        let event = TestKeyEvent.keyDown(characters: "я", keyCode: TestKeyEvent.Code.z)
        let candidates = KeyboardShortcutMatcher.toolCharacters(for: event)
        XCTAssertTrue(candidates.contains("я"), "the typed character is always a candidate")
        XCTAssertGreaterThan(candidates.count, 1, "a non-Latin character needs an ASCII fallback too")
        XCTAssertTrue(candidates.contains { $0.unicodeScalars.first?.isASCII == true })
    }

    func testControlCharactersAreNotShortcuts() {
        for character in ["\n", "\r", "\t", "\u{1B}", "\0"] {
            let event = TestKeyEvent.keyDown(characters: character, keyCode: TestKeyEvent.Code.escape)
            XCTAssertFalse(KeyboardShortcutMatcher.matches(event, character: character, modifiers: []),
                           "\(character.debugDescription) must not resolve as a character shortcut")
        }
    }

    func testMultiCharacterInputIsNotAShortcut() {
        let event = TestKeyEvent.keyDown(characters: "ab", keyCode: TestKeyEvent.Code.a)
        XCTAssertFalse(KeyboardShortcutMatcher.matches(event, character: "ab", modifiers: []))
    }
}

/// Undo/redo chords are user-configurable, and a mis-resolved chord either does
/// nothing or does the opposite of what the user meant.
final class EditorCommandShortcutTests: XCTestCase {

    private let undoKey = "editorCommandShortcuts.undo"
    private let redoKey = "editorCommandShortcuts.redo"

    private func withCleanShortcuts(_ body: () throws -> Void) rethrows {
        try withDefaults([undoKey: nil, redoKey: nil], body)
    }

    // MARK: - Defaults

    func testDefaultUndoAndRedoChords() {
        withCleanShortcuts {
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo),
                           [.init(character: "z", modifiers: [.command])])
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .redo),
                           [.init(character: "z", modifiers: [.command, .shift]),
                            .init(character: "y", modifiers: [.command])])
        }
    }

    func testDefaultChordsResolveToTheirActions() {
        withCleanShortcuts {
            let undo = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            let redoShift = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
            let redoY = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.y, modifiers: [.command])

            XCTAssertEqual(EditorCommandShortcutManager.action(for: undo), .undo)
            XCTAssertEqual(EditorCommandShortcutManager.action(for: redoShift), .redo)
            XCTAssertEqual(EditorCommandShortcutManager.action(for: redoY), .redo)
        }
    }

    func testAnUnboundChordResolvesToNothing() {
        withCleanShortcuts {
            let event = TestKeyEvent.keyDown(characters: "q", keyCode: 12, modifiers: [.command, .option])
            XCTAssertNil(EditorCommandShortcutManager.action(for: event))
        }
    }

    // MARK: - Shortcut normalization

    func testShortcutsNormalizeCaseAndIrrelevantModifiers() {
        let upper = EditorCommandShortcutManager.Shortcut(character: "Z", modifiers: [.command, .capsLock])
        let lower = EditorCommandShortcutManager.Shortcut(character: "z", modifiers: [.command])
        XCTAssertEqual(upper, lower, "the same chord typed with caps lock on must compare equal")
    }

    func testShortcutRoundTripsThroughItsStoredForm() throws {
        let shortcut = EditorCommandShortcutManager.Shortcut(character: "k", modifiers: [.command, .option])
        let decoded = try JSONDecoder().decode(
            EditorCommandShortcutManager.Shortcut.self,
            from: try JSONEncoder().encode(shortcut))
        XCTAssertEqual(decoded, shortcut)
        XCTAssertEqual(decoded.modifiers, [.command, .option])
    }

    // MARK: - Rebinding

    func testRebindingTakesTheChordFromTheOtherAction() {
        withCleanShortcuts {
            // Bind ⌘Z (undo's default) to redo.
            EditorCommandShortcutManager.setShortcut(.init(character: "z", modifiers: [.command]), for: .redo)

            let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            XCTAssertEqual(EditorCommandShortcutManager.action(for: event), .redo,
                           "a chord can only mean one thing")
            XCTAssertFalse(EditorCommandShortcutManager.shortcuts(for: .undo)
                .contains(.init(character: "z", modifiers: [.command])),
                           "undo must lose the chord it no longer owns")
        }
    }

    func testRebindingReplacesRatherThanAppends() {
        withCleanShortcuts {
            EditorCommandShortcutManager.setShortcut(.init(character: "u", modifiers: [.command]), for: .undo)
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo).count, 1)
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo).first?.character, "u")
        }
    }

    func testDisableRemovesTheBindingWithoutRestoringTheDefault() {
        withCleanShortcuts {
            EditorCommandShortcutManager.disable(.undo)
            XCTAssertTrue(EditorCommandShortcutManager.shortcuts(for: .undo).isEmpty,
                          "disabled must stay disabled, not silently fall back to ⌘Z")

            let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            XCTAssertNil(EditorCommandShortcutManager.action(for: event))
        }
    }

    func testResetBringsBackTheDefault() {
        withCleanShortcuts {
            EditorCommandShortcutManager.disable(.undo)
            EditorCommandShortcutManager.reset(.undo)
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo),
                           [.init(character: "z", modifiers: [.command])])
        }
    }

    func testCorruptStoredDataFallsBackToDefaults() {
        withDefaults([undoKey: Data("not json".utf8)]) {
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo),
                           [.init(character: "z", modifiers: [.command])],
                           "a damaged preference must not leave the editor without undo")
        }
    }

    func testDisplayStringsAreHumanReadable() {
        withCleanShortcuts {
            let undo = EditorCommandShortcutManager.displayString(for: .undo)
            XCTAssertTrue(undo.contains("\u{2318}"), "expected ⌘ in \(undo)")
            XCTAssertTrue(undo.uppercased().contains("Z"))
        }
    }

    func testMenuItemGetsTheConfiguredChord() {
        withCleanShortcuts {
            let item = NSMenuItem()
            EditorCommandShortcutManager.applyPrimaryMenuShortcut(for: .undo, to: item)
            XCTAssertEqual(item.keyEquivalent.lowercased(), "z")
            XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command))
        }
    }
}

/// Single-key tool shortcuts in the overlay.
final class ToolShortcutTests: XCTestCase {

    private let toolsKey = "overlayToolShortcuts"

    func testDefaultsAreTheDocumentedLetters() {
        withDefaults([toolsKey: nil]) {
            let expected: [ToolShortcutManager.Action: String] = [
                .pencil: "p", .arrow: "a", .line: "l", .rectangle: "r", .ellipse: "o",
                .marker: "m", .text: "t", .number: "n", .censor: "b", .highlight: "h",
                .colorSampler: "i", .stamp: "g", .adjustSelection: "s", .moveSelection: " ",
                .openInEditor: "e", .pin: "f",
            ]
            for (action, key) in expected {
                XCTAssertEqual(ToolShortcutManager.key(for: action), key, "default for \(action.rawValue)")
            }
        }
    }

    func testEveryDefaultIsEitherUniqueOrDeliberatelyUnbound() {
        withDefaults([toolsKey: nil]) {
            var seen: [String: String] = [:]
            for action in ToolShortcutManager.Action.allCases {
                let key = ToolShortcutManager.key(for: action)
                guard !key.isEmpty else { continue }  // unbound by default
                if let existing = seen[key] {
                    XCTFail("default key `\(key)` is bound to both \(existing) and \(action.rawValue) — one of them would be unreachable")
                }
                seen[key] = action.rawValue
            }
        }
    }

    func testSettingAKeyChangesTheLookup() {
        withDefaults([toolsKey: nil]) {
            let original = ToolShortcutManager.key(for: .pencil)
            defer { ToolShortcutManager.setKey(original, for: .pencil) }

            ToolShortcutManager.setKey("j", for: .pencil)
            XCTAssertEqual(ToolShortcutManager.key(for: .pencil), "j")
            // ToolbarButtonAction isn't Equatable, so compare the tool it carries.
            guard case .tool(let tool)? = ToolShortcutManager.lookupAction(for: "j") else {
                return XCTFail("`j` no longer selects a tool")
            }
            XCTAssertEqual(tool, .pencil)
        }
    }

    func testAnEmptyKeyDisablesTheShortcut() {
        withDefaults([toolsKey: nil]) {
            let original = ToolShortcutManager.key(for: .rectangle)
            defer { ToolShortcutManager.setKey(original, for: .rectangle) }

            ToolShortcutManager.setKey("", for: .rectangle)
            XCTAssertEqual(ToolShortcutManager.key(for: .rectangle), "")
            XCTAssertNil(ToolShortcutManager.lookupAction(for: ""))
            XCTAssertEqual(ToolShortcutManager.displayString(for: .rectangle), L("None"))
        }
    }

    func testDisplayStringsNameTheSpaceKey() {
        withDefaults([toolsKey: nil]) {
            XCTAssertEqual(ToolShortcutManager.displayString(for: .moveSelection), L("Space"))
            XCTAssertEqual(ToolShortcutManager.displayString(for: .pencil), "P")
        }
    }

    func testUnboundCharactersResolveToNothing() {
        withDefaults([toolsKey: nil]) {
            ToolShortcutManager.setKey(ToolShortcutManager.key(for: .pencil), for: .pencil)  // force a cache rebuild
            XCTAssertNil(ToolShortcutManager.lookupAction(for: "~"))
        }
    }

    func testEveryActionHasALabel() {
        for action in ToolShortcutManager.Action.allCases {
            XCTAssertFalse(action.label.isEmpty, "\(action.rawValue) has no label for the settings list")
        }
    }
}

/// Global hotkeys stay physical key-code bindings; only their display strings
/// are translated. These cover the parts that don't touch Carbon registration.
final class HotkeyManagerTests: XCTestCase {

    func testEverySlotHasDistinctDefaultsKeys() {
        var seen = Set<String>()
        for slot in HotkeyManager.HotkeySlot.allCases {
            for key in [slot.keyCodeKey, slot.modifiersKey, slot.disabledKey] {
                XCTAssertTrue(seen.insert(key).inserted, "`\(key)` is used by two hotkey slots, so they'd overwrite each other")
            }
        }
    }

    func testSavingAndReadingAHotkeyRoundTrips() {
        let slot = HotkeyManager.HotkeySlot.captureArea
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.saveHotkey(for: slot, keyCode: 12, modifiers: UInt32(cmdKey | shiftKey))
            let read = HotkeyManager.readHotkey(for: slot)
            XCTAssertEqual(read.keyCode, 12)
            XCTAssertEqual(read.modifiers, UInt32(cmdKey | shiftKey))
        }
    }

    func testAnUnsetHotkeyReportsItsDefault() {
        let slot = HotkeyManager.HotkeySlot.captureArea
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            let read = HotkeyManager.readHotkey(for: slot)
            XCTAssertEqual(read.keyCode, slot.defaultKeyCode)
            XCTAssertEqual(read.modifiers, slot.defaultModifiers)
        }
    }

    func testDisablingAHotkeyReportsNoBinding() {
        let slot = HotkeyManager.HotkeySlot.recordArea
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.disableHotkey(for: slot)
            let read = HotkeyManager.readHotkey(for: slot)
            XCTAssertEqual(read.keyCode, 0)
            XCTAssertEqual(read.modifiers, 0)
            XCTAssertEqual(HotkeyManager.displayString(for: slot), L("None"))
        }
    }

    func testSavingAfterDisablingReEnables() {
        let slot = HotkeyManager.HotkeySlot.recordArea
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.disableHotkey(for: slot)
            HotkeyManager.saveHotkey(for: slot, keyCode: 15, modifiers: UInt32(cmdKey))
            XCTAssertEqual(HotkeyManager.readHotkey(for: slot).keyCode, 15)
        }
    }

    private func withCleanHotkeys(_ slots: [HotkeyManager.HotkeySlot], _ body: () -> Void) {
        let keys = slots.flatMap { [$0.keyCodeKey, $0.modifiersKey, $0.disabledKey] }
        withDefaults(Dictionary(uniqueKeysWithValues: keys.map { ($0, nil as Any?) }), body)
    }

    func testAssigningAChordTakesItAwayFromTheSlotThatHadIt() {
        let first = HotkeyManager.HotkeySlot.captureLastArea
        let second = HotkeyManager.HotkeySlot.pinFromClipboard
        let mods = UInt32(cmdKey | optionKey)
        withCleanHotkeys([first, second]) {
            HotkeyManager.assignHotkey(for: first, keyCode: 12, modifiers: mods)
            let displaced = HotkeyManager.assignHotkey(for: second, keyCode: 12, modifiers: mods)

            XCTAssertEqual(displaced, [first], "two slots can't share a chord")
            XCTAssertEqual(HotkeyManager.readHotkey(for: first).keyCode, 0, "the old slot is cleared")
            XCTAssertEqual(HotkeyManager.readHotkey(for: second).keyCode, 12)
            XCTAssertEqual(HotkeyManager.readHotkey(for: second).modifiers, mods)
        }
    }

    func testAssigningAnotherSlotsDefaultChordClearsThatSlot() {
        // Capture Area is unset, so it is bound through its default (Cmd+Shift+X).
        let area = HotkeyManager.HotkeySlot.captureArea
        let screen = HotkeyManager.HotkeySlot.captureFullScreen
        withCleanHotkeys([area, screen]) {
            let displaced = HotkeyManager.assignHotkey(for: screen, keyCode: area.defaultKeyCode,
                                                       modifiers: area.defaultModifiers)
            XCTAssertEqual(displaced, [area])
            XCTAssertEqual(HotkeyManager.readHotkey(for: area).keyCode, 0,
                           "the slot must not fall back to the default it just lost")
        }
    }

    func testResettingToADefaultTakesItBackFromAnotherSlot() {
        let screen = HotkeyManager.HotkeySlot.captureFullScreen
        let history = HotkeyManager.HotkeySlot.historyOverlay
        withCleanHotkeys([screen, history]) {
            HotkeyManager.assignHotkey(for: history, keyCode: screen.defaultKeyCode, modifiers: screen.defaultModifiers)
            let displaced = HotkeyManager.assignHotkey(for: screen, keyCode: screen.defaultKeyCode,
                                                       modifiers: screen.defaultModifiers)
            XCTAssertEqual(displaced, [history])
            XCTAssertEqual(HotkeyManager.readHotkey(for: history).keyCode, 0)
        }
    }

    func testADifferentModifierIsADifferentChord() {
        let first = HotkeyManager.HotkeySlot.captureLastArea
        let second = HotkeyManager.HotkeySlot.pinFromClipboard
        withCleanHotkeys([first, second]) {
            HotkeyManager.assignHotkey(for: first, keyCode: 12, modifiers: UInt32(cmdKey | shiftKey | optionKey))
            let displaced = HotkeyManager.assignHotkey(for: second, keyCode: 12, modifiers: UInt32(cmdKey | optionKey))
            XCTAssertEqual(displaced, [])
            XCTAssertEqual(HotkeyManager.readHotkey(for: first).keyCode, 12)
        }
    }

    func testDuplicatesLeftByAnImportKeepOnlyTheFirstSlot() {
        let area = HotkeyManager.HotkeySlot.captureArea
        let history = HotkeyManager.HotkeySlot.historyOverlay
        let lastArea = HotkeyManager.HotkeySlot.captureLastArea
        withCleanHotkeys(HotkeyManager.HotkeySlot.allCases) {
            // An imported file that gives three slots the same chord.
            let mods = UInt32(cmdKey | optionKey | controlKey)
            for slot in [area, history, lastArea] {
                HotkeyManager.saveHotkey(for: slot, keyCode: UInt32(kVK_F18), modifiers: mods)
            }
            HotkeyManager.resolveDuplicateHotkeys()
            XCTAssertEqual(HotkeyManager.readHotkey(for: area).keyCode, UInt32(kVK_F18), "the first slot keeps it")
            XCTAssertEqual(HotkeyManager.readHotkey(for: history).keyCode, 0)
            XCTAssertEqual(HotkeyManager.readHotkey(for: lastArea).keyCode, 0)
        }
    }

    func testDistinctHotkeysSurviveDuplicateResolution() {
        withCleanHotkeys(HotkeyManager.HotkeySlot.allCases) {
            let before = HotkeyManager.HotkeySlot.allCases.map { HotkeyManager.readHotkey(for: $0).keyCode }
            HotkeyManager.resolveDuplicateHotkeys()
            let after = HotkeyManager.HotkeySlot.allCases.map { HotkeyManager.readHotkey(for: $0).keyCode }
            XCTAssertEqual(before, after, "the defaults don't collide, so nothing is cleared")
        }
    }

    /// Uses real Carbon registration: a chord the app holds can't be registered
    /// again in the same process, so a second registration attempt tells us
    /// whether HotkeyManager currently holds it.
    func testSuspendReleasesHotkeysAndResumeTakesThemBack() {
        let slot = HotkeyManager.HotkeySlot.captureLastArea
        let key = UInt32(kVK_F19), mods = UInt32(cmdKey | optionKey | controlKey)
        func chordIsFree() -> Bool {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5445_5354), id: 99)
            let status = RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref)
            if let ref { UnregisterEventHotKey(ref) }
            return status == noErr
        }
        withCleanHotkeys([slot]) {
            HotkeyManager.saveHotkey(for: slot, keyCode: key, modifiers: mods)
            HotkeyManager.shared.register(slot: slot, callback: {})
            defer { HotkeyManager.shared.unregisterAll() }

            XCTAssertFalse(chordIsFree(), "registered: the app holds the chord")
            HotkeyManager.shared.suspend()
            XCTAssertTrue(chordIsFree(), "suspended: a recorder can receive the key")
            HotkeyManager.shared.resume()
            XCTAssertFalse(chordIsFree(), "resumed: the hotkey works again")
        }
    }

    func testModifierSymbolsAreInTheOrderMacOSShowsThem() {
        let all = HotkeyManager.modifierString(from: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(all, "\u{2303}\u{2325}\u{21E7}\u{2318}", "macOS renders modifiers as ⌃⌥⇧⌘")
        XCTAssertEqual(HotkeyManager.modifierString(from: 0), "")
    }

    func testFunctionKeysAreRecognized() {
        XCTAssertTrue(HotkeyManager.isFunctionKey(UInt32(kVK_F1)))
        XCTAssertTrue(HotkeyManager.isFunctionKey(UInt32(kVK_F20)))
        XCTAssertFalse(HotkeyManager.isFunctionKey(UInt32(kVK_ANSI_A)),
                       "a plain letter needs a modifier, so it mustn't be treated like F1")
    }

    func testSpecialKeysGetStableNames() {
        XCTAssertEqual(HotkeyManager.keyString(from: UInt32(kVK_Space)), "Space")
        XCTAssertEqual(HotkeyManager.keyString(from: UInt32(kVK_F5)), "F5")
    }

    func testEverySlotHasALabelAndADisplayString() {
        for slot in HotkeyManager.HotkeySlot.allCases {
            XCTAssertFalse(slot.label.isEmpty, "slot \(slot) has no label")
            XCTAssertFalse(HotkeyManager.displayString(for: slot).isEmpty)
        }
    }
}
