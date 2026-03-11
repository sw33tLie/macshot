# macshot

Native macOS screenshot tool inspired by Flameshot. Built with Swift + Storyboard. No Qt, no Electron, no memory leaks.

## Project Setup

- **Language:** Swift 5.0
- **UI:** AppKit + Storyboard (Main.storyboard)
- **Min Target:** macOS 14.0+
- **Bundle ID:** com.sw33tlie.macshot.macshot
- **Sandbox:** Disabled (required for ScreenCaptureKit)
- **LSUIElement:** YES (menu bar only app, no dock icon)
- **Permissions:** Screen Recording (Info.plist already has Privacy - Screen Capture Usage Description)

## Architecture

Menu bar agent app. No main window. All UI is overlay windows created programmatically.

### File Structure

```
macshot/
├── AppDelegate.swift          # App lifecycle, status bar item, global hotkey
├── ScreenCaptureManager.swift # Capture all screens via ScreenCaptureKit
├── OverlayWindowController.swift # One per screen: fullscreen borderless overlay
├── OverlayView.swift          # Selection, drawing, annotation rendering
├── AnnotationToolbar.swift    # Floating toolbar during annotation mode
├── Annotation.swift           # Data models for all annotation types
├── PreferencesWindowController.swift # Settings window (shortcut config)
├── HotkeyManager.swift        # Global keyboard shortcut registration
├── Info.plist                 # Permissions
├── Assets.xcassets/           # App icon, status bar icon
├── Base.lproj/Main.storyboard # Minimal storyboard (just the app + main menu)
└── ViewController.swift       # Unused default (can remain minimal)
```

### Key Components

#### 1. AppDelegate (entry point)
- Create NSStatusItem with icon in system menu bar
- Menu items: "Capture Screen" (with shortcut label), "Preferences...", "Quit"
- Register global hotkey (default: Cmd+Shift+X)
- On trigger: call ScreenCaptureManager then show overlays
- Store preferences in UserDefaults

#### 2. ScreenCaptureManager
- Uses ScreenCaptureKit (`SCScreenshotManager.captureImage`) to capture each display
- Capture ALL screens simultaneously (multi-monitor support)
- Async completion handler returns array of `(NSScreen, CGImage)` pairs
- Retina-aware: captures at best resolution (2x pixel density)
- Clean up captured images when done (no retain cycles)

#### 3. OverlayWindowController (one per screen)
- `NSWindow` level: `.statusBar + 1` (above normal windows)
- `styleMask: [.borderless]`, `backgroundColor: .clear`
- `isOpaque: false`, `hasShadow: false`
- Set frame to screen's full frame
- Content view is OverlayView
- Displays the frozen screenshot as background
- Accept keyboard events (Escape to cancel, Enter/Return to confirm)

#### 4. OverlayView (the main interaction surface)
- **States:** `idle` -> `selecting` -> `selected` -> `annotating`
- Renders captured screenshot as background
- Dark overlay (semi-transparent black) over entire image
- Selection rectangle: user drags to define region, clear/bright area inside selection
- Selection handles: 8 resize handles on edges/corners for adjustment
- After selection: show AnnotationToolbar

**Drawing/annotation modes:**
- **Arrow:** Click start + drag to end, draws arrow with head
- **Line:** Freeform line drawing (pencil/pen)
- **Rectangle:** Drag to draw outlined rectangle
- **Filled Rectangle (blur/opaque):** Drag to draw filled rectangle for redacting/hiding content
- **Circle/Ellipse:** Drag to draw outlined ellipse
- **Text:** Click to place, inline text field appears, type, press Enter to commit
- **Number/Counter:** Click to place numbered circles (auto-incrementing 1, 2, 3...)
- **Highlighter:** Semi-transparent wide stroke for highlighting
- **Color picker:** Quick color selection for annotation tools (red default, + a few presets)
- **Stroke width:** Small/Medium/Large toggle

**Key behaviors:**
- All annotations are drawn within the selected region only (clipped)
- Undo support: Cmd+Z removes last annotation
- Redo support: Cmd+Shift+Z
- Escape: cancel and close overlay (discard everything)
- Enter/Return or double-click: confirm (copy to clipboard by default)

#### 5. AnnotationToolbar
- Floating `NSPanel` positioned near the selection (below or to the side)
- Horizontal row of tool buttons with icons (SF Symbols where possible)
- Tools: Arrow, Line, Rectangle, Filled Rect, Ellipse, Text, Number, Highlighter
- Color picker button (shows small popover with color grid)
- Stroke width toggle
- Action buttons: Copy to Clipboard, Save to File, Cancel
- Toolbar repositions if selection is resized
- Compact, minimal design

#### 6. Annotation (data models)
```swift
enum AnnotationTool {
    case arrow, line, rectangle, filledRectangle, ellipse, text, number, highlighter
}

struct Annotation {
    let tool: AnnotationTool
    let startPoint: NSPoint
    let endPoint: NSPoint
    let color: NSColor
    let strokeWidth: CGFloat
    let text: String?        // for text annotations
    let number: Int?         // for numbered markers
    let path: NSBezierPath?  // for freeform lines
}
```

#### 7. PreferencesWindowController
- Simple window with:
  - Hotkey recorder (click to record new shortcut)
  - "Save to folder" path picker (default: Desktop)
  - Auto-copy to clipboard toggle (default: on)
  - "Launch at login" toggle
- All settings stored in UserDefaults
- Open from menu bar dropdown

#### 8. HotkeyManager
- Use Carbon `RegisterEventHotKey` for global hotkey
- Default: Cmd+Shift+X (avoid conflict with macOS Cmd+Shift+4)
- Configurable via Preferences
- Must work when app is not focused (global)

## Implementation Order

### Phase 1: Menu Bar + Capture Foundation
1. AppDelegate: Status bar item with menu (Capture, Preferences, Quit)
2. ScreenCaptureManager: Capture screen(s) to CGImage
3. Basic OverlayWindowController: Show frozen screenshot as fullscreen overlay
4. Test: clicking "Capture" shows frozen screen overlay, Escape dismisses

### Phase 2: Selection
5. OverlayView: Dark overlay + rubber-band selection rectangle
6. Selection handles for resize/reposition
7. Live clear region inside selection (unmasked area)
8. Test: can select region, resize it, Escape cancels

### Phase 3: Annotation Tools
9. AnnotationToolbar: Floating panel with tool buttons
10. Arrow tool
11. Line (freeform drawing) tool
12. Rectangle + Filled Rectangle tools
13. Ellipse tool
14. Text tool (inline NSTextField)
15. Number/counter tool
16. Highlighter tool
17. Color picker + stroke width
18. Undo/Redo stack

### Phase 4: Output
19. Copy selected+annotated region to clipboard
20. Save to file (PNG)
21. Enter confirms (copies), button alternatives

### Phase 5: Preferences & Hotkey
22. HotkeyManager: Global shortcut registration
23. PreferencesWindowController: Hotkey config, save path, launch at login
24. Persist preferences in UserDefaults

## Coding Conventions

- Pure AppKit, no SwiftUI, no external dependencies (except ScreenCaptureKit from Apple)
- ScreenCaptureKit for screen capture (CGWindowListCreateImage is deprecated in macOS 15+)
- Avoid retain cycles: use `[weak self]` in closures
- Tear down overlay windows and images promptly after capture completes
- All overlay/drawing happens in `draw(_:)` overrides and Core Graphics
- SF Symbols for toolbar icons where available
- Minimal allocations during mouse tracking (reuse paths, avoid creating objects per mouseMoved)
- `NSBezierPath` for all drawing; no UIKit bridging
- UserDefaults for all preferences (no Core Data, no plist files)
- Storyboard is kept minimal (just app entry + main menu); all windows created in code
- Xcode project uses file system synchronized groups: just create .swift files in macshot/ folder and Xcode picks them up automatically

## Important macOS APIs

- `SCShareableContent.getExcludingDesktopWindows` + `SCScreenshotManager.captureImage` - screen capture
- `RegisterEventHotKey` (Carbon) - global hotkey (preferred, simpler)
- `NSStatusBar.system.statusItem(withLength:)` - menu bar icon
- `NSWindow(contentRect:styleMask:backing:defer:)` with `.borderless` - overlay
- `NSBezierPath` - all shape drawing
- `NSImage(cgImage:size:)` - wrapping captures for display
- `NSGraphicsContext` - compositing final output
- `NSPasteboard.general` - clipboard
- `NSSavePanel` - save file dialog

## Build & Run

- Open `macshot.xcodeproj` in Xcode
- Build & Run (Cmd+R)
- Grant Screen Recording permission when prompted
- App appears as icon in menu bar (no dock icon)
- Click menu bar icon -> "Capture Screen" or use global hotkey
