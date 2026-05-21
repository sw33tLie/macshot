import Cocoa
import AVFoundation

// MARK: - Configuration enums

enum WebcamPosition: String {
    case bottomRight, bottomLeft, topRight, topLeft
}

enum WebcamSize: String {
    case small, medium, large, xlarge

    var points: CGFloat {
        switch self {
        case .small: return 80
        case .medium: return 120
        case .large: return 160
        case .xlarge: return 220
        }
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

    private var currentSize: CGFloat = WebcamSize.medium.points
    private var currentShape: WebcamShape = .circle

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
    }

    // MARK: - Public API

    func configure(position: WebcamPosition, size: WebcamSize, shape: WebcamShape, recordingRect: NSRect) {
        currentSize = size.points
        currentShape = shape

        let s = currentSize
        let padding: CGFloat = 12

        var origin: NSPoint
        switch position {
        case .bottomRight:
            origin = NSPoint(x: recordingRect.maxX - s - padding, y: recordingRect.minY + padding)
        case .bottomLeft:
            origin = NSPoint(x: recordingRect.minX + padding, y: recordingRect.minY + padding)
        case .topRight:
            origin = NSPoint(x: recordingRect.maxX - s - padding, y: recordingRect.maxY - s - padding)
        case .topLeft:
            origin = NSPoint(x: recordingRect.minX + padding, y: recordingRect.maxY - s - padding)
        }

        setFrame(NSRect(x: origin.x, y: origin.y, width: s, height: s), display: true)
        applyShapeMask()
        previewLayer?.frame = containerView.bounds
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

        // Start camera on background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            session.startRunning()
            // Give the preview layer a moment to receive the first frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.hideSpinner()
            }
        }
    }

    func stopPreview() {
        let session = captureSession
        captureSession = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        hideSpinner()
        // Stop on background thread to avoid blocking UI
        if let session = session {
            DispatchQueue.global(qos: .userInitiated).async {
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

private class WebcamContainerView: NSView {
    weak var panel: NSPanel?
    private var dragOrigin: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = panel else { return }
        let current = event.locationInWindow
        let dx = current.x - dragOrigin.x
        let dy = current.y - dragOrigin.y
        var origin = panel.frame.origin
        origin.x += dx
        origin.y += dy
        panel.setFrameOrigin(origin)
    }
}
