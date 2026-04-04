import Cocoa

/// A small floating toast shown after a recording completes.
/// Shows the filename with "Open in Finder" and "Copy Path" buttons.
final class RecordingToastView: NSView {

    private let url: URL

    init(frame: NSRect, url: URL) {
        self.url = url
        super.init(frame: frame)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.92).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = NSColor(red: 0.3, green: 0.85, blue: 0.45, alpha: 1)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let openBtn = makeButton(title: L("Show in Finder"), action: #selector(openInFinder))
        let copyBtn = makeButton(title: L("Copy Path"), action: #selector(copyPath))

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: copyBtn.leadingAnchor, constant: -8),

            copyBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            copyBtn.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),

            openBtn.trailingAnchor.constraint(equalTo: copyBtn.leadingAnchor, constant: -6),
            openBtn.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
        ])

        // Subtitle with format info
        let ext = url.pathExtension.uppercased()
        let sub = NSTextField(labelWithString: ext.isEmpty ? L("Recording saved") : String(format: L("%@ • Recording saved"), ext))
        sub.textColor = NSColor(white: 0.6, alpha: 1)
        sub.font = .systemFont(ofSize: 10)
        sub.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sub)
        NSLayoutConstraint.activate([
            sub.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            sub.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ])
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .inline
        btn.controlSize = .small
        btn.isBordered = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(btn)
        return btn
    }

    @objc private func openInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
