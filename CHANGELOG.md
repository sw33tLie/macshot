# Changelog

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
