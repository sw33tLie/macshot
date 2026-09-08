import Cocoa
import UniformTypeIdentifiers

class TableRecognitionResultController: NSObject {
    private var window: NSPanel?
    private let table: RecognizedTable
    private let workbookData: Data
    private let temporaryWorkbookURL: URL
    private var removesTemporaryWorkbookOnClose = true

    /// Invoked once when the result window closes so its owner can release it.
    var onClose: (() -> Void)?

    init(table: RecognizedTable) throws {
        self.table = table
        self.workbookData = try XLSXWriter.data(for: table)
        self.temporaryWorkbookURL = TmpScratchDirectory.makeURL(
            filename: "recognized-table-\(UUID().uuidString).xlsx"
        )
        super.init()
        try workbookData.write(to: temporaryWorkbookURL, options: .atomic)
        buildWindow()
    }

    private func buildWindow() {
        let width: CGFloat = 760
        let height: CGFloat = 500
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.midY - height / 2
        )

        let panel = TableResultPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Table Recognition")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.minSize = NSSize(width: 620, height: 360)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        contentView.autoresizingMask = [.width, .height]

        let titleLabel = NSTextField(labelWithString: L("Table recognition succeeded"))
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: height - 42, width: width - 40, height: 24)
        titleLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(titleLabel)

        let summary = String(
            format: L("%d rows · %d columns"),
            table.rows.count,
            table.columnCount
        )
        let summaryLabel = NSTextField(labelWithString: summary)
        summaryLabel.font = NSFont.systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.frame = NSRect(x: 20, y: height - 64, width: width - 40, height: 18)
        summaryLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(summaryLabel)

        let footerHeight: CGFloat = 64
        let scrollView = NSScrollView(frame: NSRect(
            x: 20,
            y: footerHeight,
            width: width - 40,
            height: height - footerHeight - 78
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let preview = NSTableView()
        preview.dataSource = self
        preview.delegate = self
        preview.usesAlternatingRowBackgroundColors = true
        preview.rowHeight = 25
        preview.columnAutoresizingStyle = .noColumnAutoresizing
        for column in 0..<table.columnCount {
            let identifier = NSUserInterfaceItemIdentifier("column-\(column)")
            let tableColumn = NSTableColumn(identifier: identifier)
            tableColumn.title = Self.columnName(column)
            tableColumn.width = 120
            tableColumn.minWidth = 60
            tableColumn.maxWidth = 360
            preview.addTableColumn(tableColumn)
        }
        scrollView.documentView = preview
        contentView.addSubview(scrollView)

        let separator = NSBox(frame: NSRect(x: 0, y: footerHeight - 1, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(separator)

        let buttonStack = NSStackView(frame: NSRect(x: 20, y: 18, width: width - 40, height: 30))
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 8
        buttonStack.autoresizingMask = [.width, .maxYMargin]

        let openButton = makeButton(title: L("Open Excel File"), action: #selector(openExcelFile))
        let saveButton = makeButton(title: L("Save As..."), action: #selector(saveAs))
        let copyFileButton = makeButton(title: L("Copy Excel File"), action: #selector(copyExcelFile))
        let copyTSVButton = makeButton(title: L("Copy as TSV"), action: #selector(copyAsTSV))
        let closeButton = makeButton(title: L("Close"), action: #selector(close))
        for button in [openButton, saveButton, copyFileButton, copyTSVButton, closeButton] {
            buttonStack.addArrangedSubview(button)
        }
        contentView.addSubview(buttonStack)

        panel.contentView = contentView
        self.window = panel
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openExcelFile() {
        guard NSWorkspace.shared.open(temporaryWorkbookURL) else {
            showOpenError()
            return
        }
        removesTemporaryWorkbookOnClose = false
        close()
    }

    @objc private func saveAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = L("Save Recognized Table")
        panel.nameFieldStringValue = L("Recognized Table.xlsx")
        if let xlsxType = UTType(filenameExtension: "xlsx") {
            panel.allowedContentTypes = [xlsxType]
        }
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                try self.workbookData.write(to: url, options: .atomic)
                self.close()
            } catch {
                self.showWriteError(error)
            }
        }
    }

    @objc private func copyExcelFile() {
        guard let url = ClipboardBackingStore.writeFileData(
            workbookData,
            fileExtension: "xlsx"
        ) else {
            showWriteError(nil)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else {
            showWriteError(nil)
            return
        }
        close()
    }

    @objc private func copyAsTSV() {
        guard !table.tsv.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(table.tsv, forType: .string)
        close()
    }

    @objc func close() {
        window?.close()
    }

    private func showWriteError(_ error: Error?) {
        let alert = NSAlert()
        alert.messageText = L("Could Not Create Excel File")
        alert.informativeText = error?.localizedDescription
            ?? L("The Excel file could not be written. Please try again.")
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        }
    }

    private func showOpenError() {
        let alert = NSAlert()
        alert.messageText = L("Could Not Open Excel File")
        alert.informativeText = L("No application is available to open Excel files.")
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        }
    }

    private static func columnName(_ zeroBasedIndex: Int) -> String {
        var index = zeroBasedIndex + 1
        var result = ""
        while index > 0 {
            index -= 1
            result = String(UnicodeScalar(65 + index % 26)!) + result
            index /= 26
        }
        return result
    }
}

extension TableRecognitionResultController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        table.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let column = Int(tableColumn.identifier.rawValue.replacingOccurrences(of: "column-", with: ""))
        else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("recognized-table-cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            cell.wantsLayer = true
            cell.layer?.masksToBounds = true
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.usesSingleLineMode = true
            textField.maximumNumberOfLines = 1
            textField.lineBreakMode = .byTruncatingTail
            textField.cell?.truncatesLastVisibleLine = true
            textField.isSelectable = true
            cell.textField = textField
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let value = column < table.rows[row].count ? table.rows[row][column] : ""
        cell.textField?.stringValue = value.replacingOccurrences(of: "\n", with: " ↵ ")
        cell.textField?.toolTip = value.isEmpty ? nil : value
        return cell
    }
}

extension TableRecognitionResultController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard window != nil else { return }
        if removesTemporaryWorkbookOnClose {
            try? FileManager.default.removeItem(at: temporaryWorkbookURL)
        }
        window?.delegate = nil
        window = nil
        onClose?()
        onClose = nil
        MainActor.assumeIsolated {
            (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
        }
    }
}

private class TableResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 13 {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
