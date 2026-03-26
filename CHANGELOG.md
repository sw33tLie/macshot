# Changelog

## [3.2.6] - 2026-03-26

### Added
- **Window title in filename** — new preference (off by default) to include the focused window's title in saved screenshot filenames (e.g. `Screenshot 2026-03-26 at 14.30.00 — My Document.png`)
- **Enter key action preference** — new "Enter key action" setting in Preferences to choose whether pressing Enter saves to file or copies to clipboard. Previously this was labeled "Right-click action" and only affected right-click behavior.

### Changed
- **Enter key respects confirm action** — pressing Enter in the overlay now follows the "Enter key action" preference. If set to "Save to file", Enter saves directly to the configured folder instead of copying to clipboard. Cmd+C always copies.
- **Quick Capture + F key** — pressing F (full screen) in Quick Capture mode now immediately saves/copies instead of expanding the selection and showing toolbars
- **Removed right-click selection from overlay** — right-click no longer starts a quick-save selection in the capture overlay. Use the dedicated Quick Capture shortcut instead. Other right-click actions (color wheel, toolbar context menus, anchor points, color sampler copy) are unchanged.

### Fixed
- **Save to file on Enter** — fixed a bug where pressing Enter always copied to clipboard even when "Save to file" was selected in preferences

## [3.2.5] - 2026-03-26

### Added
- **Microphone recording** — record voice audio during screen recordings. New mic toggle button in the recording toolbar (off by default). Microphone permission is requested only when first enabled — users who don't need it are never prompted. Audio is written as a separate track in the MP4 file.
- **Multi-anchor lines & arrows** — right-click (or Control-click) any line or arrow annotation to add anchor points. Drag individual anchors to create complex curves through multiple waypoints. Smooth Catmull-Rom spline rendering through all points.
- **Share button** — new share button in the right toolbar opens the native macOS sharing menu (AirDrop, Messages, Mail, etc.)
- **Number format options** — number annotations now support four formats: numeric (1, 2, 3), uppercase Roman (I, II, III), uppercase letters (A, B, C), and lowercase letters (a, b, c). Start-at value adjustable via stepper in the options row.
- **"Right-click to add points" hint** — subtle hint text in the secondary toolbar when line or arrow tools are selected

### Changed
- **Loupe performance** — loupe annotations now use the raw screenshot instead of the composited image, eliminating O(n²) re-rendering lag when placing multiple loupes
- **Delay capture moved to menu bar** — the per-capture delay toolbar button has been removed. Delay is now a persistent setting in the menu bar only.

### Fixed
- **Sparkle auto-updates** — fixed CI signing pipeline that was re-signing Sparkle's XPC installer services with the app's sandbox entitlements, preventing the updater from writing to the app bundle. XPC services are now signed without sandbox entitlements as Sparkle requires.
- **Number tool crash** — fixed crash when switching to the number tool with alpha format and start-at value of 0. Input is now clamped and stepper minimum raised to 1.
- **Annotation bounding rect** — bounding rectangle now accounts for all anchor points and control points, fixing hit-testing and selection for complex curved annotations

## [3.2.3] - 2026-03-26

### Added
- **Pre-capture delay** — new "Capture Delay" submenu in the menu bar with None/3s/5s/10s/30s options. Applies to all capture and recording hotkeys. Countdown shown before screen freeze. Press Escape to cancel.
- **Record Screen auto-start** — when capture delay is set, Record Screen starts recording automatically after countdown (no manual click needed)
- **Control-click to copy color** — color sampler now supports Control+click as alternative to right-click for copying hex values (improves compatibility with BetterTouchTool and other gesture tools)

### Changed
- **Delay capture moved to menu bar** — the per-capture delay toolbar button has been removed. Delay is now a persistent setting in the menu bar, applying to all captures. Simpler UX, matches how other screenshot apps work.
- **Loupe performance** — loupe annotations now use the raw screenshot instead of the composited image, eliminating O(n²) re-rendering lag when placing multiple loupes
- **Removed C-to-copy shortcut** — color hex copy is now right-click only (or Control+click). C key is freed for future use.

### Fixed
- **Sparkle auto-updates from DMG** — fixed entitlements not expanding `$(PRODUCT_BUNDLE_IDENTIFIER)` in CI builds, which broke the XPC installer service. Auto-updates now work for DMG installs. Users on 3.2.2 or earlier need to manually reinstall once.

## [3.2.2] - 2026-03-26

### Added
- **Capture cursor setting** — new "Capture mouse cursor in screenshot" toggle in Preferences (off by default)
- **Editor reset zoom button** — new button in editor top bar (left of zoom %) to reset zoom and recenter image
- **Beautify in editor** — beautify preview now works in the editor window (previously overlay-only)

### Changed
- **Editor architecture refactor** — editor is now a proper `EditorView` subclass of `OverlayView` instead of branching via `isDetached` boolean. Cleaner code, fewer edge cases, shared annotation/toolbar code via inheritance.
- **Marker/pencil Shift constraint** — Shift now constrains to horizontal/vertical only (not 45°), locks direction for the entire stroke
- **"Add to My Colors" button removed** — redundant; color slots auto-save when using color sampler tool
- **Auto-save to color slots** — only happens when color sampler tool is active, not on every color pick
- **OCR Copy button** — now closes the OCR window after copying
- **OCR AI Search button** — now closes the OCR window after opening browser

### Fixed
- **Editor window coordinate system** — comprehensive fix for all tools in editor mode: text, loupe, pixelate, blur, color sampler, crop, stamp, auto-redact, beautify, and remove background now all work at correct positions
- **Editor crop tool** — crop selection, preview, and commit all use correct canvas coordinates; undo/redo properly restores image size and recenters
- **Editor zoom** — smooth zoom without random jumps or recentering; canvas offset freezes when zoomed to prevent fighting with zoom anchor
- **Editor window sizing** — window now accounts for max beautify padding/shadow to prevent overflow
- **Editor title bar cursor** — cursor no longer shows tool-specific icon over traffic lights and title bar
- **Beautify shadow bleed** — fixed raw screenshot content showing through shadow area in editor
- **Remove background in editor** — now shows floating thumbnail preview (same as overlay mode)
- **Marker cursor preview** — now visible when beautify mode is active
- **Crop preview with beautify** — crop selection overlay now visible when beautify mode is active

## [3.2.1] - 2026-03-25

### Fixed
- **Multi-monitor recording** — recording on a secondary display no longer captures the wrong screen. Display matching now uses `CGDirectDisplayID` instead of fragile coordinate comparison. Same fix applied to scroll capture.
- **Cursor flickering on toolbars** — eliminated cursor flicker (crosshair/arrow alternation) when hovering over toolbars in the overlay. Replaced AppKit cursor rect system with fully imperative cursor management that avoids cross-window conflicts on multi-monitor setups and with background editor windows.
- **Editor annotation coordinates** — annotations transferred to the editor window now render at the correct position. Replaced the old approach of shifting annotation coordinates in `draw()` with a pure rendering offset (`editorCanvasOffset`), eliminating coordinate drift.
- **Editor selection resize** — selection handle hit-testing is now disabled in the editor, preventing accidental resizing of the image canvas when clicking near edges.

## [3.2.0] - 2026-03-25

### Added
- **S3-compatible uploads** — upload screenshots and videos to AWS S3, Cloudflare R2, MinIO, DigitalOcean Spaces, Backblaze B2, and other S3-compatible services. Configure endpoint, credentials, bucket, and public URL in Preferences.
- **Quick Capture shortcut** (`Cmd+Shift+S`) — select area and instantly save/copy without the annotation toolbar. Same as right-click drag, but as a global hotkey.
- **Capture OCR shortcut** (`Cmd+Shift+T`) — select area and immediately extract text via OCR. No toolbar, straight to the OCR results window.
- **Space-to-reposition mid-drag** — hold Space while drawing any shape or selection to reposition it without changing its size. Standard design tool behavior (Photoshop, Figma, Sketch).
- **Save button quick-save** — left-click Save now instantly saves to the configured folder. Right-click for "Save As..." dialog. Context menu indicator triangle shown on button.
- **Hide menu bar icon** — new toggle in Preferences. Hotkeys still work. Re-launch macshot from Spotlight to restore the icon.
- **Shortcut clear buttons** — each keyboard shortcut in Preferences now has a "x" button to disable it. Field shows "None" when cleared.
- **Menu bar icons** — all status bar menu items now have SF Symbol icons.
- **Color sampler right-click to copy** — right-click with the eyedropper to copy hex value to clipboard instead of pressing C.
- **Color picker slot system** — custom color slots always have one selected. Any color you pick (swatch, gradient, or eyedropper) auto-saves to the selected slot. Slots auto-advance when using the eyedropper for rapid palette collection. Right-click a slot to clear it.
- **Color picker stays open** — clicking on the screenshot with the color picker open now samples the color and keeps the picker visible. Switching to the eyedropper tool also keeps the picker open.

### Changed
- **Menu bar icon size** — reduced from 26px to 22px to match other menu bar apps.
- **Upload toast redesign** — moved from bottom-right to top-center. Native macOS notification appearance with app icon, light/dark mode support, and "Open" button for upload links. Click anywhere to dismiss. Error messages now word-wrap instead of truncating.
- **Floating thumbnail hover** — auto-dismiss timer now pauses while the cursor is over the thumbnail. Timer resumes when the cursor leaves.
- **Video editor responsive layout** — buttons collapse to icon-only when the window is narrow, preventing overlap.

### Fixed
- **Dock icon lifecycle** — dock icon now appears when Preferences, Editor, or Video Editor windows are open, and hides when all are closed. Fixed a bug where closing the video editor didn't remove the dock icon.
- **Duplicate instances** — launching macshot while it's already running now activates the existing instance instead of starting a second one.
- **Space switching** — switching macOS spaces now automatically dismisses the capture overlay.
- **OCR window Cmd+W** — the OCR results window can now be closed with Cmd+W.
- **Upload confirmation dialog** — now shows the correct provider name ("Upload to S3?" / "Upload to Google Drive?" / "Upload to imgbb?") based on the selected provider.
- **Editor tall image scrolling** — tall screenshots (e.g. from scroll capture) can now be scrolled at 1x zoom in the editor. Previously required zooming in first.
- **Zoom position preservation** — zooming back to 100% in the editor no longer resets the scroll position.
- **Space key beep** — holding Space to reposition no longer produces system beep sounds from key repeat.

## [3.1.0] - 2026-03-24

### Added
- **App Sandbox** — macshot is now fully sandboxed with minimal entitlements (network client, user-selected files, bookmarks). Improved security posture.
- **macOS 12.3+ support** — minimum deployment target lowered from macOS 14.0 to macOS 12.3 (Monterey). Features unavailable on older versions gracefully degrade:
  - Background removal requires macOS 14+
  - Launch at login requires macOS 13+
  - Mesh gradients require macOS 15+
  - System audio recording requires macOS 13+
- **Google AI Search in OCR** — new button in OCR results window to search extracted text directly in Google AI mode.
- **Error toast improvements** — upload error messages now word-wrap instead of truncating, with expanded toast height.
- **Video editor error colors** — errors now display in red instead of green.

### Changed
- **Google Drive OAuth** — replaced loopback HTTP server with ASWebAuthenticationSession and a new iOS-type OAuth client. More secure, sandbox-compatible, no local server socket.
- **Screen capture engine** — replaced SCScreenshotManager (macOS 14+) with SCStream-based single-frame capture compatible with macOS 12.3+.
- **Modernized image rendering** — replaced all deprecated `lockFocus()`/`unlockFocus()` calls (~32 occurrences) with `NSImage(size:flipped:drawingHandler:)`.
- **Recording output** — recordings now save to temp directory; final export via video editor Save button.
- **Save directory** — now uses security-scoped bookmarks for sandbox compatibility. Save directory preference persists across launches.

### Fixed
- **Video recording in sandbox** — recordings were failing because security-scoped access was released before the video editor could open the file.
- **GIFEncoder thread safety** — added locking to prevent data races on frame counters.
- **Force unwrap crashes** — replaced `NSScreen.main!` with safe fallbacks.

### Breaking Changes
- **Google Drive:** You will need to re-sign in to Google Drive after updating. The OAuth client has changed.
- **Screenshot history:** Local screenshot history will be cleared on first launch due to sandbox container migration. New screenshots will be saved normally.
- **Save directory:** You may need to re-select your custom save directory in Preferences after updating.

## [3.0.8] - 2026-03-24

### Added
- **Invert Colors** — new toolbar button to invert colors in the selected region. Apply twice to revert. Supports undo. Can be disabled in Preferences → Tools.
- **Mouse wheel zoom** — scroll wheel now zooms in/out without holding Cmd (trackpad behavior unchanged).

### Fixed
- **First click ignored on slower Macs** — overlay now accepts clicks immediately via `acceptsFirstMouse`, fixing a race condition where the first selection drag was dropped on Intel Macs or when app activation was slow.
- **Blurry captures on mixed-DPI setups** — screenshots from a 1x external monitor were being interpolation-upscaled to 2x when a Retina display was also connected. Output now matches the source display's native pixel density.

## [3.0.7] - 2026-03-24

### Added
- **Mesh gradients** — 7 new organic, multi-directional gradient backgrounds using SwiftUI MeshGradient (macOS 15+ only, hidden on macOS 14). Shown first in the gradient picker.
- **Beautify on/off toggle** — dedicated toggle switch in the beautify options row to enable/disable the effect independently from the tool.
- **Beautify active indicator** — sparkles icon turns gold when the beautify effect is enabled, visible even when using other tools.

### Improved
- **Beautify is now a proper tool mode** — clicking the sparkles button deselects the current drawing tool and shows the beautify options row. No more confusing 3-click toggle cycle.
- **Gradient picker hit area** — the dropdown triangle next to the gradient swatch is now clickable to open/close the picker.
- **Gradient picker cursor** — arrow cursor over the expanded gradient dropdown instead of crosshair.

### Fixed
- **Crosshair cursor stuck after cancel** — cursor now explicitly resets to arrow when dismissing the overlay, preventing stale crosshair on desktop/fullscreen apps.
- **Loupe/stamp cursor in beautify mode** — loupe preview and stamp cursor no longer persist when switching to beautify mode.

### Removed
- 5 duplicate gradient styles (Warm, Arctic, Mint, Charcoal, Steel) that were too similar to existing ones.

## [3.0.6] - 2026-03-23

### Fixed
- **Credit card auto-redact** — significantly improved detection of credit card numbers in OCR text. Handles Amex (4-6-5) format, OCR artifacts (฿, @, : appended to digit groups), and numbers split across multiple OCR text blocks. Uses spatial grouping to detect horizontally adjacent digit groups on the same row and redacts them as a card number.

## [3.0.5] - 2026-03-23

### Added
- **Annotation rotation** — shapes (rectangle, ellipse, stamp, text, number, pixelate, blur) can be rotated via a rotation handle above the selection box. Hold Shift to snap to 90° steps. Works in both Select tool and hover-to-move (quick edit) mode.
- **Stamp tool shortcut** — press `G` to switch to the stamp/emoji tool.
- **About tab** — Preferences now has an About tab showing version, description, author, and GitHub link.
- **Redact button hover/press states** — "Blur All Text" and "Auto-Redact PII" buttons now visually respond to hover and click.

### Improved
- **Beautify output** — removed outer background radius to eliminate subpixel gap artifacts on exported images. Gradient fills edge-to-edge.
- **Thick arrow smoothness** — increased curve sampling from 24 to 64 points for smoother bends. Shape scales down proportionally when short.
- **Thick arrow hit test** — uses distance-to-curve instead of bounding rect for more accurate hover/click detection.
- **Rotation handle UX** — arrow cursor over handle, icon centered in circle, handle reachable in quick edit mode.
- **Menu bar order** — "Show History Panel" moved below "Recent Captures" for logical grouping.

### Fixed
- **Resize handles after rotation** — click point is inverse-rotated into annotation's local space so handles work correctly at any rotation angle.
- **Rotation direction** — dragging the handle clockwise now rotates the shape clockwise (was inverted).
- **Debug logging** — all print/NSLog statements wrapped in `#if DEBUG`.
- **Dead code** — removed unused `showRecordingCompletedToast` function.
- **README** — updated beautify style count (28), added global hotkeys table, added stamp shortcut.

## [3.0.4] - 2026-03-22

### Added
- **System audio recording** — toggle in the recording toolbar to capture system audio alongside screen video. Off by default. Recorded as AAC 48kHz stereo in MP4. macshot's own sounds are excluded. The mute toggle in the video editor can strip audio on export.
- **120fps recording** — added 120fps option for MP4 recording on supported displays (ProMotion).
- **GIF FPS cap in preferences** — when GIF format is selected, the FPS dropdown shows only 5/10/15fps options instead of the full range.
- **Upload progress percentage** — Google Drive uploads in the video editor now show real-time progress ("Uploading to Drive... 47%").
- **Video resolution display** — video editor info bar now shows pixel dimensions (e.g. "1920×1080") alongside format, file size, and FPS.
- **GIF playback timeline** — GIF files in the video editor now have a moving playhead and time labels matching the MP4 experience.

### Improved
- **Recording toolbar icons** — screenshot mode shows a camera icon (video.fill) for "switch to record mode", recording mode shows a red circle (record.circle) for "start recording", and a red square for "stop". Clearer than the previous play/stop icons.
- **Beautify rounded corners** — shadow is now rendered via transparency layer on the image itself, eliminating the white corner artifacts and edge lines from the previous shadow fill approach.
- **Stamp preview suppressed during recording** — emoji cursor preview no longer follows the mouse when in recording mode.
- **Auto-select first emoji** — switching to the stamp tool automatically selects the first emoji instead of showing an error. Highlight tracking is now reliable across all selection methods.

### Fixed
- **Recording duration shows hours** — fixed audio track causing the MP4 file to report a duration of hundreds of hours. The session now starts at the first video frame's timestamp so audio and video are properly aligned.
- **Video editor duration** — uses video track duration instead of asset duration, so audio track length doesn't inflate the timeline.
- **Video playback starts from trim start** — play button now always starts from trim start if the playhead is outside the trimmed range.
- **GIF editor window sizing** — GIF editor window no longer expands to fill the screen. NSImageView compression resistance set to low so it respects the window size.

## [3.0.3] - 2026-03-22

### Added
- **Video editor window** — after recording stops, a dedicated editor window opens with video playback, a trim timeline with draggable start/end handles, and action buttons: Play/Pause (Space bar), Save, Upload to Google Drive, Reveal in Finder, Copy Path. Trim handles let you cut the beginning and end of the video before exporting.
- **Mute audio toggle** — speaker icon in the video editor strips audio from exports when enabled.
- **Google Drive integration** — upload screenshots and videos directly to your Google Drive. Sign in via OAuth2 in Preferences → Uploads. Files are stored in a private "macshot" folder. Token refresh is automatic — sign in once, stay signed in. Supports both images (PNG) and videos (MP4/GIF).
- **Upload provider selector** — choose between imgbb (images only) and Google Drive (images + videos) in Preferences → Uploads.
- **Redesigned Uploads tab** — provider selector, Google Drive sign-in/sign-out, imgbb API key, and upload history all in one tab.

### Fixed
- **Upload confirm dialog** — now shows "Upload to Google Drive?" when Drive is the selected provider instead of always showing imgbb.
- **Upload toast delete button** — "Delete from server" button is now hidden for Google Drive uploads (which have no delete URL).
- **Video playhead clamping** — the playhead circle no longer goes past the timeline edges near the beginning/end.
- **Video trim playback** — play always starts from trim start (not video start) and resets to exact trim start position with zero-tolerance seek.
- **Keychain prompts** — replaced Keychain token storage with file-based storage in Application Support to eliminate repeated "confidential information" prompts on rebuild/update.

## [3.0.2] - 2026-03-20

### Added
- **History overlay** — press `Cmd+Shift+H` (or "Show History" from menu bar) to see all recent captures as a full-screen card grid. Click any card to copy it to clipboard. ESC or click outside to dismiss. Hotkey configurable in Preferences.
- **Horizontal scroll capture** — scroll capture now auto-detects horizontal scrolling. On the first scroll, the direction (vertical or horizontal) is locked for the session. Horizontal scrolls stitch content left-to-right or right-to-left.

### Fixed
- **Shift + snap guide conflict** — holding Shift while drawing constrained shapes (straight lines, 45° angles, perfect squares) no longer gets nudged by snap alignment guides. Shift constraint now takes priority.
- **ESC in recording mode (Record Screen)** — pressing ESC before starting capture now correctly closes the overlay. The recording control window activates macshot so it can receive keyboard events.
- **Stop recording requires two clicks** — the recording control window now accepts the first mouse click immediately (`acceptsFirstMouse`) instead of consuming it for window activation.

## [3.0.1] - 2026-03-20

### Added
- **Text box with visible bounds** — text annotations now show a resizable dashed border while editing. Drag any of the 8 handles to resize the box; text automatically reflows to fit the new width.
- **Text alignment** — left, center, and right alignment buttons in the text secondary toolbar. Applied live while editing.
- **Click to re-edit text** — with the text tool active, clicking on an existing text annotation opens it for editing with all formatting restored (font, size, style, alignment, fill, outline). Cancel (ESC) restores the original.
- **Text background & outline** — "Fill" and "Outline" toggle buttons in the text secondary toolbar. Left-click toggles on/off, right-click opens the full color picker to choose the color. Both render as a rounded pill behind/around the text, visible live during editing.
- **Measure unit toggle** — px/pt segment control in the measure tool options row. Switch between pixel values (Retina-scaled) and point values (1:1 with design tools). Persisted across sessions.

### Fixed
- **Color picker behind text** — when opening the color picker for text Fill/Outline, the text view is temporarily hidden so the picker is fully visible. Text content is rendered manually in its place.
- **Text box doesn't expand on newline** — the dashed border and resize handles now update immediately when pressing Enter to add new lines.
- **Thick arrow corners** — all 3 corners of the thick arrow's triangle head are now consistently rounded using quadratic bezier curves through each corner point.

## [3.0.0] - 2026-03-20

### Added
- **Stamp / Emoji tool** — place emojis and images on your screenshots. 21 common emojis in the quick bar, a categorized emoji picker with 5 tabs (Faces, Hands, Symbols, Objects, Flags) and 100+ emojis, plus a "Load Image" button to stamp any PNG/JPEG. Stamps are placed at click position, movable and resizable with the standard 8-handle box. A semi-transparent preview follows the cursor before placement.
- **Arrow styles** — 5 arrow head styles selectable in the secondary toolbar: single (default), thick/banner (tapered solid shape), double-headed, open/chevron, and tail (circle at start). Persisted across sessions.
- **Shape fill modes** — rectangle and ellipse tools now have 3 fill modes in the secondary toolbar: stroke only, stroke + semi-transparent fill, and solid fill. Respects color opacity. Replaces the separate "Filled Rectangle" tool.
- **Record Area / Record Screen** — "Record Screen" renamed to "Record Area" (select region to record). New "Record Screen" opens the recording UI with the full screen already selected, ready to press play.
- **Mouse click highlights** — toggle in the recording toolbar to show expanding yellow rings at click positions during screen recording.

### Improved
- **Arrow scaling** — arrowheads now scale down proportionally when the arrow is short, preventing the oversized head problem at the start of a drag.
- **Editor top bar icons** — crop, flip horizontal, and flip vertical buttons now use the same white-tinted SF Symbol style as the main toolbar (was using default system coloring that looked bad on dark backgrounds).
- **Secondary toolbar positioning** — the options row now flips above the main toolbar when it would go off-screen (fixes full-screen selection clipping).
- **Recording mode transition** — clicking the Record button now properly enters pass-through mode: hides the bottom toolbar and options row, activates the window underneath for interaction, and shows the recording control panel. Previously the bottom toolbar stayed visible and drawing was still possible.
- **Recording control window cleanup** — the recording control panel is now properly dismissed when recording stops (previously could get orphaned and stuck on screen).
- **ESC in recording mode** — pressing ESC before starting capture now correctly closes the overlay. The recording control window accepts keyboard focus for this.
- **Paste in text tool** — Cmd+V, Cmd+C, Cmd+X, Cmd+A, and Cmd+Z now work correctly while editing text annotations.

### Fixed
- **`isCapturingVideo` not reset** — recording state flag was never cleared in `reset()`, breaking state machine invariants.
- **State mutation in draw()** — mouse highlight pruning was happening inside `draw(_:)`, violating AppKit's drawing contract. Moved to async callback.
- **Mouse highlight position** — click highlights now use the actual event location instead of a potentially stale `NSEvent.mouseLocation`.

### Removed
- **Filled Rectangle tool** — merged into the Rectangle tool with a fill mode selector (stroke / stroke+fill / fill).
- **Keystroke overlay** — removed the "Show Keystrokes" recording feature.
- **Dead code** — removed unreachable record options picker code.

## [2.9.0] - 2026-03-19

### Added
- **Snap alignment guides** — when drawing or moving annotations, edges and centers snap to the selection midlines and existing annotation edges/centers. Cyan dashed guide lines appear at snap points. Toggleable in Preferences (on by default).
- **Auto-redact in blur/pixelate tools** — auto-redact PII and "redact all text" buttons are now in the blur/pixelate options row (removed from right toolbar). Redactions use the active tool's style (blur or pixelate) instead of always using filled rectangles.
- **Redact all text** — new button in blur/pixelate options row that detects and redacts all text in the selection, not just PII patterns.
- **Dotted rectangle corner dots** — dotted-style rectangles now always have a dot at every corner with evenly-spaced dots per side, instead of the previous uneven pattern.
- **Custom cursors** — pencil tool shows a pen cursor; select/move tool shows a 4-arrow move cursor only when hovering over movable annotations (arrow cursor elsewhere). Both cursors have white fill with dark outline for visibility on any background.
- **Shift-constrain on resize** — holding Shift while resizing existing annotations constrains lines/arrows/measure to 45° angles and rectangles/ellipses to squares/circles.

### Improved
- **Pencil hover-to-move removed** — the pencil tool no longer shows edit controls when hovering near existing annotations, preventing accidental moves when drawing close to existing strokes.
- **Redact type dropdown toggle** — clicking the types dropdown when already open now properly closes it.
- **Font picker** — hover highlights items in the dropdown; selecting a font no longer commits/deselects the active text field.
- **Editor right toolbar position** — no longer overlaps the top bar.
- **Bold/italic on system font** — now works correctly with SF Pro via font descriptor traits.
- **Number circle sizing** — all stroke width steps produce visibly different sizes.
- **Number text contrast** — black text on light fill colors for readability.
- **Crop preview** — shows dimmed overlay, white border, and rule-of-thirds grid while dragging.
- **Loupe and color sampler in beautify mode** — previews now render on top of the beautify gradient.
- **Snap guides in beautify mode** — guide lines render on top of the beautify preview.

## [2.8.1] - 2026-03-18

### Fixed
- **WebP encoding crash** — fixed crash when copying or saving as WebP. The encoder was using the wrong pixel format (RGBA) for ScreenCaptureKit images (BGRA). Now uses NSImage-based encoding which handles format conversion automatically.
- **Swift-WebP compatibility** — pinned to v0.5.0 for Xcode 16.4 (Swift 6.1) compatibility. v0.6.1 requires Swift tools 6.2.

## [2.8.0] - 2026-03-18

### Added
- **Editor top bar** — fixed full-width bar at the top of the editor window with pixel dimensions display, crop button, flip horizontal/vertical buttons, and zoom level indicator.
- **Flip image** — flip the screenshot horizontally or vertically in the editor. All annotations (including freeform strokes and control points) are mirrored to match. Fully undoable.
- **Undoable crop** — cropping in the editor now saves the previous image state, so Cmd+Z restores the full uncropped image.
- **Crop selection preview** — dragging a crop area now shows a live preview with dimmed overlay outside the selection, a white border, and rule-of-thirds grid lines.
- **Number pointer cone** — click-and-drag with the number tool to create a triangular pointer extending from the numbered circle toward where you release. Single-click still places a plain number. Great for pointing numbers at specific areas.
- **Auto-measure** — with the measure tool selected, hold `1` to preview a vertical measurement or `2` for horizontal. The ruler scans outward from the cursor until the pixel color changes, automatically measuring the element you're pointing at. Release to commit, fully undoable.
- **Font picker hover highlight** — hovering over fonts in the dropdown now highlights the item and brightens the text.

### Improved
- **Number circle sizing** — all 7 stroke width steps now produce visibly different circle sizes (was stuck at the same size for steps 1-3).
- **Number text contrast** — text inside number circles is now black for light fill colors (white, yellow, etc.) instead of always white.
- **Bold/italic on system font** — bold and italic buttons now work correctly with the System font (SF Pro). Previously they had no effect because NSFontManager can't convert system font traits; now uses font descriptor traits directly.
- **Font selection preserves text focus** — clicking a font in the dropdown no longer commits/deselects the active text field. The font change applies immediately to the current text.
- **Editor bottom toolbar spacing** — the bottom toolbar is now raised when the secondary options row is visible, so it no longer clips off-screen.
- **Editor right toolbar position** — the right toolbar now sits below the top bar instead of overlapping it.

### Fixed
- **Loupe preview in beautify mode** — the loupe live preview was hidden behind the beautify gradient overlay; now redrawn on top.
- **Text formatting commits text** — clicking bold/italic/underline/strikethrough no longer finalizes the active text field before applying the change.
- **Corner radius slider label overlap** — increased gap between the slider handle and value label.
- **Stroke width slider label overlap** — increased gap between the slider knob and "20px" label.

## [2.7.1] - 2026-03-18

### Added
- **Redesigned color picker** — modern popup with always-visible HSB gradient, brightness slider, hex color display, and consistent slider thumbs. Preset colors reduced to 12 essential system colors for a cleaner layout.
- **Custom color palette** — 7 saveable color slots that persist across app restarts. Click an empty slot to save the current color, right-click any slot to replace it with the current color (or clear it if it already matches). "Add to My Colors" button at the bottom for quick saving.
- **Color sampler sets drawing color** — clicking with the color sampler (eyedropper) tool now sets the current drawing color to the sampled pixel, in addition to the existing C-to-copy-hex shortcut.

### Fixed
- **Stroke width slider label overlap** — the "20px" label no longer overlaps with the slider knob on the last step.
- **Crosshair cursor over color picker** — the cursor now correctly switches to an arrow when hovering over the color picker popup.

## [2.7.0] - 2026-03-18

### Added
- **HEIC format** — save screenshots as HEIC (High Efficiency Image Coding) for ~50% smaller files than JPEG at the same visual quality; uses macOS native encoding via CGImageDestination.
- **WebP format** — save screenshots as WebP for ~25-35% smaller files than JPEG; powered by [Swift-WebP](https://github.com/ainame/Swift-WebP) (libwebp wrapper).
- **Downscale Retina (1x) option** — new "Save at standard resolution (1x)" checkbox in Preferences → Output. Halves pixel dimensions on Retina displays, producing ~4x smaller files. Useful when sharing on Slack, docs, or the web where full Retina resolution is overkill.
- **sRGB color profile embedding** — new "Embed sRGB color profile" checkbox in Preferences → Output (on by default). Ensures consistent colors when screenshots are viewed on different displays or transferred between machines.

### Improved
- **Clipboard copy performance** — eliminated redundant double-encoding (was generating TIFF twice plus the configured format). Now converts once and writes only the configured format to the pasteboard. For a full-screen Retina capture this removes ~30 MB of unnecessary TIFF data from the copy pipeline.
- **Dropped TIFF from clipboard** — the pasteboard no longer includes an uncompressed TIFF representation alongside the configured format. Modern macOS apps all read PNG/JPEG natively; removing TIFF significantly speeds up Cmd+C. HEIC and WebP clipboard copies include a PNG fallback for compatibility.
- **Capture sound caching** — all four code paths that played the capture sound were creating new NSSound objects from disk on every call. Consolidated into a single shared static instance (`AppDelegate.captureSound`) reused everywhere. CoreAudio is pre-warmed at app launch to eliminate the ~1s delay on the first capture after idle.
- **Drag-to-save format** — dragging a floating thumbnail to Finder now saves in the configured format (was hardcoded to PNG).
- **Quality slider scope** — the quality slider in Preferences now applies to JPEG, HEIC, and WebP (was JPEG-only). Disabled for PNG (always lossless).
- **History pixel dimensions** — the "Recent Captures" menu now shows correct pixel dimensions when the Retina downscale option is enabled.

## [2.6.0] - 2026-03-17

### Added
- **Font family picker** — text tool now has a font dropdown in the secondary toolbar with 22 curated typefaces (System, Helvetica Neue, Arial, Avenir Next, Futura, Georgia, and more), each rendered in its own font for a live preview.
- **Text settings in secondary toolbar** — bold, italic, underline, strikethrough, font size, and cancel/confirm controls are now drawn inline in the tool options row, replacing the old floating control bar.

### Improved
- **Beautify gradients redesigned** — 18 new gradient styles (up from 12) organized in 6 rows: warm, blues, pink/purple, greens/nature, dark/moody, and clean/neutral. Includes multi-color 4-stop gradients inspired by modern screenshot tools.
- **Evenly-spaced dashed/dotted lines** — dash and dot patterns on rectangles, ellipses, lines, and arrows now adjust segment size to tile evenly around the shape perimeter, eliminating asymmetric bunching.
- **Dotted freeform strokes** — dotted pencil strokes now place dots at evenly-spaced arc-length positions instead of relying on Core Graphics dash patterns, fixing uneven spacing with smoothing off.
- **Beautify slider spacing** — increased margins between Pad/Rad/Shd/BgR sliders so labels no longer overlap adjacent controls.
- **Default text size** — increased from 16 to 20.

### Fixed
- **Beautify annotation controls** — move/resize handles and selection highlights now draw on top of the beautify preview instead of being hidden behind it.
- **Beautify translate overlay** — translated text overlays now render inside the beautify preview instead of being filtered out.
- **Editor window options row clipping** — the secondary toolbar (tool options row) is now accounted for in the editor window's padding, preventing it from being cut off.

## [2.5.7] - 2026-03-17

### Fixed
- **Pencil/marker self-overlap** — drawing over the same area within a single stroke no longer causes the paint to get darker. The entire stroke now composites as one flat layer with uniform opacity.

## [2.5.6] - 2026-03-16

### Improved
- **Floating thumbnail letterboxing** — very thin or very tall screenshots are now shown with dark padding (letterbox bars) in the thumbnail preview, ensuring action buttons are always clickable and the image is never stretched.

## [2.5.5] - 2026-03-16

### Fixed
- **Floating thumbnail aspect ratio** — very wide or very tall screenshots no longer appear stretched in the thumbnail preview. The thumbnail now always preserves the original aspect ratio while fitting within size bounds.

## [2.5.4] - 2026-03-16

### Fixed
- **Filled rectangle context menu** — right-click menu now shows only the rounded corners toggle (no stroke width rows, since filled rectangles have no border).

## [2.5.3] - 2026-03-16

### Fixed
- **Check for Updates dialog** — the Sparkle update dialog now appears immediately on first click instead of requiring a second click (LSUIElement app activation fix).

## [2.5.2] - 2026-03-16

### Added
- **Filled rectangle right-click menu** — right-click the filled rectangle tool to access stroke width and rounded corners toggle, matching the outlined rectangle tool.

### Fixed
- **Color picker toggle** — clicking the color button when the picker is already open now closes it instead of flickering closed and reopening.

## [2.5.1] - 2026-03-16

### Added
- **Rounded corners toggle** — right-click the rectangle or filled rectangle tool to toggle rounded corners on/off. Setting persists across restarts. Corner radius scales proportionally to the rectangle size.

### Fixed
- **Marker preview circle position** — the marker size preview circle no longer jumps back to the start of the stroke when releasing the mouse button without moving.

## [2.5.0] - 2026-03-16

### Added
- **Auto-updates via Sparkle** — macshot now checks for updates automatically every 30 minutes. Right-click the menu bar icon and choose "Check for Updates..." to check manually. Updates are signed with EdDSA and verified before install.

## [2.4.1] - 2026-03-16

### Added
- **Tool keyboard shortcuts** — single-key shortcuts active after selecting a region: `A` arrow, `L` line, `P` pencil, `M` marker, `R` rectangle, `T` text, `N` number, `B` blur, `X` pixelate, `I` color sampler, `S` select & edit, `E` open in editor (overlay only).

### Fixed
- **Delay button stays highlighted** — after using delay capture, the delay icon appeared active on the next capture but required an extra click to actually use. Delay state now always resets to off when opening a new capture.

## [2.4.0] - 2026-03-16

### Added
- **Editor Window (revamped)** — the standalone editor window is back, rebuilt from scratch. Open any capture in a resizable, titled window via the new "Open in Editor Window" toolbar button, or from the floating thumbnail / pin window "Edit" action. Full annotation tools, zoom (0.1×–8×), copy, save, pin, OCR, upload, beautify, and background removal — all work inside the editor. Annotations transfer seamlessly from the overlay with correct coordinate mapping. Multiple editor windows can be open simultaneously; macshot shows a dock icon while any editor is open.
- **Annotation cloning** — `Annotation.clone()` method for safe deep copies when transferring annotations between overlay and editor.

### Improved
- **Editor toolbar layout** — toolbars pin to window edges (bottom-center, top-right) instead of floating relative to the selection. Overlay-only buttons (cancel, move selection, delay, record, scroll capture) are hidden in editor mode.
- **Editor drawing** — dark background with image centered at natural size. No selection border or resize handles. New selections blocked (image bounds are fixed).

## [2.3.0] - 2026-03-16

### Added
- **Color Picker tool** — new eyedropper tool in the bottom toolbar. Hover over any pixel to see its hex color in real time with a color swatch preview. Press `C` to copy the hex value (e.g. `#FF3B30`) to clipboard. Accurate sRGB sampling. Can be disabled in Preferences like any other tool.
- **Draw outside selection** — annotation strokes (pencil, arrow, line, etc.) can now continue past the selection boundary. Start drawing inside the selection and drag outside freely.
- **Floating thumbnail on copy from overlay** — Cmd+C now shows the floating thumbnail preview in the bottom-right corner, matching the behavior when confirming a capture.

### Improved
- **Loupe tool performance** — live preview no longer creates intermediate images or calls `compositedImage()` on every mouse move. Placed loupes draw directly from the source image. Shadow and gradient objects are cached as statics. Significantly smoother cursor tracking.
- **Marker cursor preview** — now scales correctly with zoom level (drawn inside the zoom transform).
- **Zoom smoothness** — zooming in/out no longer causes a jump when crossing 1x. The zoom transform is continuous at all levels.

### Removed
- **Editor window mode** — the standalone editor window has been removed. All annotation, zoom, crop, and export features work directly in the overlay.

### Fixed
- **Overlay translate clipping** — translated text overlays now stay clipped to the selection rectangle when zoomed, preventing overflow into the dark overlay area.

## [2.2.0] - 2026-03-15

### Added
- **Scroll Capture** — select a region, click the Scroll Capture button (above Record in the right toolbar), then scroll normally. macshot stitches each captured strip into one seamless tall image using Apple Vision's `VNTranslationalImageRegistrationRequest` for pixel-perfect alignment. Works at any scroll speed; handles both downward and upward scrolling. The full screen turns transparent during capture so you see live content everywhere, not a frozen overlay. Press Stop (or Esc) when done — the result is copied to clipboard and shown as a floating thumbnail.

### Improved
- **Scroll Capture live preview** — entire overlay window is fully transparent during scroll capture so you see live screen content on the whole screen, not just inside the selection rectangle.

## [2.1.6] - 2026-03-15

### Fixed
- **Toolbar preferences not respected** — disabling a tool or action in Preferences → Tools would be silently overridden the next time a capture was made. Root cause: the migration code that auto-enables new tools/actions on app updates was treating any tag missing from the stored array as "new", which re-enabled anything the user had just disabled. Fixed by introducing `knownToolRawValues` and `knownActionTags` UserDefaults keys that track which tools/actions have already been introduced; the migration now only adds tags that have never appeared before, so user-disabled items stay disabled.
- **Record screen not toggleable** — the "Record screen" button (tag 1009) was missing from Preferences → Tools → Toolbar Actions, so it could not be hidden. It is now listed alongside the other action toggles.

## [2.1.5] - 2026-03-15

### Fixed
- **~1 s delay on snap/fullscreen confirm** — copying, saving, or pinning a window-snap or full-screen (F key) selection was stalling the main thread for ~1 second before the screenshot sound played. Root cause: `SCScreenshotManager.captureImage` returns an IOSurface-backed CGImage (GPU memory) that is only read back to CPU RAM the first time its pixels are accessed. For manual drag selections the readback happened silently during the drag (many `draw()` calls); for snap/fullscreen the user confirmed before any draw occurred, so the blocking readback hit the main thread at copy/save/pin time. Fix: blit the IOSurface CGImage into a CPU-backed `CGContext` immediately after capture, while still on the background capture thread, so the readback is done before the overlay even appears.

## [2.1.4] - 2026-03-15

### Added
- **Color opacity slider** — the color picker popup now has an opacity slider below the swatches. Drag it to set transparency for all drawing tools (pencil, line, arrow, rectangle, filled rectangle, ellipse, text, numbered markers). Marker keeps its own fixed highlight opacity. Opacity is remembered across captures within the same session.
- **Floating thumbnail action buttons** — hovering the thumbnail now shows a dark overlay with six action buttons: Copy, Save (center), Close, Pin, Edit, Upload (corners). Clicking anywhere else on the thumbnail dismisses it as before.
- **Stackable thumbnails** — multiple captures now stack vertically instead of replacing each other. When a thumbnail is dismissed, the ones below animate up. Configurable in Preferences: "Stack (keep all)" or "Replace (show only latest)".
- **Configurable thumbnail auto-dismiss** — set how many seconds before the thumbnail auto-dismisses (0 = never). Configurable in Preferences (default: 5 seconds).
- **Remember last selection** — new Preferences toggle: "Remember last selection area". When enabled, the last selection rect is restored on the matching screen every time you open the capture overlay.
- **Hover-to-move annotations** — when a shape or drawing tool is active, hovering over an existing annotation shows its edit controls (handles, delete button) and the open-hand cursor. You can drag it to reposition or click a handle to resize without switching to the Select tool. Delete key also removes the hovered annotation.
- **Marker cursor preview** — while the marker tool is active, a semi-transparent circle follows the cursor showing the exact marker size and color before you start drawing.
- **Delete key removes annotations** — pressing Delete (Backspace) removes the currently selected or hovered annotation without needing to click the ✕ button.
- **Undo/redo deletions** — deleting an annotation (via button or Delete key) is now undoable with Cmd+Z. Previously only additions were undoable.

### Improved
- **Window snap performance** — the `CGWindowListCopyWindowInfo` lookup now runs on a background thread and skips overlapping queries, eliminating UI stalls when moving the mouse quickly in snap mode.
- **Thumbnail size** — doubled from 160 px max-width to 320 px for better visibility.
- **Quick-save threshold** — a single-pixel drag now counts as a valid selection for right-click quick-save (previously required >5 px in both dimensions).
- **Undo/redo architecture** — rewritten with a proper `UndoEntry` enum that tracks both additions and deletions, so the full history is preserved when opening in the editor window.
- **Tool persistence** — the last-used drawing tool is now remembered across captures within the same session (was always resetting to arrow).

### Fixed
- **Bezier hit-test** — curved lines and arrows now use the cubic formula that matches NSBezierPath `curve(to:controlPoint1:controlPoint2:)`, so clicking near a bent arrow selects it correctly.

## [2.1.3] - 2026-03-15

### Added
- **Editor window** — open any capture in a standalone editor window (`Open in Editor` button in the right toolbar). The window lives independently of the capture overlay: resize it freely, annotate, copy, save, pin, or upload without dismissing the overlay.
- **Crop tool** — editor window only. Click the `Crop` button in the top bar, drag a rectangle over the image, and release to crop. Annotations are automatically translated to the new origin. Zoom resets to 1× after cropping.
- **Zoom out below 1×** — in editor window mode, pinch or scroll below 1× to zoom out. Areas outside the image show a checkerboard pattern.
- **Top bar in editor window** — shows image size (px), a `Crop` button, the zoom level (click to type an exact value), and a reset-zoom button.
- **Dock icon while editor is open** — macshot shows a dock icon whenever one or more editor windows are open, so you can click it to bring them back. Icon disappears when all editors are closed.
- **Edit button in pin window** — a pencil button next to the close (✕) button opens the pinned image in a new editor window and closes the pin.
- **Smooth strokes toggle** — right-click the pencil tool to see a `Smooth strokes` toggle at the bottom of the menu (on by default). When enabled, finished pencil strokes are smoothed with Chaikin corner-cutting. Preference persists across restarts.

### Improved
- **OCR copy/paste** — `Cmd+C`, `Cmd+A`, `Cmd+X`, `Cmd+V`, and `Cmd+Z`/`Cmd+Shift+Z` now reliably work in the OCR results window.
- **Pin ownership** — pins created from an editor window are now owned by AppDelegate and survive the editor closing.

## [2.1.2] - 2026-03-15

### Added
- **Zoom to cursor** — pinch or scroll now zooms toward the pointer position instead of the selection center
- **Pan while zoomed** — two-finger swipe pans the canvas when zoomed in
- **Click zoom label to set zoom** — click the zoom indicator pill to type an exact zoom level (e.g. `2`, `3.5`); Enter to apply, Escape to cancel
- **Cmd+0 resets zoom** — resets zoom to 1× from the keyboard

## [2.1.1] - 2026-03-15

### Improved
- **Select & Edit tool** — arrow and line endpoints are now individually draggable handles instead of a bounding box; drag the midpoint handle to bend arrows and lines into curves
- **Loupe tool** — gradient border ring (light at top, darker at bottom) for a real lens look; new 320px size option; now magnifies existing annotations too (not just the raw screenshot)
- **Color picker in edit mode** — right-click color wheel and color picker now apply color to the selected annotation; previously only changed the current draw color
- **Font size changes** — no longer clips multi-line text or jumps the text box position; font size number in toolbar is now vertically centered
- **Pen tool** — single click now draws a dot (previously was discarded)
- **App icon** — regenerated all sizes from SVG at correct resolutions; no more blurriness in Finder/System Settings
- **Menu bar icon** — replaced SF Symbol with custom icon matching the app logo (corner brackets + shutter)
- **Liquid glass logo** — shutter blades and ring now use semi-transparent frosted glass effect with top-light gradient sheen

### Fixed
- **Circle/ellipse resize** — no longer flattens immediately when dragging a corner handle; all resize handles now work correctly regardless of draw direction
- **Marker/pencil selection** — bounding box and hit area now account for stroke width, so thick strokes are fully selectable
- **Color in edit mode** — right-click color wheel now shows when select tool is active; color changes apply to selected annotation

## [2.1.0] - 2026-03-15

### Added
- **Screen recording** — record any region of your screen as MP4 (H.264) or GIF. Select a region, click the record button in the right toolbar, and interact with any app normally while recording. Toggle **annotation mode** to draw on screen during recording. Stop with the stop button.
- **Annotation mode during recording** — while recording, toggle annotation mode to draw arrows, text, shapes, and other annotations on the live screen. Annotations appear in the recorded video.
- **Recording completed toast** — after stopping, a floating toast shows the filename with options to reveal in Finder or copy the file path. Auto-dismisses after 6 seconds.
- **Recording preferences tab** — configure output format (MP4/GIF), frame rate (15/24/30/60 fps), and what happens when recording stops (Show in Finder or do nothing).

### Improved
- **Preferences spacing** — tab content is now packed at the top instead of being spread across the full tab height.

## [2.0.0] - 2026-03-14

### Added
- **Window snap mode** — hover over any window to highlight it with a blue border; click to snap the selection to that window's exact bounds. Drag as normal for a custom area. Toggle with `Tab`, capture full screen with `F`. Right-clicking a highlighted window performs a quick save/copy instantly. State persists via UserDefaults.
- **Live QR & barcode detection** — as soon as a selection is made or moved, macshot scans for QR codes and barcodes using Apple Vision. An inline bar appears below (or above) the selection with **Open** (URLs), **Copy**, and **Dismiss** actions. Redetects automatically when the selection changes.
- **Translation in OCR window** — translate extracted OCR text to any language directly in the results panel. Pick a target language from the dropdown, click **Translate**, toggle back with **Show Original**. Re-translates automatically on language change.
- **Background removal** — new toolbar action that uses Apple Vision's foreground instance mask to remove the background from a selection and copy the result as a transparent PNG (macOS 14+).

### Improved
- **Text tool** — `Enter` now inserts a new line (Shift+Enter no longer needed). Confirm text with the new green ✓ button; cancel with the red ✕. Switching to another annotation tool also commits text. Fixed long-standing position drift on multi-line text — switched to `draw(in:)` with the exact layout rect from the NSTextView layout manager.
- **Preferences rebuilt with AutoLayout** — entire Preferences window rewritten using `NSStackView` and AutoLayout. No hardcoded Y coordinates. All three tabs (General, Tools, Uploads) size and scroll correctly.
- **Uploads tab** — fully replaced broken scroll view with an AutoLayout-based list. Upload and delete URLs always visible and scrollable; Copy buttons aligned to the right edge.
- **Tools tab alignment** — second-column checkboxes use a fixed column width so they always align vertically.
- **Capture sound caching** — sound loaded once at startup (`static let`) instead of from disk on every capture, eliminating latency on quick save.
- **OCR Cmd+C fix** — copying text in the OCR results panel now works correctly; was previously beeping due to NSPanel focus issues.
- **Toolbar overlap fix** — bottom action bar no longer overlaps the right toolbar when the selection is near the top of the screen; repositions automatically.

## [1.5.0] - 2026-03-12

### Added
- **Text Tool Overhaul**: Replaced basic text entry with an auto-resizing native text field that is single-line by default. Added `Shift+Enter` for multiline support.
- **Context Menus**: Added context menu support for toolbar tools. Right-click on drawing tools (pencil, line, etc.) or the beautify button to access their settings (stroke, color, or beautify styles), indicated by a small corner triangle.

### Improved
- **Square Selection Constrain**: Holding `Shift` while selecting an area now correctly constrains the selection to a perfect square.
- **Icon Updates**: Replaced the text tool icon with a cleaner `textformat` symbol. Also improved the main menu bar app icon with a larger scale.
- **UI Polish**: Vertically aligned the font size label with the +/- buttons for better aesthetics.
- **Marker Adjustments**: Fine-tuned the marker tool thickness and fixed text crop block sizing.

## [1.4.3] - 2026-03-12

### Fixed
- **Blur/Pixelate stacking**: Blurring or pixelating an already-blurred area now correctly operates on the composited image (including previous annotations) instead of the raw screenshot. Re-blurring now properly increases the blur effect instead of partially reverting it.

## [1.4.2] - 2026-03-12

### Added
- **Right-click color wheel**: Right-click inside the selection while drawing to open a radial color picker centered on the cursor. Drag toward a color to select it, release to confirm. 12 preset colors arranged in a ring.
- **Middle-click move toggle**: Middle mouse button toggles Move Object mode on/off for quick access without clicking the toolbar.
- **Move Object cursor**: Open hand cursor when in Move Object mode instead of crosshair.

### Changed
- Move Object button moved to leftmost position in the toolbar with a subtle background tint to visually distinguish it from drawing tools.

## [1.4.1] - 2026-03-12

### Added
- **Move Object tool**: Select and reposition existing annotations. Click to select, drag to move. Works with lines, arrows, rectangles, ellipses, pencil, marker, text, numbers, and measure lines. Button only appears when there are movable annotations. Pixelate and blur are excluded (position-dependent).

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
