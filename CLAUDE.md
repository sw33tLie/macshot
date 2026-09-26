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

## Build Variants

macshot has two release variants:

- **Normal:** product name `macshot`, bundle id `com.sw33tlie.macshot.macshot`, Sparkle feed `appcast.xml`, release asset `MacShot.dmg`.
- **Offline:** product name `macshot Offline`, bundle id `com.sw33tlie.macshot.offline`, Sparkle feed `appcast-offline.xml`, release asset `MacShot-Offline.dmg`.

The offline build is selected with the `OFFLINE` Swift compilation condition. Use `BuildVariant.isOffline` / `BuildVariant.displayName` for runtime variant checks and display names. Upload and cloud storage integrations must be compiled out of the offline build with `#if !OFFLINE`, including upload UI, upload shortcuts, upload settings, upload context menu items, and uploader implementations.

The release workflow builds both variants from the same tag. It patches the offline app's `SUFeedURL` to `appcast-offline.xml`, removes the Google OAuth URL scheme from the offline app, signs both apps, packages both DMGs, notarizes both DMGs, and writes both appcasts. Do not point the offline app at the normal appcast or vice versa; Sparkle updates must stay variant-specific so offline users never update into the normal app.

Beta handling is shared: beta items get `<sparkle:channel>beta</sparkle:channel>`, and users opt in through the existing "Check for beta updates" setting. Stable offline releases will appear to offline users through `appcast-offline.xml` once a stable offline item exists.

Homebrew status: beta releases skip Homebrew. Stable releases update the normal cask and generate `macshot-offline` in the personal tap. The official Homebrew cask remains normal-only unless a separate `macshot-offline` cask is submitted later.

## Architecture

Menu bar agent app. No main window. Global hotkey (Cmd+Shift+X) or menu bar click triggers screen capture → fullscreen overlay → selection → annotation → output.

### File Structure

```
macshot/
├── main.swift                          # App entry point
├── AppDelegate.swift                   # App lifecycle, status bar, hotkey, capture orchestration
│
├── Model/
│   ├── Annotation.swift                # Data model + drawing for all annotation types
│   └── LenientDecoding.swift           # Backward/forward-compatible Codable helpers
│
├── Capture/
│   ├── ScreenCaptureManager.swift      # Multi-screen capture via ScreenCaptureKit (async/await)
│   ├── RecordingEngine.swift           # Screen recording to durable MP4 originals
│   ├── ScrollCaptureController.swift   # Scroll capture with SAD-based stitching
│   ├── ScrollFrameAnalyzer.swift       # Pure pixel comparison: frozen header + scrollbar detection
│   ├── GIFExporter.swift              # Edited timeline → timestamped GIF frames
│   ├── GIFEncoder.swift               # Bounded-memory streaming GIF writer
│   ├── CursorTelemetry.swift          # Pointer/click/key data file format + media-clock view (CursorRecording)
│   ├── CursorTelemetryRecorder.swift  # Samples the pointer during a take (no permissions needed)
│   ├── CursorMotion.swift             # Spring smoothing, idle/typing hiding, click timing
│   ├── VideoSceneGeometry.swift       # Canvas/frame layout, camera path (zooms), auto-zoom planner
│   ├── VideoSceneRenderer.swift       # Per-frame Core Image scene: frame, camera, cursor, overlays, webcam
│   ├── VideoSceneBuilder.swift        # Main-actor snapshot builder: background art, sprites
│   ├── KeystrokeTimeline.swift        # Keystroke labels + caption segmentation/SRT
│   ├── VideoCameraRecorder.swift      # Separate webcam file aligned to the screen clock
│   ├── CameraPlacementTrack.swift     # Webcam bubble moves/resizes during a take, replayed by the editor
│   └── VideoCaptionTranscriber.swift  # On-device speech → caption words
│
├── Services/
│   ├── ImageEncoder.swift              # PNG/JPEG/HEIC/WebP encoding, clipboard copy, resolution scaling
│   ├── BeautifyRenderer.swift          # Gradient frame / background beautification (linear + mesh gradients)
│   ├── AutoRedactor.swift              # PII regex detection + Vision OCR → redaction annotations
│   ├── TranslationOverlay.swift        # OCR → translate → overlay annotations
│   ├── TranslationService.swift        # Google Translate API wrapper
│   ├── VisionOCR.swift                 # Vision text recognition request factory
│   ├── HotkeyManager.swift            # Global keyboard shortcut (Carbon RegisterEventHotKey)
│   ├── KeyboardShortcutMatcher.swift   # Layout-aware character matching for shortcuts
│   ├── ToolShortcutManager.swift       # Single-key overlay tool shortcuts
│   ├── EditorCommandShortcutManager.swift  # Configurable undo/redo chords
│   ├── FilenameFormatter.swift         # Filename templates ({date}, {window}, {random}, …)
│   ├── SettingsPortability.swift       # Settings export/import + the secret filter
│   ├── LanguageManager.swift           # Locale resolution + L("…") lookup
│   ├── ScreenshotHistory.swift         # Local history in ~/Library/Application Support/
│   └── SaveDirectoryAccess.swift       # Security-scoped bookmark for save directory
│
├── Upload/
│   ├── UploadPayload.swift             # Streamed upload bodies (chunking, incremental SHA256, multipart on disk)
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
│   │   ├── VideoEditorWindowController(+Export).swift  # Studio video editor window, actions, exports
│   │   └── Video/                      # Editor document, playback, planner, exporter, inspector, stage, timeline
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
│   │   ├── ScopedUndoTextView.swift    # NSTextView with view-owned undo history
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

### Video editor (Studio)

The video editor is built around `VideoEditorDocument` (one `VideoProject`: timeline edits plus the look — frame/background, pointer, zoom, keystrokes, camera, captions). Views observe it; they never keep copies. Undo is a stack of encoded project snapshots; group continuous interactions with `beginGesture()`/`endGesture()`. Projects autosave beside a recording (`<take>.project.json`) or in `VideoProjects/` for other files, and decode leniently.

- **One render path.** `VideoRenderPlanner` builds every composition (preview and all exports) and the compositor renders `VideoSceneSnapshot` through `VideoSceneRenderer`: censors in content space → crop and framed placement → camera over the whole canvas (with motion blur) → text, pointer, clicks, camera bubble, keystrokes and captions in output space. Preview only lowers the render scale. Don't add effects to one path only.
- **Recorded pointer data.** Every take writes `cursor.mstl` (`CursorTelemetry`) beside the MP4. Takes that open in the editor with "Editable pointer" hide the system cursor from ScreenCaptureKit and exclude the click/keystroke/webcam overlay windows; the editor redraws them. Any other destination keeps them in the pixels. Telemetry is host-clock based and anchored to the writer's first frame (`MP4WriterSession` `onSessionStart`); pauses are removed exactly like the writer removes them. Telemetry and camera failures never affect the screen recording.
- **Time-dependent motion is precomputed and pure.** Cursor smoothing (`CursorMotion`) and the camera path (`CameraPathBuilder`) are sampled deterministically so scrubbing, playback and export produce identical frames. Motion-blur averaging must weight alpha only (Core Image color matrices are unpremultiplied).
- **Webcam.** When the camera records separately, `VideoCompositionBuilder` adds its track in lockstep with every cut/speed/freeze piece.
- **Visual checks.** `scripts/probe-video-editor.sh` builds the real editor into an isolated app; with `-D VIDEO_EDITOR_PROBE` it accepts scripted commands (`PROBE_COMMANDS` file) and renders in-process snapshots, including the preview frame. `scripts/make-studio-fixture.swift` generates a synthetic recording with pointer data.

### Undo/Redo

`UndoEntry` enum: `.added(Annotation)`, `.deleted(Annotation, Int)`, `.imageTransform(...)`. Stacks: `undoStack` / `redoStack`. Batch undo via `groupID` (e.g. auto-redact creates multiple annotations with same groupID, all undone together).

**CRITICAL — transient `NSTextView` undo ownership:** `UndoManager` keeps undo-operation targets unowned. A disposable editable `NSTextView` that obtains the window's shared undo manager through the responder chain can therefore leave `_undoRedoTextOperation:` entries pointing at a deallocated view; the next Cmd+Z may crash in `_NSUndoStack popAndInvoke`. Every editable app-created text view with `allowsUndo = true` must use `ScopedUndoTextView` (or subclass it), never a plain `NSTextView`. Call `discardUndoHistory()` before removing and releasing an editing session. Read-only text views that cannot register editing actions are exempt. Do not move transient text editing back onto a window-level undo manager.

### Coordinate Systems
- **Overlay:** View coordinates = screen frame, bottom-left origin (AppKit)
- **Editor:** EditorView inside NSScrollView — `isInsideScrollView` makes all transforms identity. NSScrollView handles zoom/pan/centering.
- **ScreenCaptureKit:** Top-left origin, needs conversion from AppKit bottom-left for recording crop rects
- **Annotation coords:** Always relative to the overlay/editor view — shifted when transferring between overlay and editor

### Persistence (UserDefaults)
- Drawing: `currentStrokeWidth`, `numberStrokeWidth`, `markerStrokeWidth`
- Hotkey: `hotkeyKeyCode`, `hotkeyModifiers`
- Output: `saveDirectory`, `quickCaptureMode`, `copyPathAfterSave`, `playCopySound`
- Selection: `lastSelectionRect`, `lastSelectionScreenFrame`, `rememberLastSelection`
- Thumbnails: `showFloatingThumbnail`, `thumbnailStacking`, `thumbnailAutoDismissSeconds`
- Image: `imageFormat` (png/jpeg/heic/webp/avif), `imageQuality` (0.0–1.0), `downscaleRetina` (bool), `clipboardIncludesImageFormat` (bool, opt-in: adds the configured format ahead of PNG/TIFF on the clipboard)
- Recording: `recordingFormat` (mp4/gif), `recordingFPS`, `recordingOnStop`
- History: `historySize`
- Tools: `enabledTools`, `knownToolRawValues`
- Features: `imgbbAPIKey`, `beautifyEnabled`, `beautifyStyleIndex`, `beautifyMode`, `beautifyPadding`, `beautifyCornerRadius`, `beautifyShadowRadius`, `pencilSmoothEnabled`, `loupeSize`, `stampSize`, `translateTargetLang`
- Styles: `currentLineStyle`, `currentArrowStyle`, `currentRectFillStyle`, `currentRectCornerRadius`
- Upload: `uploadProvider` (imgbb/gdrive), `googleDriveRefreshToken`, `gdriveFolderName` (Drive destination folder, defaults to "macshot"), `uploadConfirmEnabled`

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
- Annotation is a class (reference type) for mutation during drag/resize — use `clone()` for safe copies. **When adding new properties to Annotation, update four places:** the property declaration, `clone()`, `CodableAnnotation` in `AnnotationCodable.swift` (the struct field, `toCodable`, `fromCodable`, and a line in its `init(from:)`), and the census in `macshotTests/AnnotationPersistenceTests.swift`. The compiler won't catch a missing field — annotations silently lose data on clone or history reload — but the census test will: it reflects over every stored property and fails naming the new one.
- **Persisted models must decode leniently.** Swift's synthesized `init(from:)` requires a key for every non-optional property *even when it has a default value*, so adding a field silently breaks every file written by an older build. Any `Codable` type that is written to disk or UserDefaults needs a hand-written `init(from:)` using `decode(_:or:)` / `decodeOptional(_:)` from `Model/LenientDecoding.swift`, and arrays of them should decode through `LenientArrayDecoder` so one corrupt entry doesn't discard the file. This applies to `CodableAnnotation`, `CaptureEditState`, `ScreenshotHistory.IndexEntry`, and anything new that joins them.
- **History cleanup is conservative.** Missing or salvaged indexes do not establish orphanhood. `HistoryFileCleanup` only reclaims old unreferenced thumbnails/previews using a captured cutoff; captures, raw images, annotations and edit state remain for recovery. Explicit retention/deletion owns those files. Index identifiers must remain UUIDs, extensions must be recognized image types, and duplicate rows must be removed before enforcing retention.
- **History writes are transactions.** `HistoryImageSnapshot` owns composited/raw pixels and serialized annotations before enqueueing. `HistoryStorage` serializes saves, deletion and retention; a new immutable revision becomes current only after atomic index publication. Do not publish unwritten rows or delete the previous revision before success. Resolve preview URLs on the main actor, decode bounded pixels in ImageIO on the worker, and discard obsolete preview completions. Quit drains pending history writes.
- **Reopen editable history as a unit.** Use `loadEditableCapture`; if an existing sidecar or annotation cannot be restored, use the flattened capture rather than exposing raw pixels with an omitted annotation/effect. `AnnotationSerializer` still supports lenient salvage for callers that explicitly want it. `SavedCaptureValidation` validates embedded PNG dimensions before decoding, bounds saved numeric settings, and rejects impossible canvas geometry. Keep the full capture available when editable data exceeds these limits. See `docs/history-recovery.md` for the revision layout and downgrade limitations.
- **History queues retain a bounded amount of snapshot data.** Admission counts pixel buffers and serialized sidecars, with defaults of 512 MiB and 32 pending saves. A single oversized capture may save alone. Report saturation through the normal failed-save completion and visible error; never silently drop a queued capture or replace a committed revision. Release reservations on both success and failure before invoking the caller's completion.
- **Screenshot clipboard is image data only.** Never put a file URL on the pasteboard for a screenshot: it points into the sandbox, and Teams, Photopea and RDP clients prefer it over the image data but can't read it (#309, #393). PNG and TIFF are always present; the opt-in configured format (#373) is added first, never instead.
- **Clipboard HTML is formatting-only.** Generate import markup through `ClipboardHTML` after local parsing with external entities disabled. Copy only supported tags and validated style values; never pass source markup, resource attributes, declarations or arbitrary CSS to AppKit's HTML importer. Apply rich-input byte limits before parsing and text limits before layout, preserving composed characters when truncating.
- **Editor saves keep their original state.** Capture the image, cloned annotations, edit state and editor revision together before showing a save panel or starting an asynchronous output. Save completion must not combine an older image with current annotations, overwrite an already submitted newer history edit, mark subsequent edits clean, or close the editor after failure.
- **Filenames are single components.** Both rendered templates and direct recording names use `FilenameSanitizer`. Template expansion is one pass: window titles containing `{date}` or `{random}` stay literal. Preserve complete Unicode characters while capping UTF-8 length, and sanitize again at the direct recording boundary.
- **Report failures the user can't otherwise see.** A capture that fails to save or a recording that produces no file used to disappear silently (a `#if DEBUG` log at most). Anything that can lose a user's capture must surface: `ImageSaveService.onFailure` is wired to `AppDelegate.showFailureToast(_:)` at launch, and the recording completion handler reports its error the same way. Never swallow such a failure into an ignored `false` completion.
- **Recording originals are durable.** `RecordingSessionStore` gives each take a unique Application Support folder. Do not delete or sweep these on editor close or failed export. `AtomicMediaSave` stages output on the destination volume and publishes it atomically; keep heavy copying off the main thread and preserve the old destination on failure.
- **Exports outlive their windows.** Register media exports, audio mixes and recording copies with `MediaExportCoordinator`. Retain their input/directory leases until the worker actually completes, including cancellation. Gate atomic publication with `MediaExportCancellation.beginPublication` so a completed save cannot be reported as cancelled. `ApplicationTerminationCoordinator` keeps the normal event loop running while work drains, then retries Quit; `terminateLater` stalled MainActor completions in the native macOS 27 probe.
- **Video sources stay stable.** Open through `VideoSourceSnapshot` and `PreparedVideoSource`; use the working `mediaURL` for reads and `originalURL` for names. A later save can replace the public file without changing the active timeline's input. Prepared assets and thumbnail callbacks retain the read lease. Clipboard URLs need their own published copy so closing the editor cannot remove their backing file. Only the snapshot service cleans temporary working folders, honoring live-reader locks; durable original backups are never part of that sweep.
- **Offline bitrate targets differ from capture.** Medium/Low MP4 exports use `VideoExportEncodingPlan`, with source metadata loaded during preparation. Do not apply live-recording bitrate minimums or estimate size by multiplying input bytes by a quality percentage. For comparable H.264 sources with near-uniform cadence, estimates use the same target settings and edited duration as export, including audio. Omit estimates for sparse or unknown cadence, different codecs, High and GIF; fallback encoder budgets are not size predictions. Keep file/track metadata reads out of editor drawing.
- **Video cadence is not the shortest sample.** Idle heartbeats and final tails produce variable timing. `VideoFrameCadence` stores the intended interval in MP4's supported software metadata field and performs a bounded background timing inspection for unmarked files. Cache that interval during preparation and reuse it for preview, rendering and bitrate targets; preserve it through audio mixing and MP4 exports. Do not derive rendering FPS from a single minimum interval or the average across long idle gaps.
- **GIF export streams.** Use `GIFExporter` with the processed timeline and an explicit output cadence. `GIFEncoder` consumes presentation timestamps and writes one ImageIO-encoded frame at a time, combining unchanged pixels into holds. Do not accumulate an animation in one ImageIO destination, decimate by guessed source FPS, or spool every frame into scratch PNGs.
- **Uploads stream, they don't buffer.** A recording is routinely larger than the memory the app can hold, so uploaders take an `UploadPayload` (`.file` for recordings, `.data` for encoded screenshots). `UploadPayload` chunks, hashes incrementally for SigV4, and `MultipartBodyWriter` writes request bodies straight to a temp file. Don't reintroduce `Data(contentsOf:)` on a recording.
- **Upload bodies and callbacks belong to one job.** Prepare `PreparedUploadBody` off the main actor, hash the bytes while writing that owned body, and retain it through every retry. Never reread the public source for a retry or put progress on a shared uploader property. `UploadJob` participates in the existing quit drain; completion owns source leases until the request finishes. Drive retries reuse one pre-generated file ID and one multipart body. Account/cache changes stay on the main actor, and stale responses must not restore signed-out credentials or folders. Verify requests with local fixtures, not live cloud uploads.
- **Keyboard shortcuts:** Character-based commands must go through `KeyboardShortcutMatcher`; do not compare raw letter key codes or read `charactersIgnoringModifiers` directly. The matcher follows the character produced by rearranged Latin layouts such as QWERTZ, AZERTY, and Dvorak, while falling back through the user's ASCII-capable layout for non-Latin input sources such as Russian or Arabic. Use `EditorCommandShortcutManager` for configurable Undo/Redo chords and `ToolShortcutManager` plus `KeyboardShortcutMatcher.toolCharacters(for:)` for single-key overlay tools. Raw `event.keyCode` checks are appropriate only for layout-independent non-character keys such as Escape, Return, Tab, Space, Delete, arrows, and function keys. Global Carbon hotkeys remain physical key-code bindings; translate them only for display with `KeyboardShortcutMatcher.currentLayoutCharacter(for:)`, and disable `NSMenuItem` automatic key-equivalent localization after applying an already-translated physical binding.
- `autoreleasepool` for overlay teardown to prevent memory spikes
- Extension files (`OverlayView+Feature.swift`) for self-contained feature code that accesses OverlayView state but is logically separate (recording overlays, scroll capture HUD, window snapping, popovers)
- **Light/dark mode:** The toolbar and popovers always use a dark background regardless of system appearance. `ToolOptionsRowView` and `PopoverHelper` force `NSAppearance(named: .darkAqua)` so system controls render with light text. Never use system-adaptive colors (`.labelColor`, `.secondaryLabelColor`) for text in toolbar/popover contexts without verifying contrast against the dark background. Always test new toolbar UI elements in both light and dark system appearance.
- **Focus management:** macshot is an `LSUIElement` (menu bar app) that temporarily shows windows. All focus return is handled by `AppDelegate.returnFocusIfNeeded()` — one centralized method. Rules:
  - `previousApp` is captured in `startCapture()` before the overlay steals focus. Cleared after single use.
  - `returnFocusIfNeeded()` checks for visible titled windows, switches to `.accessory` policy, activates `previousApp`. When `previousApp` is nil it activates the frontmost non-macshot app instead. It deliberately does **not** call `NSApp.hide(nil)`: that can suspend the Carbon event loop and break global hotkeys.
  - `dismissOverlays(refocusPreviousApp: true)` (default) calls `returnFocusIfNeeded()`. Pass `false` only when macshot creates floating panels immediately after (pin, upload toast, recording HUD).
  - **Pattern for pin/upload/OCR-window paths:** an overlay dismiss that creates a floating panel afterward should: (1) save `previousApp` locally, (2) `dismissOverlays(refocusPreviousApp: false)`, (3) create the panel, (4) manually `app.activate(options: .activateIgnoringOtherApps)` on the saved app. See `overlayDidRequestPin` and `overlayDidRequestUpload`. (This originally guarded against the `NSApp.hide(nil)` fallback, which no longer exists; the ordering still gives the panel a clean hand-off.)
  - Every window close (editor, video editor, OCR, preferences) calls `returnFocusIfNeeded()` — never inline `setActivationPolicy`/`activate` directly.
  - All floating panels (thumbnails, pins, upload toasts, HUD, overlays) must set `hidesOnDeactivate = false` so they survive app deactivation. Pin windows must use `orderFrontRegardless()` instead of `makeKeyAndOrderFront` to avoid activating macshot.
  - `NSApp.activate(options: .activateIgnoringOtherApps)` is the only reliable way to switch focus to another app — plain `activate()` and `NSApp.deactivate()` do not reliably transfer focus on macOS 26.
  - `NSApp.hide(nil)` transfers focus but hides ALL windows and can suspend the Carbon event loop that global hotkeys depend on — don't reintroduce it.

## Tests

- `scripts/run-tests.sh` runs everything; add `--offline` for the offline variant, and pass `ClassName` or `ClassName/testName` to narrow it. It reports failures and preserves the full log/result bundle on failure. Set `MACSHOT_KEEP_TEST_RESULTS=1` to preserve successful results too. Empty/all-skipped runs are errors.
- The `macshotTests` target compiles the app sources directly (a synchronized group over `macshot/`, minus `main.swift`), so there is **no host app**: tests run headless, with no Screen Recording permission and no window server dependency. `internal` symbols are reachable without `@testable import`; `private` ones are not.
- Shared helpers live in `macshotTests/TestSupport.swift`: `withDefaults` (isolated UserDefaults), `ImageProbe` (scale-independent fixture images + pixel probes — never build fixtures with `lockFocus`, it produces 2x buffers on Retina and 1x in CI), `TestKeyEvent` (synthesized `NSEvent`s), and `Reflect`/`FieldDescriber` (compare every stored property of a value at once).
- Logic that is worth testing but buried in a permission-gated class should be extracted rather than left untested — see `ScrollFrameAnalyzer` and `RecordingEngine.cropRect(for:displayBounds:)`.
- `.github/workflows/tests.yml` runs the suite plus a Release build of both variants on every push and PR. The Release build is what catches strict-concurrency errors that Debug builds let through.

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
