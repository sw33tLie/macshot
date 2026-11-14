import Cocoa
import UniformTypeIdentifiers

/// Installed as main.swift only in the launcher's private source copy.
/// Drives the real editor with synthesized mouse events and renders its own
/// windows (never the screen) to PNGs in the probe's output folder:
///   Select tool + marquee, editing a pasted image past the canvas edge,
///   measure scale (draw reference, enter "90 mm", undo/redo), and a
///   .macshot project round trip (save, reopen, save in place).
@MainActor
final class AnnotationWorkflowsProbe: NSObject, NSApplicationDelegate {
    /// Inside the sandbox container, so the probe runs with the shipping entitlements.
    private let output: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("annotation-workflows-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private var failures = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "beautifyEnabled")
        UserDefaults.standard.set(0, forKey: "historySize")
        UserDefaults.standard.removeObject(forKey: "enabledTools")
        UserDefaults.standard.removeObject(forKey: "knownToolRawValues")
        log("OUTPUT \(output.path)")
        Task { @MainActor in
            await run()
            log("DONE failures=\(failures)")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Scenarios

    private func run() async {
        let image = makeImage()
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 120, y: 120), endPoint: NSPoint(x: 300, y: 260),
                               color: .systemRed, strokeWidth: 5)
        let rect = Annotation(tool: .rectangle, startPoint: NSPoint(x: 500, y: 300), endPoint: NSPoint(x: 760, y: 470),
                              color: .systemYellow, strokeWidth: 4)
        DetachedEditorWindowController.open(image: image, annotations: [arrow, rect])
        await pause(0.8)
        guard let (window, editor) = findEditor() else { return fail("editor did not open") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await pause(0.3)
        snap(window, "01-editor-opened")

        // Select tool: first toolbar button, V shortcut, marquee on empty space.
        editor.handleToolbarAction(.tool(.select))
        await pause(0.2)
        check(editor.currentTool == .select, "select tool armed from toolbar")
        snap(window, "02-select-tool-armed")
        await drag(editor, from: NSPoint(x: 60, y: 40), to: NSPoint(x: 820, y: 500), steps: 8, release: false)
        snap(window, "03-marquee-dragging")
        await mouse(.leftMouseUp, editor, NSPoint(x: 820, y: 500))
        await pause(0.2)
        snap(window, "04-marquee-selected-both")
        check(editor.annotations.count == 2, "marquee drew nothing new")

        // Dragging a body with the Select tool moves it, never draws.
        await mouse(.leftMouseDown, editor, NSPoint(x: 600, y: 80)) // empty: clears selection
        await mouse(.leftMouseUp, editor, NSPoint(x: 600, y: 80))
        let before = arrow.startPoint
        await drag(editor, from: NSPoint(x: 210, y: 190), to: NSPoint(x: 260, y: 160), steps: 5)
        check(abs(arrow.startPoint.x - before.x - 50) < 1.5 && abs(arrow.startPoint.y - before.y + 30) < 1.5,
              "select tool moved the arrow (\(before) -> \(arrow.startPoint))")
        check(editor.annotations.count == 2, "moving drew nothing new")

        // Arrow keys nudge the selected arrow (real key events through the window).
        let beforeNudge = arrow.startPoint
        let depthBeforeNudge = editor.undoStack.count
        for (code, shift) in [(UInt16(124), false), (124, false), (126, true)] {
            let character = String(UnicodeScalar([124: 0xF703, 126: 0xF700][Int(code)]!)!)
            if let key = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                          modifierFlags: shift ? [.shift, .function, .numericPad] : [.function, .numericPad],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: character, charactersIgnoringModifiers: character,
                                          isARepeat: false, keyCode: code) {
                NSApp.sendEvent(key)
                await pause(0.05)
            }
        }
        check(arrow.startPoint.x == beforeNudge.x + 2 && arrow.startPoint.y == beforeNudge.y + 10,
              "arrow keys nudged the selection (\(beforeNudge) -> \(arrow.startPoint))")
        check(editor.undoStack.count == depthBeforeNudge + 1, "the nudge run is one undo entry")
        check(rect.startPoint == NSPoint(x: 500, y: 300), "clicking empty space deselected the rectangle, so it stayed put")
        editor.undo()
        check(arrow.startPoint == beforeNudge, "one undo reverts the whole nudge run (\(arrow.startPoint))")
        let movedArrowStart = arrow.startPoint

        // A pasted image at the bottom: its lower handles sit in the margin.
        editor.addCaptureImage(makeImage(width: 320, height: 200, hue: 0.8))
        await pause(0.3)
        guard let stamp = editor.annotations.last, stamp.tool == .stamp else { return fail("no pasted image") }
        let canvas = editor.selectionRect
        log("canvas after paste: \(canvas) stamp: \(stamp.boundingRect) frame: \(editor.frame) bounds: \(editor.bounds)")
        snap(window, "05-pasted-image-handles-in-margin")
        // Bottom-left handle is at the canvas corner; grab it from just outside the image.
        let corner = NSPoint(x: stamp.boundingRect.minX, y: stamp.boundingRect.minY)
        check(!canvas.insetBy(dx: 0.5, dy: 0.5).contains(corner), "handle sits on/outside the canvas edge")
        let widthBefore = stamp.boundingRect.width
        // Scroll to the bottom, as a user would to reach the pasted image.
        if let scrollView = editor.enclosingScrollView {
            let clip = scrollView.contentView
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: -10_000),
                                                             size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
            await pause(0.2)
            snap(window, "05b-scrolled-to-bottom")
        }
        for probe in [NSPoint(x: corner.x - 2, y: corner.y - 2), NSPoint(x: 160, y: -10), NSPoint(x: 10, y: 10)] {
            let windowPoint = editor.convert(probe, to: nil)
            let hit = window.contentView?.hitTest(window.contentView!.convert(windowPoint, from: nil))
            log("hit \(probe) window \(windowPoint) -> \(hit.map { String(describing: type(of: $0)) } ?? "nil") interactive=\(editor.pointHitsAnnotationInteraction(probe))")
        }
        await drag(editor, from: NSPoint(x: corner.x - 2, y: corner.y - 2), to: NSPoint(x: corner.x - 2 + 60, y: corner.y - 2 + 40), steps: 6)
        await pause(0.2)
        check(abs(stamp.boundingRect.width - widthBefore) > 20,
              "resized from a handle outside the image (\(widthBefore) -> \(stamp.boundingRect.width))")
        snap(window, "06-pasted-image-resized-from-margin")

        // Drawing tool clicks in the margin draw nothing.
        editor.handleToolbarAction(.tool(.pencil))
        let count = editor.annotations.count
        await drag(editor, from: NSPoint(x: -20, y: canvas.midY), to: NSPoint(x: -30, y: canvas.midY + 50), steps: 4)
        check(editor.annotations.count == count, "pencil in the empty margin drew nothing")

        // Undo the resize, the canvas growth and the paste: the original image returns aligned.
        editor.undo(); editor.undo(); editor.undo()
        await pause(0.2)
        check(editor.annotations.count == 2, "paste undone")
        check(editor.selectionRect.size == NSSize(width: 900, height: 560), "canvas back to the image (\(editor.selectionRect))")
        check(arrow.startPoint == movedArrowStart, "arrow realigned after undoing canvas growth (\(arrow.startPoint))")
        snap(window, "07-after-undoing-paste")

        // Measure scale: no line selected -> popover offers to draw a reference.
        editor.handleToolbarAction(.tool(.measure))
        await pause(0.3)
        snap(window, "08-measure-options-set-scale")
        guard let scaleButton = find(NSButton.self, in: window.contentView!, where: { $0.tag == ToolOptionsRowView.measureScaleButtonTag })
        else { return fail("Set Scale button missing") }
        scaleButton.performClick(nil)
        await pause(0.6)
        snapPopover("09-scale-popover-no-reference")
        guard let drawReference = popoverButton(titled: L("Draw Reference Line")) else { return fail("no Draw Reference Line") }
        drawReference.performClick(nil)
        await pause(0.4)
        check(editor.isAwaitingMeasureReference, "waiting for a reference line")
        // A 300-point line; it should become "90 mm".
        await drag(editor, from: NSPoint(x: 100, y: 500), to: NSPoint(x: 400, y: 500), steps: 6)
        await pause(0.7)
        snapPopover("10-scale-popover-reference")
        guard let field = popoverView(NSTextField.self, where: { $0.isEditable }) else { return fail("no length field") }
        field.stringValue = "abc"
        popoverButton(titled: L("Set Scale"))?.performClick(nil)
        await pause(0.3)
        snapPopover("11-scale-popover-invalid-input")
        check(editor.measureCalibration == nil, "nonsense does not set a scale")
        field.stringValue = "90 mm"
        popoverButton(titled: L("Set Scale"))?.performClick(nil)
        await pause(0.4)
        check(editor.measureCalibration?.unit == MeasureUnit.millimeters, "scale set in mm")
        check(abs((editor.measureCalibration?.pointsPerUnit ?? 0) - 300.0 / 90) < 0.01, "3.33 points per mm")
        await drag(editor, from: NSPoint(x: 600, y: 120), to: NSPoint(x: 600, y: 270), steps: 5)  // 150 pt = 45 mm
        await drag(editor, from: NSPoint(x: 450, y: 60), to: NSPoint(x: 750, y: 220), steps: 5)  // diagonal
        await pause(0.3)
        let measures = editor.annotations.filter { $0.tool == .measure }
        check(measures.count == 3 && measures.allSatisfy { $0.measureCalibration != nil }, "every line carries the scale")
        snap(window, "12-measured-in-mm")

        // Show in inches.
        if let button = find(NSButton.self, in: window.contentView!, where: { $0.tag == ToolOptionsRowView.measureScaleButtonTag }) {
            button.performClick(nil)
            await pause(0.6)
            snapPopover("13-scale-popover-calibrated")
            if let popup = popoverView(NSPopUpButton.self, where: { $0.target != nil }) {
                popup.selectItem(at: MeasureUnit.allCases.firstIndex(of: .inches)!)
                _ = popup.target?.perform(popup.action, with: popup)
            }
            await pause(0.4)
        }
        check(editor.measureCalibration?.unit == MeasureUnit.inches, "shown in inches")
        snap(window, "14-measured-in-inches")

        editor.undo()  // back to mm
        check(editor.measureCalibration?.unit == MeasureUnit.millimeters, "undo returns to mm")
        editor.redo()
        check(editor.measureCalibration?.unit == MeasureUnit.inches, "redo returns to inches")

        // Project round trip.
        let projectURL = output.appendingPathComponent("Inspection Report.macshot")
        guard let raw = editor.captureSelectedRegionRaw(), let flat = editor.captureSelectedRegion() else {
            return fail("no raw image")
        }
        do {
            let snapshot = try MacshotProjectFile.Snapshot(
                rawImage: raw, flattenedImage: flat, annotations: editor.annotations.filter { $0.isMovable }.map { $0.clone() },
                editState: editor.captureEditState())
            let written = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                MacshotProjectFile.write(snapshot, to: projectURL) { result in
                    if case .failure(let error) = result { self.log("write error: \(error)") }
                    continuation.resume(returning: (try? result.get()) != nil)
                }
            }
            check(written, "project written")
        } catch { return fail("snapshot: \(error)") }
        let size = (try? projectURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        log("project size: \(size) bytes, type: \(String(describing: try? projectURL.resourceValues(forKeys: [.contentTypeKey]).contentType))")

        window.performClose(nil)  // dirty: a sheet asks
        await pause(0.6)
        snapSheet(window, "15-close-prompt")
        if let sheet = window.attachedSheet, let discard = find(NSButton.self, in: sheet.contentView!, where: { $0.title == L("Discard") }) {
            discard.performClick(nil)
        }
        await pause(0.6)

        guard let decoded = try? MacshotProjectFile.decode(contentsOf: projectURL) else { return fail("decode") }
        guard let contents = try? MacshotProjectFile.contents(of: decoded),
              case .editable(let rawImage, let annotations, let editState) = contents else {
            return fail("project did not reopen editable")
        }
        DetachedEditorWindowController.open(image: rawImage, annotations: annotations, editState: editState, projectURL: projectURL)
        await pause(0.8)
        guard let (reopened, reopenedEditor) = findEditor() else { return fail("reopened editor missing") }
        check(reopened.title == "Inspection Report", "window titled after the project (\(reopened.title))")
        check(reopened.representedURL == projectURL, "proxy icon points at the file")
        check(reopenedEditor.annotations.count == 5, "all annotations back (\(reopenedEditor.annotations.count))")
        check(reopenedEditor.measureCalibration?.unit == MeasureUnit.inches, "scale back")
        check(!reopened.isDocumentEdited, "fresh project is clean")
        reopenedEditor.handleToolbarAction(.tool(.measure))
        await pause(0.3)
        snap(reopened, "16-project-reopened")
        check(DetachedEditorWindowController.focusEditor(forProjectURL: projectURL), "second open focuses the same window")

        // Edit + Save Project writes in place without a panel.
        reopenedEditor.handleToolbarAction(.tool(.rectangle))
        await drag(reopenedEditor, from: NSPoint(x: 40, y: 40), to: NSPoint(x: 140, y: 100), steps: 4)
        await pause(0.2)
        check(reopened.isDocumentEdited, "edited project shows the dirty dot")
        let mtime = (try? projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        await pause(1.1)
        NSApp.sendAction(#selector(DetachedEditorWindowController.saveMacshotProject(_:)), to: nil, from: nil)
        await pause(1.5)
        let newMtime = (try? projectURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        check(newMtime > mtime, "Save Project (⇧⌘S) wrote the file in place")
        check(!reopened.isDocumentEdited, "clean after saving")
        check(reopened.attachedSheet == nil, "no save panel for a linked project")
        if let resaved = try? MacshotProjectFile.decode(contentsOf: projectURL),
           let contents = try? MacshotProjectFile.contents(of: resaved),
           case .editable(_, let anns, _) = contents {
            check(anns.count == 6, "saved file has the new rectangle (\(anns.count))")
        } else { fail("resaved project unreadable") }

        // Light toolbar appearance with the scale chip.
        UserDefaults.standard.set("light", forKey: "hudAppearance")
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
        reopenedEditor.handleToolbarAction(.tool(.measure))
        await pause(0.4)
        snap(reopened, "17-light-toolbar-measure")
        UserDefaults.standard.removeObject(forKey: "hudAppearance")
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
        reopened.close()
        await pause(0.3)
        await runOverlayScenario()
    }

    /// The capture overlay hosts the same canvas without a scroll view:
    /// toolbars and popovers live inside the view itself.
    private func runOverlayScenario() async {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Overlay probe"
        window.isReleasedWhenClosed = false
        let overlay = OverlayView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720))
        window.contentView = overlay
        overlay.screenshotImage = makeImage(width: 1100, height: 720, hue: 0.1)
        window.makeKeyAndOrderFront(nil)
        overlay.applySelection(NSRect(x: 150, y: 220, width: 760, height: 420))
        overlay.rebuildToolbarLayout()
        await pause(0.4)
        overlay.handleToolbarAction(.tool(.select))
        overlay.rebuildToolbarLayout()
        await pause(0.2)
        snap(window, "18-overlay-select-tool")

        // A line drawn past the selection's top edge: its end handle sits outside.
        overlay.handleToolbarAction(.tool(.line))
        await drag(overlay, from: NSPoint(x: 300, y: 500), to: NSPoint(x: 500, y: 630), steps: 5)
        let line = overlay.annotations.last
        check(line?.tool == .line, "line drawn in overlay")
        overlay.handleToolbarAction(.tool(.select))
        await mouse(.leftMouseDown, overlay, NSPoint(x: 400, y: 565))
        await mouse(.leftMouseUp, overlay, NSPoint(x: 400, y: 565))
        await pause(0.2)
        let count = overlay.annotations.count
        // Outside the selection on empty screen: nothing happens.
        await drag(overlay, from: NSPoint(x: 60, y: 60), to: NSPoint(x: 120, y: 120), steps: 3)
        check(overlay.annotations.count == count, "outside the selection draws nothing")

        overlay.handleToolbarAction(.tool(.measure))
        overlay.rebuildToolbarLayout()
        await pause(0.3)
        await drag(overlay, from: NSPoint(x: 200, y: 300), to: NSPoint(x: 500, y: 300), steps: 5)
        if let measure = overlay.annotations.last, measure.tool == .measure {
            overlay.showMeasureScalePopover(reference: measure, anchorView: nil)
            await pause(0.6)
            snapPopover("19-overlay-scale-popover")
            if let field = popoverView(NSTextField.self, where: { $0.isEditable }) {
                field.stringValue = "6' 2\""
                popoverButton(titled: L("Set Scale"))?.performClick(nil)
            }
            await pause(0.4)
            check(overlay.measureCalibration?.unit == .feet, "feet and inches set a scale in feet")
        } else { fail("overlay measure missing") }
        snap(window, "20-overlay-measured")
        window.close()
    }

    // MARK: - Helpers

    private func findEditor() -> (NSWindow, EditorView)? {
        for window in NSApp.windows.reversed() where window.isVisible {
            if let view = find(EditorView.self, in: window.contentView ?? NSView(), where: { _ in true }) {
                return (window, view)
            }
        }
        return nil
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView, where predicate: (T) -> Bool) -> T? {
        if let match = root as? T, predicate(match) { return match }
        for sub in root.subviews {
            if let found = find(type, in: sub, where: predicate) { return found }
        }
        return nil
    }

    private var popoverWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    private func popoverView<T: NSView>(_ type: T.Type, where predicate: (T) -> Bool) -> T? {
        for window in popoverWindows {
            if let root = window.contentView, let found = find(type, in: root, where: predicate) { return found }
        }
        return nil
    }

    private func popoverButton(titled title: String) -> NSButton? {
        popoverView(NSButton.self, where: { $0.title == title })
    }

    private func mouse(_ type: NSEvent.EventType, _ view: NSView, _ canvasPoint: NSPoint) async {
        guard let window = view.window else { return }
        let point = view.convert(canvasPoint, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        NSApp.sendEvent(event)
        await pause(0.03)
    }

    private func drag(_ view: NSView, from: NSPoint, to: NSPoint, steps: Int, release: Bool = true) async {
        await mouse(.leftMouseDown, view, from)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            await mouse(.leftMouseDragged, view, NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        if release { await mouse(.leftMouseUp, view, to) }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func write(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = output.appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("SNAP \(url.path)")
    }

    private func snap(_ window: NSWindow, _ name: String) {
        window.displayIfNeeded()
        if let content = window.contentView { write(content, name) }
    }

    private func snapPopover(_ name: String) {
        guard let window = popoverWindows.last, let content = window.contentView else { return log("no popover for \(name)") }
        write(content.superview ?? content, name)
    }

    private func snapSheet(_ window: NSWindow, _ name: String) {
        guard let sheet = window.attachedSheet, let content = sheet.contentView else { return log("no sheet for \(name)") }
        write(content.superview ?? content, name)
    }

    private func check(_ condition: Bool, _ message: String) {
        if condition { log("PASS \(message)") } else { fail(message) }
    }

    private func fail(_ message: String) {
        failures += 1
        log("FAIL \(message)")
    }

    private func log(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private func makeImage(width: Int = 900, height: Int = 560, hue: CGFloat = 0.58) -> NSImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let base = NSColor(hue: hue, saturation: 0.45, brightness: 0.35, alpha: 1)
        context.setFillColor(base.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor(hue: hue, saturation: 0.3, brightness: 0.8, alpha: 1).cgColor)
        for i in 0..<6 {
            context.fill(CGRect(x: 30 + i * width / 7, y: height / 3, width: width / 9, height: height / 3))
        }
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }
}

let probeApplication = NSApplication.shared
let probeDelegate = MainActor.assumeIsolated { AnnotationWorkflowsProbe() }
probeApplication.delegate = probeDelegate
probeApplication.setActivationPolicy(.regular)
probeApplication.run()
withExtendedLifetime(probeDelegate) {}
