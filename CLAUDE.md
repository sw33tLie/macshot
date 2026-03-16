# macshot

Native macOS screenshot & annotation tool inspired by Flameshot. Built with Swift + AppKit. No Qt, no Electron, no external dependencies.

## Project Setup

- **Language:** Swift 5.0
- **UI:** AppKit (all windows created in code, storyboard is minimal — just app entry + main menu)
- **Min Target:** macOS 14.0+
- **Bundle ID:** com.sw33tlie.macshot.macshot
- **Sandbox:** Disabled (required for ScreenCaptureKit)
- **LSUIElement:** YES (menu bar only app, no dock icon — switches to `.regular` when editor windows are open)
- **Permissions:** Screen Recording (Info.plist has Privacy - Screen Capture Usage Description)
- **Xcode:** File system synchronized groups — just create .swift files in `macshot/` and Xcode picks them up automatically

## Architecture

Menu bar agent app. No main window. Global hotkey (Cmd+Shift+X) or menu bar click triggers screen capture → fullscreen overlay → selection → annotation → output.

### File Structure

```
macshot/
├── main.swift                         # App entry point
├── AppDelegate.swift                  # App lifecycle, status bar, hotkey, capture orchestration
├── ScreenCaptureManager.swift         # Multi-screen capture via ScreenCaptureKit (async/await)
├── OverlayWindowController.swift      # One per screen: fullscreen borderless overlay window
├── OverlayView.swift                  # Main canvas: selection, drawing, annotation, toolbars (~6000 lines)
├── AnnotationToolbar.swift            # Toolbar button definitions, layout constants, drawing helpers
├── Annotation.swift                   # Data model + drawing for all annotation types
├── DetachedEditorWindowController.swift  # Standalone editor window (resizable, titled)
├── PinWindowController.swift          # Floating always-on-top pinned screenshot
├── FloatingThumbnailController.swift  # Auto-dismiss thumbnail after capture (right edge)
├── PreferencesWindowController.swift  # Settings: General, Tools, Recording tabs
├── HotkeyManager.swift               # Global keyboard shortcut (Carbon RegisterEventHotKey)
├── RecordingEngine.swift              # Screen recording (MP4 via AVAssetWriter, GIF via GIFEncoder)
├── RecordingControlView.swift         # Click-through recording control overlay
├── RecordingToastView.swift           # Toast notification after recording completes
├── ScrollCaptureController.swift      # Scroll capture with SAD-based stitching
├── OCRResultController.swift          # Text recognition results window with translation
├── TranslationService.swift           # Google Translate API wrapper
├── BeautifyRenderer.swift             # Gradient frame / background beautification
├── ImageEncoder.swift                 # PNG/JPEG encoding, clipboard copy
├── ImgurUploader.swift                # imgbb image upload
├── UploadToastController.swift        # Upload progress/success toast
├── ScreenshotHistory.swift            # Local history in ~/Library/Application Support/
├── GIFEncoder.swift                   # Animated GIF from video frames
├── CountdownView.swift                # Delay capture countdown display
├── PermissionOnboardingController.swift  # First-run permission guide
├── ViewController.swift               # Unused default (minimal)
├── Info.plist
├── Assets.xcassets/
└── Base.lproj/Main.storyboard
```

### Component Overview

#### AppDelegate — Entry Point & Orchestrator
- NSStatusItem in menu bar with "Capture Screen", "Recent Captures", "Preferences...", "Quit"
- Registers global hotkey via HotkeyManager
- On trigger: ScreenCaptureManager captures all screens → creates one OverlayWindowController per screen
- Implements `OverlayWindowControllerDelegate` — handles confirm, cancel, pin, OCR, recording, scroll capture, upload, delay
- Manages: `overlayControllers[]`, `thumbnailControllers[]`, `pinControllers[]`, `ocrController`, `recordingEngine`, `scrollCaptureController`

#### ScreenCaptureManager
- Async/await with TaskGroup for concurrent multi-display capture
- `SCShareableContent.getExcludingDesktopWindows` + `SCScreenshotManager.captureImage`
- Returns `[(NSScreen, CGImage)]` pairs
- CPU-backed blit of GPU-sourced IOSurface images on capture thread (avoids main thread GPU stall)

#### OverlayWindowController — One Per Screen
- `NSWindow` level `.statusBar + 1`, borderless, transparent
- Content view is OverlayView with the frozen screenshot
- Implements `OverlayViewDelegate` — bridges view events to AppDelegate
- Handles detach: crops screenshot to selection, clones annotations with coordinate shift, opens DetachedEditorWindowController

#### OverlayView — The Main Interaction Surface (~6000 lines)
The core of the app. Handles selection, annotation, rendering, and all user interaction.

**State machine:** `idle` → `selecting` → `selected`

**Zoom system:** 0.1x–8x (min 1.0x in overlay, 0.1x in editor), scroll/pinch to zoom, pan while zoomed, clickable zoom label

**Toolbars:** Two bars drawn inline in `draw(_:)` (not separate windows), draggable:
- **Bottom bar:** Drawing tools, color picker, stroke width, undo/redo
- **Right bar:** Output actions (copy, save, pin, OCR, upload, etc.), cancel, move selection, editor, delay, record, scroll capture

**`isDetached` mode:** When true (editor window), hides overlay-only buttons (cancel, move, delay, record, scroll capture), pins toolbars to window edges, dark background, image centered at natural size, no selection border/handles, no new-selection on click outside.

**Drawing pipeline in `draw(_:)`:**
1. Background: screenshot image (full-screen in overlay, centered in editor)
2. Dark overlay mask (except inside selection) — skipped in editor
3. Selection rectangle with 8 resize handles — skipped in editor
4. Annotations rendered with cached composite when not actively drawing
5. Toolbars (bottom + right bars) with hover/press states
6. Popovers (color picker, stroke width)
7. Zoom label (fades out)
8. Recording indicators (elapsed time, controls)

**Text editing:** Inline NSTextView with rich formatting (bold, italic, underline, strikethrough, font size). Commits to `Annotation.textImage` snapshot on Enter.

**Annotation selection:** Select tool picks existing annotations, 8-point resize handles, move without switching tools (hover detection), delete/edit buttons on selection.

**Bend control point:** Lines and arrows support a draggable control point for curved paths (cubic bezier with cp1==cp2).

#### Annotation — Data Model + Drawing
Class (not struct) with `clone()` for safe copying.

**Tools (AnnotationTool enum, 17 cases):**
```
pencil, line, arrow, rectangle, filledRectangle, ellipse, marker,
text, number, pixelate, blur, measure, loupe, select,
translateOverlay, crop, colorSampler
```

**Key properties:** tool, startPoint, endPoint, color, strokeWidth, text, attributedText, number, points (freeform), bakedBlurNSImage (pixelate/blur result), textImage (text snapshot), textDrawRect, fontSize, isBold/isItalic/isUnderline/isStrikethrough, controlPoint (bend), groupID (batch undo for auto-redact), sourceImage (temporary, cleared after bake)

**Each annotation draws itself** via `draw(in:)`. Has `hitTest(point:threshold:)`, `move(dx:dy:)`, `isMovable`, `boundingRect`, `drawSelectionHighlight()`.

#### DetachedEditorWindowController — Standalone Editor
- Opens from overlay ("Open in Editor Window" button) or from thumbnail/pin "Edit" action
- Creates a titled, resizable NSWindow with OverlayView as content (isDetached=true)
- Transfers annotations with coordinate shift (overlay coords → image-relative 0,0 origin)
- `selectionRect == image bounds` — no coordinate offset
- Static `activeControllers[]` array keeps instances alive; switches activation policy to `.regular` when open, `.accessory` when all closed
- Implements `OverlayViewDelegate` for confirm/save/pin/OCR/upload/removeBackground

#### AnnotationToolbar — Layout & Button Definitions
- `ToolbarLayout` static class: `bottomButtons()` and `rightButtons()` factory methods
- `ToolbarButton` struct: action, sfSymbol, label, tooltip, rect, isSelected, isHovered, isPressed, tintColor, bgColor, hasContextMenu
- Theme: purple accent (`accentColor`), dark background, 32px buttons
- Context menus: right-click on buttons for sub-options (redact patterns, delay seconds, beautify styles)
- Tool enable/disable: reads `enabledTools` from UserDefaults, tracks `knownToolRawValues` to avoid re-enabling user-disabled tools on upgrade

#### RecordingEngine
- MP4 via AVAssetWriter + SCStream, GIF via GIFEncoder
- Configurable FPS (default 30, capped at 15 for GIF)
- Annotation mode: overlay stays visible during recording for live drawing
- Output to temp files in Application Support directory

#### ScrollCaptureController
- Monitors scroll events, captures strips at intervals
- SAD (Sum of Absolute Differences) template matching for sub-pixel registration
- Scroll throttle 0.25s minimum, settlement timer 0.4s after scroll ends
- Builds running stitched canvas, returns final tall CGImage

#### FloatingThumbnailController
- Appears on right edge after capture, auto-dismisses (configurable)
- Stack mode (multiple thumbnails) or replace mode (single)
- Quick actions: Copy, Save, Pin, Edit (opens editor), Upload
- Draggable (NSDraggingSource) to save to filesystem

#### PreferencesWindowController
- **General tab:** Hotkey, save path, copy sound, thumbnails, history size
- **Tools tab:** Per-tool enable/disable toggles
- **Recording tab:** Format (MP4/GIF), FPS, on-stop action

### Protocols

```
OverlayWindowControllerDelegate  — OverlayWindowController → AppDelegate
OverlayViewDelegate              — OverlayView → OverlayWindowController / DetachedEditorWindowController
PinWindowControllerDelegate      — PinWindowController → AppDelegate
```

### Undo/Redo

`UndoEntry` enum: `.added(Annotation)` and `.deleted(Annotation, Int)`. Stacks: `undoStack` / `redoStack`. Batch undo via `groupID` (e.g. auto-redact creates multiple annotations with same groupID, all undone together).

### Coordinate Systems
- **Overlay:** View coordinates = screen frame, bottom-left origin (AppKit)
- **Detached editor:** selectionRect == image bounds, origin at (padLeft, padBottom) within view
- **ScreenCaptureKit:** Top-left origin, needs conversion from AppKit bottom-left for recording crop rects
- **Annotation coords:** Always relative to the overlay/editor view — shifted when transferring between overlay and editor

### Persistence (UserDefaults)
- Drawing: `currentStrokeWidth`, `numberStrokeWidth`, `markerStrokeWidth`
- Hotkey: `hotkeyKeyCode`, `hotkeyModifiers`
- Output: `saveDirectory`, `autoCopyToClipboard`, `playCopySound`
- Selection: `lastSelectionRect`, `lastSelectionScreenFrame`, `rememberLastSelection`
- Thumbnails: `showFloatingThumbnail`, `thumbnailStacking`, `thumbnailAutoDismissSeconds`
- Image: `imageFormat` (png/jpeg), `imageQuality` (0.0–1.0)
- Recording: `recordingFormat` (mp4/gif), `recordingFPS`, `recordingOnStop`
- History: `historySize`
- Tools: `enabledTools`, `knownToolRawValues`
- Features: `imgbbAPIKey`, `beautifyEnabled`, `beautifyStyleIndex`, `pencilSmoothEnabled`, `loupeSize`, `translateTargetLang`

### Threading Model
- **Capture:** Async/await TaskGroup for concurrent multi-display capture
- **Recording:** SCStream output on background thread, main actor for state updates
- **Scroll capture:** Background throttle/settlement timers, serialized captureAndStitch
- **OCR:** VNImageRequestHandler on background thread, results to main
- **Upload:** URLSession background task
- **GIF:** Frame encoding on background thread
- **UI:** All drawing, state changes, and user interaction on main thread

## Features

### Core
- Multi-screen capture (one overlay per screen, concurrent ScreenCaptureKit calls)
- Rubber-band selection with 8-point resize handles
- Full-screen capture (single click without drag)
- Remember last selection rectangle

### Annotation Tools (17)
Pencil, Line, Arrow, Rectangle, Filled Rectangle, Ellipse, Marker/Highlighter, Text (rich formatting), Number (auto-incrementing), Pixelate, Blur, Measure (pixel ruler), Loupe (2x magnifier), Select & Edit, Translate Overlay, Crop (editor only), Color Sampler

### Output Actions
Copy to clipboard, Save to file (PNG/JPEG), Pin (floating always-on-top), OCR with translation (30+ languages), Upload to imgbb, Remove background (VNGenerateForegroundInstanceMaskRequest), Open in editor, Beautify (6 gradient styles)

### Advanced
- **Editor Window:** Standalone resizable window for post-capture editing, full annotation tools, zoom 0.1x–8x
- **Screen Recording:** MP4/GIF, annotation mode during recording, configurable FPS
- **Scroll Capture:** Automatic scroll detection + stitching via SAD matching
- **Auto-Redact:** Right-click filled rect → regex patterns (emails, phones, SSN, credit cards, IPs, AWS keys, bearer tokens)
- **Barcode/QR Detection:** Live Vision detection with decoded payload, open/copy actions
- **Floating Thumbnail:** Stackable, draggable, auto-dismiss, quick actions
- **Screenshot History:** Local storage with thumbnails, "Recent Captures" menu
- **Delay Capture:** Configurable countdown (3s, 5s, 10s)
- **Color Opacity:** Adjustable per annotation
- **Smooth Pencil Strokes:** Toggle in settings
- **Zoom:** 0.1x–8x, scroll/pinch, pan, clickable label to edit percentage

## Coding Conventions

- Pure AppKit, no SwiftUI (Apple frameworks: ScreenCaptureKit, Vision, CoreImage, AVFoundation + Sparkle for auto-updates)
- All overlay/drawing in `draw(_:)` overrides via Core Graphics / NSBezierPath
- Toolbars drawn inline in OverlayView (not separate NSPanel windows) — avoids z-order issues
- SF Symbols for toolbar icons
- Minimal allocations during mouse tracking (reuse paths, avoid per-mouseMoved object creation)
- `[weak self]` in all closures to avoid retain cycles
- Tear down overlay windows and images promptly after capture
- UserDefaults for all preferences (no Core Data, no plist files)
- Annotation is a class (reference type) for mutation during drag/resize — use `clone()` for safe copies
- `autoreleasepool` for overlay teardown to prevent memory spikes

## Build & Run

- Open `macshot.xcodeproj` in Xcode
- Build & Run (Cmd+R)
- Grant Screen Recording permission when prompted
- App appears as icon in menu bar (no dock icon)
- Click menu bar icon → "Capture Screen" or use global hotkey (default: Cmd+Shift+X)

## Releasing

When pushing a new version tag (e.g. `v2.6.0`):

1. **Add a CHANGELOG.md entry** for the new version — CI extracts it for GitHub Release notes.
2. **Tag and push:** `git tag v2.6.0 && git push origin main --tags`
3. CI handles the rest: build (with `MARKETING_VERSION` injected from the tag), sign, notarize, DMG, GitHub Release, Sparkle appcast, Homebrew cask update.

Note: `MARKETING_VERSION` in `project.pbxproj` is only used for local dev builds. CI always overrides it from the git tag.

