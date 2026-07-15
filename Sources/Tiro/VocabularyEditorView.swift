import AppKit

final class VocabularyEditorView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "Complete both columns")
    private var entries: [VocabularyEntry] = []
    private var hasUnsavedChanges = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func load() {
        guard !hasUnsavedChanges else { return }
        do {
            entries = try VocabularyFile.load()
            table.isEnabled = true
            addButton.isEnabled = true
            table.backgroundColor = .textBackgroundColor
            table.reloadData()
            updateValidation()
        } catch {
            table.isEnabled = false
            addButton.isEnabled = false
            NSLog("Could not load Tiro vocabulary: %@", error.localizedDescription)
        }
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 10

        let label = NSTextField(labelWithString: "Vocabulary")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let spokenColumn = column(identifier: "spoken", title: "When Tiro hears")
        let writtenColumn = column(identifier: "written", title: "Tiro writes")
        table.addTableColumn(spokenColumn)
        table.addTableColumn(writtenColumn)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table

        configure(addButton, symbol: "plus", tooltip: "Add vocabulary", action: #selector(addEntry))
        configure(removeButton, symbol: "minus", tooltip: "Remove selected vocabulary", action: #selector(removeEntry))
        removeButton.isEnabled = false
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true

        let controls = NSStackView(views: [addButton, removeButton, statusLabel])
        controls.orientation = .horizontal
        controls.spacing = 6
        addArrangedSubview(label)
        addArrangedSubview(scrollView)
        addArrangedSubview(controls)

        scrollView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 140).isActive = true
    }

    private func column(identifier: String, title: String) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.minWidth = 180
        let cell = NSTextFieldCell()
        cell.isEditable = true
        column.dataCell = cell
        return column
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = tooltip
    }

    private func save() {
        do {
            try VocabularyFile.save(entries)
            hasUnsavedChanges = false
            table.backgroundColor = .textBackgroundColor
        } catch {
            hasUnsavedChanges = true
            table.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12)
            window?.presentError(error)
            NSLog("Could not save Tiro vocabulary: %@", error.localizedDescription)
        }
    }

    private func updateValidation() {
        statusLabel.isHidden = !entries.contains { $0.spoken.isEmpty != $0.written.isEmpty }
    }

    private func consolidateDuplicate(at row: Int) -> Int {
        let key = VocabularyEntry.normalized(entries[row].spoken)
        guard !key.isEmpty,
              let duplicate = entries.indices.first(where: {
                  $0 != row && VocabularyEntry.normalized(entries[$0].spoken) == key
              }) else { return row }
        if !entries[row].written.isEmpty { entries[duplicate].written = entries[row].written }
        entries.remove(at: row)
        return duplicate > row ? duplicate - 1 : duplicate
    }

    @objc private func addEntry() {
        entries.append(VocabularyEntry(spoken: "", written: ""))
        let row = entries.count - 1
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeEntry() {
        let row = table.selectedRow
        guard entries.indices.contains(row) else { return }
        entries.remove(at: row)
        table.reloadData()
        updateValidation()
        save()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard entries.indices.contains(row) else { return nil }
        return tableColumn?.identifier.rawValue == "spoken" ? entries[row].spoken : entries[row].written
    }

    func tableView(
        _ tableView: NSTableView,
        setObjectValue object: Any?,
        for tableColumn: NSTableColumn?,
        row: Int
    ) {
        guard entries.indices.contains(row), let value = object as? String else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if tableColumn?.identifier.rawValue == "spoken" { entries[row].spoken = trimmed }
        else { entries[row].written = trimmed }
        let selectedRow = consolidateDuplicate(at: row)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        updateValidation()
        save()
    }

    func tableView(
        _ tableView: NSTableView,
        willDisplayCell cell: Any,
        for tableColumn: NSTableColumn?,
        row: Int
    ) {
        guard let cell = cell as? NSTextFieldCell, entries.indices.contains(row) else { return }
        let entry = entries[row]
        cell.textColor = entry.spoken.isEmpty != entry.written.isEmpty ? .systemRed : .labelColor
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }
}
