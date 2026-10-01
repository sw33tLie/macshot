import Cocoa
import AVFoundation

// MARK: - Configuration enums

enum WebcamPosition: String {
    case bottomRight, bottomLeft, topRight, topLeft
}

enum WebcamSize: String {
    case small, medium, large, xlarge

    static let defaultsKey = "webcamSizePoints"
    static let minPoints: CGFloat = 80
    static let maxPoints: CGFloat = 480
    static let defaultPoints: CGFloat = 120

    var points: CGFloat {
        switch self {
        case .small: return 80
        case .medium: return 120
        case .large: return 160
        case .xlarge: return 220
        }
    }

    /// Read the continuous size, falling back to the legacy named presets.
    static var savedPoints: CGFloat {
        if let value = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber {
            return min(max(CGFloat(value.doubleValue), minPoints), maxPoints)
        }
        let legacy = WebcamSize(
            rawValue: UserDefaults.standard.string(forKey: "webcamSize") ?? "medium")
            ?? .medium
        return legacy.points
    }

    static func save(points: CGFloat) {
        let clamped = min(max(points.rounded(), minPoints), maxPoints)
        UserDefaults.standard.set(Double(clamped), forKey: defaultsKey)
    }
}

enum WebcamShape: String {
    case circle, roundedRect
}

// MARK: - WebcamOverlay

/// Floating webcam preview bubble for screen recording.
/// Positioned at `.statusBar + 1` so ScreenCaptureKit automatically captures it.
class WebcamOverlay: NSPanel {

    private let containerView = WebcamContainerView()
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var spinner: NSProgressIndicator?

    private var frameOutput: AVCaptureVideoDataOutput?
    private var frameDelegate: WebcamFrameDelegate?
    private let frameQueue = DispatchQueue(label: "macshot.webcam-frames", qos: .userInitiated)
    /// Starting, stopping and reconfiguring the session are serialized here:
    /// `startRunning()` must never run between begin/commitConfiguration.
    private let sessionQueue = DispatchQueue(label: "macshot.webcam-session", qos: .userInitiated)

    private var currentSize: CGFloat = WebcamSize.defaultPoints
    private var currentShape: WebcamShape = .circle

    /// Recorded area (screen coordinates) the bubble stays inside.
    private var constraintRect: NSRect = .zero
    private let resizeHandle = WebcamResizeHandleView()
    private var isHovered = false
    private var isInteracting = false
    private var hideHandleWork: DispatchWorkItem?

    /// Called with the new screen frame while the user moves or resizes the bubble.
    var onFrameChanged: ((NSRect) -> Void)?

    init(screen: NSScreen) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // 258: above the capture overlay window (level 257) so the setup preview is
        // visible before recording starts. After recording starts the overlay is gone
        // and ScreenCaptureKit captures the panel regardless of level.
        level = NSWindow.Level(258)
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        containerView.wantsLayer = true
        containerView.frame = contentView!.bounds
        containerView.autoresizingMask = [.width, .height]
        containerView.panel = self
        contentView!.addSubview(containerView)

        resizeHandle.panel = self
        resizeHandle.isHidden = true
        contentView!.addSubview(resizeHandle)
    }

    // MARK: - Public API

    /// Places the bubble in `recordingRect`: at `freeCenter` (normalized,
    /// from a previous drag) when given, otherwise in the `position` corner.
    func configure(position: WebcamPosition, size: CGFloat, shape: WebcamShape, recordingRect: NSRect,
                   freeCenter: CGPoint? = nil) {
        constraintRect = recordingRect
        currentShape = shape
        let s = WebcamPlacement.fittedSize(size, in: recordingRect)
        let frame: NSRect
        if let freeCenter {
            frame = WebcamPlacement.frame(
                center: WebcamPlacement.center(fromNormalized: freeCenter, in: recordingRect),
                size: s, in: recordingRect)
        } else {
            frame = WebcamPlacement.cornerFrame(position, size: s, in: recordingRect)
        }
        applyBubbleFrame(frame, notify: false)
    }

    /// Applies a new square frame and keeps mask, preview, handle and shadow in step.
    private func applyBubbleFrame(_ frame: NSRect, notify: Bool = true) {
        currentSize = frame.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(frame, display: true)
        applyShapeMask()
        previewLayer?.frame = containerView.bounds
        layoutResizeHandle()
        CATransaction.commit()
        invalidateShadow()
        if notify { onFrameChanged?(frame) }
    }

    func startPreview(deviceUID: String?) {
        stopPreview()

        let session = AVCaptureSession()
        session.sessionPreset = .medium

        let device: AVCaptureDevice?
        if let uid = deviceUID, let d = AVCaptureDevice(uniqueID: uid) {
            device = d
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let camera = device,
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = containerView.bounds
        containerView.layer?.addSublayer(preview)
        previewLayer = preview
        captureSession = session

        applyShapeMask()
        showSpinner()

        // Start camera off the main thread to avoid blocking UI
        sessionQueue.async { [weak self] in
            session.startRunning()
            // Give the preview layer a moment to receive the first frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.hideSpinner()
            }
        }
    }

    func stopPreview() {
        stopFrameTap()
        let session = captureSession
        captureSession = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        hideSpinner()
        // Stop off the main thread to avoid blocking UI
        if let session = session {
            sessionQueue.async {
                session.stopRunning()
            }
        }
    }

    private func showSpinner() {
        guard spinner == nil else { return }
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.isIndeterminate = true
        s.sizeToFit()
        s.frame.origin = NSPoint(
            x: (containerView.bounds.width - s.frame.width) / 2,
            y: (containerView.bounds.height - s.frame.height) / 2)
        s.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        containerView.addSubview(s)
        s.startAnimation(nil)
        spinner = s
    }

    private func hideSpinner() {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
    }

    func setDraggable(_ draggable: Bool) {
        ignoresMouseEvents = !draggable
        if !draggable { setHovered(false) }
    }

    // MARK: - Move & resize

    private var dragOffset: NSPoint = .zero
    private var resizeAnchor: NSPoint = .zero

    fileprivate func beginMove(at mouse: NSPoint) {
        isInteracting = true
        dragOffset = NSPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
    }

    fileprivate func move(to mouse: NSPoint) {
        var f = frame
        f.origin = NSPoint(x: mouse.x - dragOffset.x, y: mouse.y - dragOffset.y)
        applyBubbleFrame(WebcamPlacement.clamped(f, to: constraintRect))
    }

    fileprivate func endMove() {
        isInteracting = false
        if WebcamPlacement.snapsToCorners,
           let corner = WebcamPlacement.snapCorner(for: frame, in: constraintRect) {
            let target = WebcamPlacement.cornerFrame(corner, size: currentSize, in: constraintRect)
            if target != frame { applyBubbleFrame(target) }
        }
        persistPlacement()
        if !isHovered { scheduleHandleHide() }
    }

    fileprivate func beginResize() {
        isInteracting = true
        // The corner opposite the handle stays put.
        let d = WebcamPlacement.handleDirection(for: frame, in: constraintRect)
        resizeAnchor = NSPoint(x: d.dx > 0 ? frame.minX : frame.maxX, y: d.dy > 0 ? frame.minY : frame.maxY)
    }

    fileprivate func resize(to mouse: NSPoint) {
        let side = max(abs(mouse.x - resizeAnchor.x), abs(mouse.y - resizeAnchor.y))
        applyBubbleFrame(WebcamPlacement.resized(frame, to: side, keeping: resizeAnchor, in: constraintRect))
    }

    fileprivate func endResize() {
        isInteracting = false
        persistPlacement()
        if !isHovered { scheduleHandleHide() }
    }

    /// Pinch / ⌥-scroll resize around the bubble's center.
    fileprivate func scale(by delta: CGFloat) {
        guard delta.isFinite, delta != 0 else { return }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        applyBubbleFrame(WebcamPlacement.frame(center: center, size: currentSize + delta, in: constraintRect))
        persistPlacement()
    }

    /// Remembers the placement for the next recording: a corner slot when
    /// the bubble sits in one, otherwise its normalized center.
    private func persistPlacement() {
        WebcamSize.save(points: currentSize)
        if let corner = WebcamPlacement.snapCorner(for: frame, in: constraintRect, threshold: 0.5) {
            WebcamPlacement.saveCorner(corner)
        } else if let center = WebcamPlacement.normalizedCenter(of: frame, in: constraintRect) {
            WebcamPlacement.saveFreeCenter(center)
        }
    }

    // MARK: - Resize handle

    fileprivate func setHovered(_ hovered: Bool) {
        isHovered = hovered
        if hovered {
            hideHandleWork?.cancel()
            hideHandleWork = nil
            resizeHandle.isHidden = ignoresMouseEvents
        } else if !isInteracting {
            scheduleHandleHide()
        }
    }

    /// Hides the handle shortly after the pointer leaves. When the webcam
    /// is part of the recorded pixels the handle must not linger on screen.
    private func scheduleHandleHide() {
        hideHandleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isHovered, !self.isInteracting else { return }
            self.resizeHandle.isHidden = true
        }
        hideHandleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func layoutResizeHandle() {
        guard let content = contentView else { return }
        let s = content.bounds.width
        let d = WebcamPlacement.handleDirection(for: frame, in: constraintRect)
        // On the bubble's rim, on the side facing the inside of the recorded area.
        let reach = s / 2 * 0.62
        let side = WebcamResizeHandleView.side
        let center = NSPoint(x: s / 2 + reach * d.dx, y: s / 2 + reach * d.dy)
        resizeHandle.frame = NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    // MARK: - Frame tap (separate camera recording)

    /// Taps camera frames for recording at up to 720p. Times are converted
    /// from the capture session's clock to the host clock the screen uses.
    func startFrameTap(_ handler: @escaping @Sendable (CMSampleBuffer, Double) -> Void) -> Bool {
        guard let session = captureSession, frameOutput == nil else { return false }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let delegate = WebcamFrameDelegate { [weak session] sample in
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let clock = session?.synchronizationClock ?? CMClockGetHostTimeClock()
            let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
            guard host.isNumeric else { return }
            handler(sample, host.seconds)
        }
        let queue = frameQueue
        let added: Bool = sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            output.setSampleBufferDelegate(delegate, queue: queue)
            return true
        }
        guard added else { return false }
        frameOutput = output
        frameDelegate = delegate
        return true
    }

    func stopFrameTap() {
        guard let output = frameOutput, let session = captureSession else {
            frameOutput = nil
            frameDelegate = nil
            return
        }
        output.setSampleBufferDelegate(nil, queue: nil)
        sessionQueue.async {
            session.beginConfiguration()
            session.removeOutput(output)
            session.commitConfiguration()
        }
        frameOutput = nil
        frameDelegate = nil
    }

    // MARK: - Static helpers

    static var availableCameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video, position: .unspecified).devices
    }

    // MARK: - Shape masking

    private func applyShapeMask() {
        guard let layer = containerView.layer else { return }
        let bounds = containerView.bounds

        // Remove old sublayers except preview
        layer.sublayers?.removeAll { $0 !== previewLayer }

        let path: CGPath
        switch currentShape {
        case .circle:
            path = CGPath(ellipseIn: bounds, transform: nil)
        case .roundedRect:
            let radius = currentSize / 5
            path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        // Clip mask
        let mask = CAShapeLayer()
        mask.path = path
        layer.mask = mask

        // Border stroke
        let border = CAShapeLayer()
        border.path = path
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        border.lineWidth = 2
        layer.addSublayer(border)
    }
}

// MARK: - Draggable content view

/// Drag to move, pinch or ⌥-scroll to resize. Works while another app is
/// active (during recording), hence `acceptsFirstMouse`.
private class WebcamContainerView: NSView {
    weak var panel: WebcamOverlay?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { panel?.setHovered(true) }
    override func mouseExited(with event: NSEvent) { panel?.setHovered(false) }

    override func mouseDown(with event: NSEvent) { panel?.beginMove(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { panel?.move(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { panel?.endMove() }

    override func magnify(with event: NSEvent) {
        guard let panel else { return }
        panel.scale(by: panel.frame.width * event.magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        panel?.scale(by: delta)
    }
}

/// Small grip on the bubble's rim; dragging it resizes around the opposite corner.
private final class WebcamResizeHandleView: NSView {
    static let side: CGFloat = 16
    weak var panel: WebcamOverlay?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dot = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSColor.white.setFill()
        dot.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        dot.lineWidth = 1
        dot.stroke()
    }

    override func mouseDown(with event: NSEvent) { panel?.beginResize() }
    override func mouseDragged(with event: NSEvent) { panel?.resize(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { panel?.endResize() }
}


extension WebcamOverlay: RecordingCameraSource {}

private final class WebcamFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let handler: (CMSampleBuffer) -> Void
    init(_ handler: @escaping (CMSampleBuffer) -> Void) { self.handler = handler }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}
