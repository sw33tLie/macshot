import Cocoa

/// Owns the ONE place the two themes legitimately diverge for a single toolbar
/// surface: window topology.
///
/// - Normal theme: the content view (a strip / options row) stays a subview of
///   the overlay and draws its own solid background. The presenter does nothing
///   except ensure no glass panel is active.
/// - Liquid Glass theme: the content is lifted into a floating child panel
///   (`OverlayChromePanel`) above the overlay, where an `NSGlassEffectView`
///   provides the translucent background (glass can only refract content from
///   windows behind it, so it must live in a separate window). While hosted, the
///   content's `hostedInGlassPanel` flag is set so it skips its own bg fill.
///
/// Everything else — layout (overlay-space rects), hit-test detection, cursor,
/// tooltips — is identical for both themes and lives in `OverlayView`, keyed off
/// the shared overlay-space rect. This presenter is the only topology branch.
final class OverlayChromePresenter {

    let cornerRadius: CGFloat
    /// True for surfaces with editable text fields (the resolution box) so their
    /// glass panel can take keyboard focus.
    let keyCapable: Bool
    private var panel: OverlayChromePanel?

    init(cornerRadius: CGFloat, keyCapable: Bool = false) {
        self.cornerRadius = cornerRadius
        self.keyCapable = keyCapable
    }

    var hasPanel: Bool { panel != nil }

    /// Temporarily make the floating chrome window mouse-transparent. Used while
    /// a toolbar-initiated drag is moving the selection: the glass panels are
    /// separate windows, and moving them under the stationary cursor causes
    /// AppKit to synthesize hover/entered states for arbitrary buttons.
    func setMouseInteractionEnabled(_ enabled: Bool) {
        panel?.ignoresMouseEvents = !enabled
        panel?.acceptsMouseMovedEvents = enabled
    }

    /// Present `content` at `overlayRect` (overlay-space) within `overlayView`.
    /// When `glass` is true and `visible`, host it in a child panel; otherwise
    /// return it to the overlay as a normal subview.
    func present(_ content: ChromeContent & NSView, overlayRect: NSRect,
                 visible: Bool, glass: Bool, in overlayView: NSView) {
        guard glass, visible, overlayRect.width > 1, overlayRect.height > 1,
              let win = overlayView.window else {
            reclaim(content, to: overlayView)
            return
        }
        content.hostedInGlassPanel = true
        content.frame = NSRect(origin: .zero, size: overlayRect.size)
        if panel == nil {
            content.removeFromSuperview()
            panel = OverlayChromePanel(hosting: content, cornerRadius: cornerRadius, canBecomeKey: keyCapable)
            win.addChildWindow(panel!, ordered: .above)
        }
        let screenRect = win.convertToScreen(overlayView.convert(overlayRect, to: nil))
        panel?.place(at: screenRect)
    }

    /// Tear down the glass panel (if any), returning `content` to the overlay.
    func reclaim(_ content: (ChromeContent & NSView)?, to overlayView: NSView) {
        guard panel != nil else { return }
        if let content {
            content.hostedInGlassPanel = false
            content.removeFromSuperview()
            overlayView.addSubview(content)
        }
        disposePanel()
    }

    func teardown() { disposePanel() }

    private func disposePanel() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
        self.panel = nil
    }
}

/// Toolbar surfaces that can be hosted in a glass chrome panel. When hosted, the
/// surface must not draw its own solid background (the glass provides it).
protocol ChromeContent: AnyObject {
    var hostedInGlassPanel: Bool { get set }
}
