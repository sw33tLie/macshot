# macshot

Native macOS screenshot & annotation tool inspired by Flameshot. Built with Swift + AppKit. No Qt, no Electron.

## Project Setup

- **Language:** Swift 5.0
- **UI:** AppKit (all windows created in code, storyboard is minimal — just app entry + main menu)
- **Min Target:** macOS 12.3+ (Monterey)
- **Bundle ID:** com.sw33tlie.macshot.macshot
- **Sandbox:** Enabled (entitlements: network.client, files.user-selected.read-write, files.bookmarks.app-scope)
- **LSUIElement:** YES (menu bar only app, no dock icon — switches to `.regular` when editor windows are open)
- **Permissions:** Screen Recording (Info.plist has Privacy - Screen Capture Usage Description)
- **Xcode:** File system synchronized groups — just create .swift files in `macshot/` and Xcode picks them up automatically

## Architecture

Menu bar agent app. No main window. Global hotkey (Cmd+Shift+X) or menu bar click triggers screen capture → fullscreen overlay → selection → annotation → output.

### File Structure

```
macshot/
├── main.swift                          # App entry point
├── AppDelegate.swift                   # App lifecycle, status bar, hotkey, capture orchestration
│
├── Model/
│   └── Annotation.swift                # Data model + drawing for all annotation types
│
├── Capture/
│   ├── ScreenCaptureManager.swift      # Multi-screen capture via ScreenCaptureKit (async/await)
│   ├── RecordingEngine.swift           # Screen recording (MP4 via AVAssetWriter, GIF via GIFEncoder)
│   ├── ScrollCaptureController.swift   # Scroll capture with SAD-based stitching
│   └── GIFEncoder.swift               # Animated GIF from video frames
│
├── Services/
│   ├── ImageEncoder.swift              # PNG/JPEG/HEIC/WebP encoding, clipboard copy, resolution scaling
│   ├── BeautifyRenderer.swift          # Gradient frame / background beautification (linear + mesh gradients)
│   ├── AutoRedactor.swift              # PII regex detection + Vision OCR → redaction annotations
│   ├── BarcodeDetector.swift           # Async Vision barcode/QR scanning, badge drawing, hit-testing
│   ├── TranslationOverlay.swift        # OCR → translate → overlay annotations
│   ├── TranslationService.swift        # Google Translate API wrapper
│   ├── VisionOCR.swift                 # Vision text recognition request factory
│   ├── HotkeyManager.swift            # Global keyboard shortcut (Carbon RegisterEventHotKey)
│   ├── ScreenshotHistory.swift         # Local history in ~/Library/Application Support/
│   └── SaveDirectoryAccess.swift       # Security-scoped bookmark for save directory
│
├── Upload/
│   ├── ImgbbUploader.swift             # imgbb image upload
│   ├── GoogleDriveUploader.swift       # Google Drive OAuth2 upload
│   └── S3Uploader.swift               # S3-compatible upload
│
├── UI/
│   ├── Overlay/
│   │   ├── OverlayView.swift           # Base canvas: selection, drawing, annotation rendering, input routing
│   │   ├── OverlayView+Popovers.swift  # Popover factories + auto-redact/translate action helpers
│   │   ├── OverlayView+Recording.swift # Recording HUD, mouse highlight monitor
│   │   ├── OverlayView+ScrollCaptureHUD.swift  # Scroll capture progress bar + stop button
│   │   ├── OverlayView+WindowSnapping.swift    # Window detection + snap highlight drawing
│   │   ├── OverlayWindowController.swift       # One per screen: fullscreen borderless overlay window
│   │   └── ColorWheelRenderer.swift    # Radial color wheel for right-click quick color pick
│   │
│   ├── Editor/
│   │   ├── EditorView.swift            # OverlayView subclass: NSScrollView mode, no selection chrome
│   │   ├── DetachedEditorWindowController.swift  # Standalone editor window (resizable, titled)
│   │   ├── EditorTopBarView.swift      # NSView with crop, flip, zoom buttons
│   │   ├── CenteringClipView.swift     # NSClipView subclass that centers document when smaller than clip
│   │   └── VideoEditorWindowController.swift  # Standalone video editor (trim, export, upload)
│   │
│   ├── Toolbar/
│   │   ├── ToolbarDefinitions.swift    # ToolbarButtonAction enum, ToolbarButton struct, ToolbarLayout constants
│   │   ├── ToolbarButtonView.swift     # NSView for a single toolbar button (hover, press, selection states)
│   │   ├── ToolbarStripView.swift      # NSView container for horizontal/vertical button rows
│   │   └── ToolOptionsRowView.swift    # NSView-based tool options bar (sliders, segments, text formatting)
│   │
│   ├── Tools/
│   │   ├── AnnotationToolHandler.swift # AnnotationToolHandler + AnnotationCanvas protocols, shared helpers
│   │   ├── PencilToolHandler.swift     # Freeform draw with Chaikin smoothing
│   │   ├── MarkerToolHandler.swift     # Highlighter (semi-transparent wide stroke)
│   │   ├── LineToolHandler.swift       # Straight line with 45° snap
│   │   ├── ArrowToolHandler.swift      # Arrow with styles (single, thick, double, open, tail)
│   │   ├── RectangleToolHandler.swift  # Rectangle with corner radius, fill style, line style
│   │   ├── FilledRectangleToolHandler.swift  # Opaque filled rectangle (redact)
│   │   ├── EllipseToolHandler.swift    # Ellipse with fill style
│   │   ├── PixelateToolHandler.swift   # Pixelate region
│   │   ├── BlurToolHandler.swift       # Gaussian blur region
│   │   ├── LoupeToolHandler.swift      # Click-to-place 2x magnifier
│   │   ├── MeasureToolHandler.swift    # Pixel ruler with 45° snap
│   │   ├── NumberToolHandler.swift     # Auto-incrementing numbered circle
│   │   ├── StampToolHandler.swift      # Emoji/image stamp + StampEmojis data
│   │   └── TextEditingController.swift # Text tool: NSTextView lifecycle, formatting, commit, cancel
│   │
│   ├── Popover/
│   │   ├── PopoverHelper.swift         # Static helper for showing/dismissing NSPopovers
│   │   ├── ColorPickerView.swift       # Custom color picker: swatches, HSB gradient, opacity, custom slots
│   │   ├── ListPickerView.swift        # Reusable list picker with checkmark selection
│   │   ├── EmojiPickerView.swift       # Emoji grid with category tabs
│   │   └── GradientPickerView.swift    # Beautify gradient style swatch grid
│   │
│   └── Windows/
│       ├── PinWindowController.swift          # Floating always-on-top pinned screenshot
│       ├── FloatingThumbnailController.swift  # Auto-dismiss thumbnail after capture
│       ├── PreferencesWindowController.swift  # Settings: General, Tools, Recording tabs
│       ├── OCRResultController.swift          # Text recognition results window with translation
│       ├── HistoryOverlayController.swift     # Recent captures visual overlay panel
│       ├── UploadToastController.swift        # Upload progress/success toast
│       ├── RecordingControlView.swift         # Click-through recording control overlay
│       ├── RecordingToastView.swift           # Toast notification after recording completes
│       ├── CountdownView.swift                # Delay capture countdown display
│       └── PermissionOnboardingController.swift  # First-run permission guide
│
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

#### OverlayView — The Main Interaction Surface
The core canvas view. Handles selection state machine, annotation rendering, input routing, and toolbar positioning. Tool-specific creation/update/finish logic is delegated to `AnnotationToolHandler` implementations in `UI/Tools/`.

**State machine:** `idle` → `selecting` → `selected`

**Zoom system:** 0.1x–8x (min 1.0x in overlay, 0.1x in editor), scroll/pinch to zoom, pan while zoomed, clickable zoom label

**Toolbars:** Real NSView-based toolbar strips (`ToolbarStripView` + `ToolbarButtonView`) positioned by OverlayView. Tool-specific options in `ToolOptionsRowView` with real NSSlider/NSSegmentedControl/NSButton controls. Popovers use `NSPopover` via `PopoverHelper`.

**Editor mode (EditorView subclass):** `EditorView` is a subclass of `OverlayView` that overrides behavior via clean override points. Uses NSScrollView for zoom/pan/centering. The old `isDetached` flag is removed — use `isEditorMode` computed property instead.

**CRITICAL — Overlay vs Editor coordinate rules:**
- **Never use `bounds` for image-to-pixel mapping.** Always use `captureDrawRect` (returns `bounds` in overlay, `selectionRect` in editor).
- **Never use raw view-space points for annotation positions.** Always convert via `viewToCanvas()` first.
- **Never call `viewToCanvas()` on a point that's already in canvas space.** `startAnnotation(at:)` receives canvas-space points — don't double-convert inside it.
- **When positioning NSViews (e.g. NSTextView for text tool),** convert canvas coords back to view coords via `canvasToView()`.
- **`compositedImage()`** renders at `captureDrawRect.size`, not `bounds.size`.
- **`sourceImageBounds`** for pixelate/blur/loupe must be set to `captureDrawRect`, not `bounds`.
- **For Vision API region crops** (OCR, barcode, auto-redact), draw the screenshot at `captureDrawRect` size, not `bounds` size.
- **Cursor management** is fully imperative (no cursor rects) via `updateCursorForPoint()` + `mouseMoved`. Each window only sets cursors when the mouse is actually over it (prevents cross-window flicker on multi-monitor).

**Drawing pipeline in `draw(_:)`:**
1. Background: screenshot image (full-screen in overlay, centered in editor via NSScrollView)
2. Dark overlay mask (except inside selection) — skipped in editor
3. Selection rectangle with 8 resize handles — skipped in editor
4. Annotations rendered with cached composite when not actively drawing
5. Toolbars positioned (real NSView subviews, not drawn inline)
6. Zoom label (fades out)
7. Recording/scroll capture HUD overlays

#### Tool Handler Architecture
Each annotation tool's creation logic (start/update/finish) is extracted into an `AnnotationToolHandler` implementation. OverlayView dispatches through `toolHandlers[currentTool]` in `startAnnotation`, `updateAnnotation`, `finishAnnotation`.

**`AnnotationCanvas` protocol** — the interface tool handlers use to access OverlayView state (colors, stroke width, annotations, undo stack, snap guides, etc.) without coupling to the full class.

**`TextEditingCanvas` protocol** — additional interface for `TextEditingController` to access coordinate transforms and commit annotations.

Tools not extracted (handled directly in OverlayView): `select` (annotation interaction system), `colorSampler` (touches private color state), `crop` (editor-only image manipulation), `text` start/click detection (but all formatting/commit/cancel logic is in `TextEditingController`).

#### Annotation — Data Model + Drawing
Class (not struct) with `clone()` for safe copying. Lives in `Model/Annotation.swift`.

**Tools (AnnotationTool enum, 18 cases):**
```
pencil, line, arrow, rectangle, filledRectangle, ellipse, marker,
text, number, stamp, pixelate, blur, measure, loupe, select,
translateOverlay, crop, colorSampler
```

**Each annotation draws itself** via `draw(in:)`. Has `hitTest(point:threshold:)`, `move(dx:dy:)`, `isMovable`, `boundingRect`, `drawSelectionHighlight()`.

#### DetachedEditorWindowController — Standalone Editor
- Opens from overlay ("Open in Editor Window" button) or from thumbnail/pin "Edit" action
- Creates: NSScrollView → CenteringClipView → EditorView (documentView)
- Container view holds scroll view + EditorTopBarView
- `chromeParentView` set BEFORE `applySelection` so toolbars go in container (not document view)
- Static `activeControllers[]` array keeps instances alive; switches activation policy to `.regular` when open, `.accessory` when all closed

### Protocols

```
OverlayWindowControllerDelegate  — OverlayWindowController → AppDelegate
OverlayViewDelegate              — OverlayView → OverlayWindowController / DetachedEditorWindowController
PinWindowControllerDelegate      — PinWindowController → AppDelegate
AnnotationToolHandler            — Tool creation/update/finish lifecycle
AnnotationCanvas                 — OverlayView state interface for tool handlers
TextEditingCanvas                — Coordinate transforms + annotation storage for TextEditingController
```

### Undo/Redo

`UndoEntry` enum: `.added(Annotation)`, `.deleted(Annotation, Int)`, `.imageTransform(...)`. Stacks: `undoStack` / `redoStack`. Batch undo via `groupID` (e.g. auto-redact creates multiple annotations with same groupID, all undone together).

### Coordinate Systems
- **Overlay:** View coordinates = screen frame, bottom-left origin (AppKit)
- **Editor:** EditorView inside NSScrollView — `isInsideScrollView` makes all transforms identity. NSScrollView handles zoom/pan/centering.
- **ScreenCaptureKit:** Top-left origin, needs conversion from AppKit bottom-left for recording crop rects
- **Annotation coords:** Always relative to the overlay/editor view — shifted when transferring between overlay and editor

### Persistence (UserDefaults)
- Drawing: `currentStrokeWidth`, `numberStrokeWidth`, `markerStrokeWidth`
- Hotkey: `hotkeyKeyCode`, `hotkeyModifiers`
- Output: `saveDirectory`, `autoCopyToClipboard`, `playCopySound`
- Selection: `lastSelectionRect`, `lastSelectionScreenFrame`, `rememberLastSelection`
- Thumbnails: `showFloatingThumbnail`, `thumbnailStacking`, `thumbnailAutoDismissSeconds`
- Image: `imageFormat` (png/jpeg/heic/webp), `imageQuality` (0.0–1.0), `downscaleRetina` (bool)
- Recording: `recordingFormat` (mp4/gif), `recordingFPS`, `recordingOnStop`
- History: `historySize`
- Tools: `enabledTools`, `knownToolRawValues`
- Features: `imgbbAPIKey`, `beautifyEnabled`, `beautifyStyleIndex`, `beautifyMode`, `beautifyPadding`, `beautifyCornerRadius`, `beautifyShadowRadius`, `pencilSmoothEnabled`, `loupeSize`, `translateTargetLang`
- Styles: `currentLineStyle`, `currentArrowStyle`, `currentRectFillStyle`, `currentRectCornerRadius`
- Upload: `uploadProvider` (imgbb/gdrive), `googleDriveRefreshToken`, `uploadConfirmEnabled`

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

### Annotation Tools (18)
Pencil, Line, Arrow, Rectangle, Filled Rectangle, Ellipse, Marker/Highlighter, Text (rich formatting), Number (auto-incrementing), Stamp/Emoji, Pixelate, Blur, Measure (pixel ruler), Loupe (2x magnifier), Select & Edit, Translate Overlay, Crop (editor only), Color Sampler

- **Line styles:** Solid, dashed, dotted
- **Arrow styles:** Single, thick, double, open, tail
- **Annotation rotation:** Rotate shapes via handle, Shift to snap to 90°
- **Bend control points:** Draggable cubic bezier curve on lines and arrows
- **Stamp tool:** Place emoji or custom images, load from file

### Output Actions
Copy to clipboard, Save to file (PNG/JPEG/HEIC/WebP), Pin (floating always-on-top), OCR with translation (30+ languages), Upload to imgbb or Google Drive (OAuth2), Remove background (VNGenerateForegroundInstanceMaskRequest), Open in editor, Beautify (30 gradient styles including 7 mesh gradients on macOS 15+), Flip horizontal/vertical

### Advanced
- **Editor Window:** Standalone resizable window for post-capture editing, full annotation tools, zoom 0.1x–8x via NSScrollView
- **Video Editor:** Standalone video editor window for trimming, exporting, and uploading recorded videos
- **Screen Recording:** MP4/GIF, annotation mode during recording, configurable FPS (up to 120fps), mouse click highlighting, system audio capture
- **Scroll Capture:** Automatic scroll detection + stitching via SAD matching
- **Auto-Redact:** Right-click filled rect → regex patterns (emails, phones, SSN, credit cards, IPs, AWS keys, bearer tokens)
- **Barcode/QR Detection:** Live Vision detection with decoded payload, open/copy actions
- **Floating Thumbnail:** Stackable, draggable, auto-dismiss, quick actions
- **Screenshot History:** Local storage with thumbnails, "Recent Captures" menu, visual history overlay panel
- **Delay Capture:** Configurable countdown (3s, 5s, 10s)
- **Color Opacity:** Adjustable per annotation via custom color picker
- **Smooth Pencil Strokes:** Toggle in settings
- **Zoom:** 0.1x–8x, scroll/pinch, pan, clickable label to edit percentage
- **Sparkle Auto-Updates:** Automatic update checks via Sparkle framework
- **Permission Onboarding:** First-run guide for granting Screen Recording permission

## Coding Conventions

- Pure AppKit, no SwiftUI except `BeautifyRenderer` which uses SwiftUI `MeshGradient` + `ImageRenderer` for mesh gradient rendering (macOS 15+ only, guarded with `@available`)
- **Use proper AppKit components:** NSPopover for popovers, NSView subclasses for toolbar buttons and strips, NSSlider/NSSegmentedControl/NSButton for controls, NSScrollView for editor zoom/pan, NSTextView for text editing. Avoid reimplementing standard UI components with manual `draw()` + coordinate hit-testing.
- **Strict concurrency:** CI builds with Xcode 16+ and `-Owholemodule` which enforces strict Swift concurrency. Any code using `@MainActor`-isolated SwiftUI APIs (e.g. `ImageRenderer`) must itself be `@MainActor`. Always mark classes/functions that touch SwiftUI rendering with `@MainActor`. Calling `@MainActor`-isolated methods (e.g. on AppDelegate) from non-`@MainActor` classes requires `MainActor.assumeIsolated { }`. **Local Debug builds do NOT catch these errors.** Before tagging a release, always verify with a Release build: `xcodebuild -scheme macshot -configuration Release build 2>&1 | grep "error:"`
- **Tool handler pattern:** New annotation tools should implement `AnnotationToolHandler` protocol in `UI/Tools/`, not add switch cases to OverlayView. The handler's `start`/`update`/`finish` methods use `AnnotationCanvas` to access shared state.
- Apple frameworks: ScreenCaptureKit, Vision, CoreImage, AVFoundation + Sparkle for auto-updates + Swift-WebP for WebP encoding
- SF Symbols for toolbar icons
- Minimal allocations during mouse tracking (reuse paths, avoid per-mouseMoved object creation)
- `[weak self]` in all closures to avoid retain cycles
- Tear down overlay windows and images promptly after capture
- UserDefaults for all preferences (no Core Data, no plist files)
- Annotation is a class (reference type) for mutation during drag/resize — use `clone()` for safe copies. **When adding new properties to Annotation, update three places:** the property declaration, `clone()`, and `CodableAnnotation` in `AnnotationCodable.swift` (`toCodable` + `fromCodable`). The compiler won't catch missing fields — annotations will silently lose data on clone or history reload.
- **Keyboard shortcuts:** Always use `event.keyCode` (hardware-based, layout-independent) for Cmd+letter shortcuts — never `event.charactersIgnoringModifiers`, which returns localized characters and breaks on non-Latin layouts (Russian, Arabic, etc.). `charactersIgnoringModifiers` is only appropriate for user-configurable shortcut recording or number/symbol keys (`0`, `=`, `-`, etc.) that don't change across layouts. Common key codes: A=0, S=1, D=2, F=3, H=4, G=5, Z=6, X=7, C=8, V=9, B=11, Q=12, W=13, E=14, R=15, Y=16, T=17.
- `autoreleasepool` for overlay teardown to prevent memory spikes
- Extension files (`OverlayView+Feature.swift`) for self-contained feature code that accesses OverlayView state but is logically separate (recording overlays, scroll capture HUD, window snapping, popovers)
- **Light/dark mode:** The toolbar and popovers always use a dark background regardless of system appearance. `ToolOptionsRowView` and `PopoverHelper` force `NSAppearance(named: .darkAqua)` so system controls render with light text. Never use system-adaptive colors (`.labelColor`, `.secondaryLabelColor`) for text in toolbar/popover contexts without verifying contrast against the dark background. Always test new toolbar UI elements in both light and dark system appearance.
- **Focus management:** macshot is an `LSUIElement` (menu bar app) that temporarily shows windows. All focus return is handled by `AppDelegate.returnFocusIfNeeded()` — one centralized method. Rules:
  - `previousApp` is captured in `startCapture()` before the overlay steals focus. Cleared after single use.
  - `returnFocusIfNeeded()` checks for visible titled windows, switches to `.accessory` policy, activates `previousApp`. Falls back to `NSApp.hide(nil)` when `previousApp` is nil (editor/OCR/preferences close).
  - `dismissOverlays(refocusPreviousApp: true)` (default) calls `returnFocusIfNeeded()`. Pass `false` only when macshot creates floating panels immediately after (pin, upload toast, recording HUD).
  - **Critical pattern for pin/upload/OCR-window paths:** `returnFocusIfNeeded()` uses `NSApp.hide(nil)` as fallback, which hides ALL windows — including floating panels with `hidesOnDeactivate = false`. So any overlay dismiss that creates a floating panel afterward MUST: (1) save `previousApp` locally, (2) `dismissOverlays(refocusPreviousApp: false)`, (3) create the panel, (4) manually `app.activate(options: .activateIgnoringOtherApps)` on the saved app. See `overlayDidRequestPin` and `overlayDidRequestUpload` for the pattern.
  - Every window close (editor, video editor, OCR, preferences) calls `returnFocusIfNeeded()` — never inline `setActivationPolicy`/`activate` directly.
  - All floating panels (thumbnails, pins, upload toasts, HUD, overlays) must set `hidesOnDeactivate = false` so they survive app deactivation. Pin windows must use `orderFrontRegardless()` instead of `makeKeyAndOrderFront` to avoid activating macshot.
  - `NSApp.activate(options: .activateIgnoringOtherApps)` is the only reliable way to switch focus to another app — plain `activate()` and `NSApp.deactivate()` do not reliably transfer focus on macOS 26.
  - `NSApp.hide(nil)` reliably transfers focus (activates next app in line) but hides ALL windows — only safe as last resort when no floating panels are expected.

## Build & Run

- Open `macshot.xcodeproj` in Xcode
- Build & Run (Cmd+R)
- Grant Screen Recording permission when prompted
- App appears as icon in menu bar (no dock icon)
- Click menu bar icon → "Capture Screen" or use global hotkey (default: Cmd+Shift+X)

## Releasing

### Workflow: `.github/workflows/build-release.yml`

CI triggers on tag push (`v*.*.*` or `v*.*.*-beta.*`) or manual `workflow_dispatch`. The workflow builds, signs, notarizes, creates a DMG, updates Sparkle appcast, creates a GitHub Release, and (for stable only) updates Homebrew.

### Stable release

1. **Add a CHANGELOG.md entry** for the new version — CI extracts it for GitHub Release notes.
2. **Tag and push:** `git tag v3.8.0 && git push origin main --tags`
3. CI handles the rest: DMG, GitHub Release, appcast update (replaces all items with just the new stable), website version bump, Homebrew cask update.
4. Make sure tool version in the website page is updated too.

### Beta release

1. **Add a CHANGELOG.md entry** (e.g. `## [3.8.0-beta.3] - 2026-04-06`).
2. **Tag with `-beta.N` suffix:** `git tag v3.8.0-beta.3 && git push origin v3.8.0-beta.3`
3. CI auto-detects beta from the tag and:
   - Adds `<sparkle:channel>beta</sparkle:channel>` to the appcast item (invisible to stable users)
   - Preserves the existing stable item in the appcast
   - Marks the GitHub Release as **pre-release**
   - **Skips** Homebrew tap and cask updates
   - **Skips** website version update

Beta users opt in via Preferences > "Check for beta updates". This sets `allowedChannels(for:)` to `["beta"]` in `SPUUpdaterDelegate`.

### Sparkle versioning

- `sparkle:version` (what Sparkle compares) = `github.run_number` — a monotonically increasing integer per CI build. This avoids all semver/pre-release comparison issues.
- `sparkle:shortVersionString` (what the user sees) = the human-readable version from the tag (e.g. `3.8.0-beta.3`).
- `MARKETING_VERSION` = tag version (display). `CURRENT_PROJECT_VERSION` = run number (build number).
- The stable appcast item from older builds still uses the old version string (e.g. `3.7.0`) for `sparkle:version`. Sparkle's comparator parses `3.7.0` as `3` when compared to a plain integer, so any run number > 3 is seen as newer. This works.

### Appcast safety

- CI validates the generated appcast XML with `python3 ET.parse()` before committing. If invalid, the build fails and the broken XML never reaches users.
- Appcast is served from `https://raw.githubusercontent.com/sw33tLie/macshot/main/appcast.xml` (CDN-cached, ~5 min TTL).
- Stable item extraction uses `python3 xml.etree.ElementTree` with `ET.register_namespace('sparkle', ...)` to preserve the `sparkle:` prefix.

### Manual trigger (fallback)

If tag push doesn't trigger CI (e.g. after rapid tag create/delete), use:
```
gh workflow run build-release.yml --ref main -f tag=v3.8.0-beta.3
```
This dispatches from main (which has `workflow_dispatch` support) and reads the tag from the input parameter. The tag must already exist on the remote.

### Notes

- `MARKETING_VERSION` in `project.pbxproj` is only used for local dev builds. CI always overrides it.
- Never rapidly create/delete tags — GitHub throttles tag push events and may suppress triggers for 15-30 minutes.
- The workflow was renamed from `release.yml` to `build-release.yml`.
