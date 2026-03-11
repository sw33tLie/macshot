# macshot

A native macOS screenshot tool inspired by [Flameshot](https://flameshot.org/). No Electron, no Qt, no bloat — just pure Swift and AppKit.

macshot lives in your menu bar and lets you capture, annotate, and share screenshots with a single hotkey.

## Features

- **Instant capture** — global hotkey (default: `Cmd+Shift+X`) freezes your screen and lets you select a region
- **Annotation tools** — arrow, line, rectangle, filled rectangle, ellipse, pencil, marker/highlighter, text, numbered markers, pixelate/redact
- **Rich text** — bold, italic, underline, strikethrough, adjustable font size, color
- **Shift-constrain** — hold Shift while drawing for straight lines, perfect circles, and squares
- **Secure redaction** — pixelate tool is irreversible (multi-pass downscale, not a reversible blur)
- **Color picker** — 12 preset colors, one click to switch
- **Undo/Redo** — `Cmd+Z` / `Cmd+Shift+Z`
- **OCR text extraction** — extract text from any selected area using Apple Vision, with copy and search
- **Beautify mode** — wrap screenshots in a macOS window frame with traffic lights, shadow, and gradient background (6 styles)
- **Pin to screen** — pin a screenshot as a floating always-on-top window, movable and resizable
- **Floating thumbnail** — thumbnail slides in after capture for quick drag-and-drop (toggleable)
- **Screenshot history** — re-copy recent captures from the menu bar "Recent Captures" submenu (configurable, in-memory)
- **Pixel dimensions** — always-visible size label above the selection, click to type an exact resolution
- **Output options** — copy to clipboard (`Enter` or `Cmd+C`), save to file (`Cmd+S`)
- **Multi-monitor support** — captures all screens simultaneously
- **Configurable hotkey** — change it in Preferences
- **Lightweight** — ~8 MB memory at idle, menu bar only (no dock icon)

## Install

### Homebrew

```bash
brew install sw33tlie/macshot/macshot
```

### Manual

Download the latest `.zip` from [Releases](https://github.com/sw33tLie/macshot/releases), unzip, and drag `macshot.app` to `/Applications`.

### Build from source

Requires Xcode 16+ and macOS 15+.

```bash
git clone https://github.com/sw33tLie/macshot.git
cd macshot
xcodebuild -project macshot.xcodeproj -scheme macshot -configuration Release -derivedDataPath build clean build
cp -R build/Build/Products/Release/macshot.app /Applications/
```

## Usage

1. Launch macshot — it appears as an icon in your menu bar
2. Press `Cmd+Shift+X` (or click "Capture Screen" from the menu bar)
3. Drag to select a region
4. Annotate using the toolbar below the selection
5. Press `Enter` to copy to clipboard, or `Cmd+S` to save to file
6. Press `Esc` to cancel at any time

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+Shift+X` | Capture screen (configurable) |
| `Enter` | Confirm and copy to clipboard |
| `Cmd+C` | Copy to clipboard |
| `Cmd+S` | Save to file |
| `Cmd+Z` | Undo |
| `Cmd+Shift+Z` | Redo |
| `Esc` | Cancel |
| `Shift` (while drawing) | Constrain to straight lines / perfect shapes |

### Permissions

macshot requires **Screen Recording** permission. macOS will prompt you on first capture. If it doesn't work:

1. Open **System Settings > Privacy & Security > Screen Recording**
2. Enable macshot (or remove and re-add it)
3. Restart macshot

## Requirements

- macOS 14.0 (Sonoma) or later

## License

[MIT](LICENSE)
