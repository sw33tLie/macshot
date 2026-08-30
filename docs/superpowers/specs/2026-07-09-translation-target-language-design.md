# Translation Target Language Setting

## Goal

Replace the hardcoded Simplified Chinese translation target with a user-configurable setting in the Capture settings tab. New installations follow the first macOS preferred language by default.

## Behavior

- The Translation section contains a Target language popup.
- The first option is `Follow System`; the remaining options reuse `TranslationService.availableLanguages`.
- With `Follow System` selected, translation resolves the first macOS preferred language each time it is needed.
- Chinese script identifiers map to the existing service codes: Simplified Chinese to `zh-CN` and Traditional Chinese to `zh-TW`. Region-only identifiers map `zh-HK` and `zh-MO` to Traditional Chinese, while `zh-SG` and bare `zh` map to Simplified Chinese.
- Other locale variants match their base language code, for example `en-US` to `en` and `pt-BR` to `pt`.
- Unsupported or unavailable system languages fall back to English.
- Selecting an explicit target persists its language code. Selecting `Follow System` removes the explicit preference so later macOS language changes take effect.
- Existing explicit `translateTargetLang` values remain valid. Invalid stored values behave as `Follow System` without mutating defaults during a read.

## Implementation

- `TranslationService` owns preference parsing and system-language resolution.
- `targetLanguage` returns a concrete supported language code for translation callers.
- A separate optional preference API distinguishes an explicit selection from `Follow System` for the settings UI.
- `translateBatch` honors its target-language argument again instead of replacing it with a constant.
- `SettingsWindowController` builds the popup from the shared language list and writes changes through `TranslationService`.
- The Translation section is shown on every supported macOS version. The engine and language-pack controls remain conditional on Apple Translation availability; the target-language popup is always available because Google Translate is the fallback engine.

## Validation

- Unit tests cover explicit preference persistence, clearing back to system mode, locale normalization, Chinese script mapping, unsupported-language fallback, and invalid stored values.
- A full macOS build verifies the AppKit settings integration.
- Manual inspection verifies the popup selection and represented language codes.
