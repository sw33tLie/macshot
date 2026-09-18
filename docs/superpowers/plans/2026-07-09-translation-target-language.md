# Translation Target Language Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent translation target-language setting whose default follows the first macOS preferred language.

**Architecture:** Put locale normalization and UserDefaults preference handling in a small Foundation-only helper so it can be tested independently of AppKit and the macOS Translation framework. `TranslationService` exposes resolved and explicit target-language APIs, while `SettingsWindowController` renders `Follow System` plus the shared language list.

**Tech Stack:** Swift 5, Foundation, AppKit, UserDefaults, Xcode/macOS, a standalone Swift test executable.

---

### Task 1: Test and implement target-language resolution

**Files:**
- Create: `Tests/TranslationTargetLanguageTests.swift`
- Create: `macshot/Services/TranslationTargetLanguage.swift`

- [ ] **Step 1: Write the failing test runner**

Create a Foundation-only executable test with an `@main` runner that checks:

```swift
expect(resolve(["en-US"]) == "en")
expect(resolve(["pt-BR"]) == "pt")
expect(resolve(["zh-Hans-US"]) == "zh-CN")
expect(resolve(["zh-SG"]) == "zh-CN")
expect(resolve(["zh"]) == "zh-CN")
expect(resolve(["zh-Hant-HK"]) == "zh-TW")
expect(resolve(["zh-HK"]) == "zh-TW")
expect(resolve(["zh-MO"]) == "zh-TW")
expect(resolve(["xx-YY"]) == "en")
expect(resolve([]) == "en")
```

Use a temporary `UserDefaults` suite to verify explicit values override the system, clearing the explicit value restores system resolution, and invalid stored values are ignored without being removed.

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
swiftc Tests/TranslationTargetLanguageTests.swift -o /tmp/macshot-translation-target-tests
```

Expected: compilation fails because `TranslationTargetLanguage` does not exist.

- [ ] **Step 3: Add the minimal Foundation helper**

Create `TranslationTargetLanguage` with:

```swift
enum TranslationTargetLanguage {
    static let preferenceKey = "translateTargetLang"

    static func explicitLanguage(
        in defaults: UserDefaults,
        supportedCodes: Set<String>
    ) -> String?

    static func setExplicitLanguage(
        _ code: String?,
        in defaults: UserDefaults,
        supportedCodes: Set<String>
    )

    static func resolvedLanguage(
        defaults: UserDefaults,
        preferredLanguages: [String],
        supportedCodes: Set<String>,
        fallback: String = "en"
    ) -> String

    static func systemLanguage(
        preferredLanguages: [String],
        supportedCodes: Set<String>,
        fallback: String = "en"
    ) -> String
}
```

Normalize `_` to `-`, map Chinese scripts/regions explicitly, map all other locale variants to their lowercase base code, and use only the first preferred language before falling back.

- [ ] **Step 4: Run the test to verify GREEN**

Run:

```bash
swiftc macshot/Services/TranslationTargetLanguage.swift Tests/TranslationTargetLanguageTests.swift -o /tmp/macshot-translation-target-tests && /tmp/macshot-translation-target-tests
```

Expected: exit 0 and `TranslationTargetLanguageTests: PASS`.

- [ ] **Step 5: Commit the resolver and tests**

```bash
git add macshot/Services/TranslationTargetLanguage.swift Tests/TranslationTargetLanguageTests.swift
git commit -m "Add translation target language resolution"
```

### Task 2: Restore configurable translation behavior

**Files:**
- Modify: `macshot/Services/TranslationService.swift`
- Modify: `macshot/AppDelegate.swift`
- Modify: `macshot/UI/Overlay/OverlayView.swift`
- Modify: `macshot/UI/Overlay/OverlayWindowController.swift`

- [ ] **Step 1: Wire preference APIs into `TranslationService`**

Add a supported-code set derived from `availableLanguages`, expose `explicitTargetLanguage: String?`, and implement `targetLanguage` as a resolved concrete code using `Locale.preferredLanguages`. Keep the existing setter behavior for screenshot/OCR language pickers by storing an explicit selection.

- [ ] **Step 2: Make batch translation honor its argument**

Change `translateBatch(texts:targetLang:completion:)` to pass `targetLang` to Apple or Google translation instead of replacing it with `zh-CN`.

- [ ] **Step 3: Remove stale fixed-language comments**

Update comments in the four files so they describe the configured/resolved target language.

- [ ] **Step 4: Re-run resolver tests**

Run the Task 1 GREEN command. Expected: PASS.

- [ ] **Step 5: Commit service integration**

```bash
git add macshot/Services/TranslationService.swift macshot/AppDelegate.swift macshot/UI/Overlay/OverlayView.swift macshot/UI/Overlay/OverlayWindowController.swift
git commit -m "Use configurable translation target language"
```

### Task 3: Add the target-language setting

**Files:**
- Modify: `macshot/UI/Windows/SettingsWindowController.swift`

- [ ] **Step 1: Add the popup to the Translation section**

Always render the Translation section. Add a popup whose first item is localized `Follow System` with an empty represented code, followed by `TranslationService.availableLanguages`. Select the explicit stored language when valid; otherwise select `Follow System`.

- [ ] **Step 2: Preserve Apple-only controls**

Show the engine selector, provider note, and language-pack link only when Apple Translation is available. The target popup remains visible on older macOS versions because Google Translate is still available.

- [ ] **Step 3: Persist changes**

Add `translationTargetLanguageChanged(_:)`. Set `TranslationService.explicitTargetLanguage` to the represented language code, or `nil` for `Follow System`.

- [ ] **Step 4: Build the app**

Run:

```bash
xcodebuild -scheme macshot -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit the settings UI**

```bash
git add macshot/UI/Windows/SettingsWindowController.swift
git commit -m "Add translation target language setting"
```

### Task 4: Final verification and publish

**Files:**
- Verify all files changed by Tasks 1-3.

- [ ] **Step 1: Run tests and build from a clean state**

Run the resolver test command, then `xcodebuild clean build` with signing disabled. Both must exit 0.

- [ ] **Step 2: Inspect the final diff**

Run `git diff upstream/main...HEAD --check` and inspect `git diff upstream/main...HEAD` for unrelated changes. Keep the existing untracked `MacShot.dmg` untouched.

Inspect the settings implementation to confirm the popup selects `Follow System` when there is no valid explicit preference and that every language item carries its language code as `representedObject`.

- [ ] **Step 3: Push directly to the fork**

```bash
git push origin main
```

Expected: `origin/main` advances without creating a pull request.
