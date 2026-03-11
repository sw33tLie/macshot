# Changelog

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
