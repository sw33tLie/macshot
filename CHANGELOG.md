# Changelog

## [1.4.0] - 2026-03-12

### Added
- **Upload to cloud**: Upload screenshots to imgbb with one click. Link auto-copied to clipboard, toast shows clickable link + delete button. Configurable API key in Preferences.
- **Measure tool**: Pixel ruler for measuring distances. Drag to measure, shows pixel dimensions with a label. Hold Shift to snap to horizontal, vertical, or 45° angles. Shows width × height breakdown for diagonal measurements.
- **Colored beautify style icon**: The style picker icon now matches the selected gradient theme color for quick visual identification.

### Changed
- Beautify mode and style now persist across sessions (remembered after toggling).

## [1.3.1] - 2026-03-11

### Added
- **Full-screen capture via single click**: Left-click without dragging instantly selects the entire screen for annotation. Right-click without dragging performs a quick save/copy of the full screen.
- **Smart toolbar placement**: Toolbars now independently detect when they would go off-screen and move inside the selection. Works for any selection shape — full-width, full-height, or full-screen — not just full-screen rectangles.
- **Draggable toolbars**: Drag toolbar backgrounds to reposition them so they don't block areas you want to annotate.

### Changed
- Updated helper text to reflect single-click full-screen shortcuts.

## [1.3.0] - 2026-03-11

### Added
- **Image format setting**: Choose between PNG (lossless, default) and JPEG with adjustable quality slider (10–100%) in Preferences. Applies to clipboard copy, file save, quick save, and screenshot history.
- **Disk-based screenshot history**: Recent captures are now stored as files in `~/Library/Application Support/com.sw33tlie.macshot/history/` instead of in memory. Zero RAM overhead, persists across restarts, and directory is created with owner-only permissions (0700).

## [1.2.7] - 2026-03-11

### Fixed
- **Memory usage**: Screenshot history now stores compressed PNG data instead of raw bitmaps, reducing memory from ~400 MB to ~30-50 MB with 10 entries. Floating thumbnail controller is also released after auto-dismiss instead of holding the full-res image until the next capture.
- **Color picker cursor**: Arrow cursor now shown over the color picker popup instead of crosshair.
- **Color picker indicator**: HSB gradient crosshair ring now tracks the actual mouse position accurately.
- **Selection visibility**: Fixed remaining case where the "Release to annotate" helper text disappeared at 1px selection dimensions.

## [1.2.6] - 2026-03-11

### Fixed
- **Color picker cursor**: The cursor now switches to an arrow over the color picker popup (presets and HSB gradient) instead of staying as a crosshair.
- **Color picker indicator**: The crosshair ring on the HSB gradient now tracks the actual mouse position instead of reverse-computing from the selected color, which caused drift due to color space conversions.

## [1.2.5] - 2026-03-11

### Fixed
- **Selection drawing**: Fixed remaining cases where the selection region and "Release to annotate" helper text would disappear when width or height was exactly 1px during drag.

## [1.2.4] - 2026-03-11

### Fixed
- **Color picker positioning**: The color picker popup now flips above the toolbar when it would go off the bottom of the screen, and clamps horizontally to stay within display bounds.

## [1.2.3] - 2026-03-11

### Improved
- **Color picker**: Replaced the external system color panel with an inline HSB gradient picker. Click the rainbow "+" swatch to expand a hue-saturation gradient and brightness slider directly inside the toolbar popup — no separate window, no losing focus.

### Fixed
- **Selection drawing**: The overlay no longer disappears when the selection width or height is momentarily zero while dragging. The selection region stays visible throughout the entire drag.

## [1.2.2] - 2026-03-11

### Improved
- **Color picker**: Expanded from 12 to 23 preset colors in a 6-column grid, with extra shades and grayscale options. Added a rainbow "+" swatch that opens the macOS system color panel for picking any custom color.

## [1.2.1] - 2026-03-11

### Improved
- **Auto-Redact**: Much better credit card detection — now catches card numbers split across separate lines (e.g. "4868 7191 9682 9038" displayed as four groups), CVV codes, and expiry dates. Multi-pass detection with context awareness.

## [1.2.0] - 2026-03-11

### Added
- **Auto-Redact**: One-click PII detection and redaction. Scans the selected region for emails, phone numbers, credit cards, SSNs, IP addresses, API keys, bearer tokens, and secrets — then covers each match with a filled rectangle. Fully undoable (Cmd+Z removes all redactions at once).
- **Delay Capture**: Timer button in the right toolbar lets you dismiss the overlay and re-capture after 3, 5, or 10 seconds — perfect for capturing tooltips, menus, and hover states. The selection region is preserved. Click to cycle through delays.
- **Right-click mode toggle**: New "Right-click action" setting in Preferences — choose between "Save to file" (default) or "Copy to clipboard".

### Fixed
- **Toolbar overlap**: Right toolbar no longer overlaps with the bottom toolbar when drawing narrow selections.

## [1.1.1] - 2026-03-11

### Added
- **Right-click mode toggle**: New "Right-click action" setting in Preferences — choose between "Save to file" (default) or "Copy to clipboard". Helper text on the capture screen updates to reflect the selected mode.

## [1.1.0] - 2026-03-11

### Added
- **Right-click quick save**: Right-click and drag to select a region and instantly save it as a PNG — no toolbar, no annotations, just a fast screenshot to disk. File is saved with the format `Screenshot 2026-03-11 at 16.09.19.png`.
- **Helper text on capture**: On-screen hints guide new users — idle screen shows left-click vs right-click instructions, and while dragging shows what happens on release (annotate or save to folder).
- **Configurable save folder**: Default save directory changed from Desktop to Pictures. Configurable in Preferences and used by both the Save button and right-click quick save.

### Fixed
- **Crosshair cursor**: Reliably forces the crosshair cursor on capture start, even when no window was focused.
- **Pixelate block size**: Pixelation blocks are now a fixed size regardless of selection area.

## [1.0.7] - 2026-03-11

### Fixed
- **Crosshair cursor**: Reliably forces the crosshair cursor on capture start, even when no window was focused. Previous fix in v1.0.6 was insufficient.

## [1.0.6] - 2026-03-11

### Fixed
- **Crosshair cursor**: The cursor now immediately switches to a crosshair when capture starts. Previously it could stay as a normal pointer until the mouse moved, especially when triggered via hotkey.

## [1.0.5] - 2026-03-11

### Fixed
- **Pixelate block size**: Pixelation blocks are now a fixed size regardless of selection area, so redactions look consistent whether you select a small or large region.
- **Beautify tooltip**: Clarified the Beautify button tooltip so users understand what it does at a glance.

## [1.0.4] - 2026-03-11

### Added
- **Blur Tool**: Real Gaussian blur annotation tool (next to Pixelate in the toolbar). Drag to select a region, blur is applied on release. Uses CIGaussianBlur with edge clamping for clean results.

## [1.0.3] - 2026-03-11

### Added
- **Beautify Mode**: Wrap screenshots in a macOS-style window frame with traffic light buttons, drop shadow, and gradient background. Toggle with the sparkles button in the toolbar, cycle through 6 gradient styles (Ocean, Sunset, Forest, Midnight, Candy, Snow). Applied on copy, save, and pin — OCR always uses the raw image.

## [1.0.2] - 2026-03-11

### Added
- **Screenshot History**: Recent captures are kept in memory and accessible from the "Recent Captures" submenu in the menu bar. Click any entry to re-copy it to clipboard. Configurable size (0–50, default 10). Set to 0 to disable.

## [1.0.1] - 2026-03-11

### Added
- **OCR Text Extraction**: New toolbar button to extract text from the selected area using Apple Vision framework. Results appear in a floating panel with copy, search, and word/character count.
- **Pin to Screen**: Pin any screenshot selection as a floating always-on-top window. Movable, resizable, with right-click context menu (Copy, Save, Close). Press Escape to dismiss.
- **Floating Thumbnail**: After capture, a thumbnail slides in from the bottom-right (like macOS native). Click to dismiss, drag to drop as a PNG file into any app. Auto-dismisses after 5 seconds. Toggleable in Preferences.
- **Capture Sound**: Plays the macOS screenshot sound on copy/save. Toggleable in Preferences.
- **Pixel Dimensions Label**: Selection dimensions (in pixels) shown above/below the selection at all times. Click to type an exact resolution (e.g. "1920x1080") and resize the selection.

### Changed
- Removed the size display toolbar button (replaced by the always-visible pixel dimensions label above the selection)
- Preferences window now includes toggles for capture sound and floating thumbnail
- Added "Made by sw33tLie" attribution with GitHub link in Preferences

## [1.0.0] - 2026-03-11

### Added
- Initial release
- Full screenshot capture with multi-monitor support
- Selection with resize handles
- Annotation tools: Pencil, Line, Arrow, Rectangle, Filled Rectangle, Ellipse, Marker, Text (with rich formatting), Numbered markers, Pixelate
- Color picker with 12 preset colors
- Undo/Redo support
- Copy to clipboard and Save to file
- Global hotkey (default: Cmd+Shift+X, configurable)
- Preferences: hotkey config, save directory, auto-copy toggle, launch at login
- Menu bar agent app (no dock icon)
