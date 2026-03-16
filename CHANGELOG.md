# Changelog

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
