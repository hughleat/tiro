import AppKit

@MainActor
final class SnippetEditorView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private let workerClient: WorkerClient
    private let table = NSTableView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var snippets: [UserSnippet] = []
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var generation = 0
    private var editState = SnippetEditState()
    private let maximumSnippetCount = 200

    init(workerClient: WorkerClient) {
        self.workerClient = workerClient
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        saveTask?.cancel()
    }

    func load() {
        if editState.hasDirtyEdits {
            saveDirtySnippets()
            return
        }
        generation += 1
        let requestGeneration = generation
        let pendingMutation = saveTask
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = await pendingMutation?.value
                guard !Task.isCancelled, requestGeneration == generation else { return }
                let loaded = try await workerClient.snippets()
                guard !Task.isCancelled, requestGeneration == generation,
                      !editState.hasDirtyEdits else { return }
                snippets = loaded
                table.reloadData()
                updateValidation()
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                showError(error)
            }
        }
    }

    func cancelWork() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let label = NSTextField(labelWithString: "Snippets")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        table.addTableColumn(column(identifier: "trigger", title: "When Tiro hears"))
        table.addTableColumn(column(identifier: "content", title: "Tiro inserts"))
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table

        configure(addButton, symbol: "plus", tooltip: "Add snippet", action: #selector(addSnippet))
        configure(removeButton, symbol: "minus", tooltip: "Remove selected snippet", action: #selector(removeSnippet))
        removeButton.isEnabled = false
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = true
        statusLabel.lineBreakMode = .byTruncatingTail

        let controls = NSStackView(views: [addButton, removeButton, statusLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6
        addArrangedSubview(label)
        addArrangedSubview(scrollView)
        addArrangedSubview(controls)
        scrollView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
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
        button.setAccessibilityLabel(tooltip)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snippets.count }

    func tableView(
        _ tableView: NSTableView,
        objectValueFor tableColumn: NSTableColumn?,
        row: Int
    ) -> Any? {
        guard snippets.indices.contains(row) else { return nil }
        return tableColumn?.identifier.rawValue == "trigger"
            ? snippets[row].trigger
            : snippets[row].content
    }

    func tableView(
        _ tableView: NSTableView,
        setObjectValue object: Any?,
        for tableColumn: NSTableColumn?,
        row: Int
    ) {
        guard snippets.indices.contains(row), let value = object as? String else { return }
        if tableColumn?.identifier.rawValue == "trigger" { snippets[row].trigger = value }
        else { snippets[row].content = value }
        markDirty(snippets[row].id)
        updateValidation()
        saveDirtySnippets()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = snippets.indices.contains(table.selectedRow)
    }

    @objc private func addSnippet() {
        guard snippets.count < maximumSnippetCount else { return }
        snippets.append(UserSnippet(id: UUID().uuidString, trigger: "", content: ""))
        markDirty(snippets.last!.id)
        table.reloadData()
        let row = snippets.count - 1
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.editColumn(0, row: row, with: nil, select: true)
        updateValidation()
    }

    @objc private func removeSnippet() {
        let row = table.selectedRow
        guard snippets.indices.contains(row) else { return }
        let removed = snippets.remove(at: row)
        editState.remove(removed.id)
        invalidateLoad()
        table.reloadData()
        removeButton.isEnabled = false
        updateValidation()
        let previousSave = saveTask
        saveTask = Task { [weak self] in
            _ = await previousSave?.value
            guard let self else { return }
            do { try await workerClient.deleteSnippet(id: removed.id) }
            catch {
                guard !Task.isCancelled,
                      !snippets.contains(where: { $0.id == removed.id }) else { return }
                snippets.insert(removed, at: min(row, snippets.count))
                markDirty(removed.id)
                table.reloadData()
                showError(error)
            }
        }
    }

    private func markDirty(_ id: String) {
        invalidateLoad()
        editState.markDirty(id)
    }

    private func invalidateLoad() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
    }

    private func saveDirtySnippets() {
        guard canSave else { return }
        for snippet in snippets where editState.dirtyIDs.contains(snippet.id) && isValid(snippet) {
            guard let revision = editState.revisionToQueue(for: snippet.id) else { continue }
            save(snippet, revision: revision)
        }
    }

    private func save(_ snippet: UserSnippet, revision: Int) {
        let previousSave = saveTask
        saveTask = Task { [weak self] in
            _ = await previousSave?.value
            guard let self else { return }
            do {
                let saved = try await workerClient.saveSnippet(snippet)
                guard !Task.isCancelled,
                      editState.saveSucceeded(id: saved.id, revision: revision),
                      let index = snippets.firstIndex(where: { $0.id == saved.id }) else { return }
                snippets[index] = saved
                updateValidation()
            } catch {
                guard !Task.isCancelled else { return }
                editState.saveFailed(id: snippet.id, revision: revision)
                showError(error)
            }
        }
    }

    private func isValid(_ snippet: UserSnippet) -> Bool {
        !snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !snippet.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && snippet.trigger.unicodeScalars.count <= 200
            && snippet.content.unicodeScalars.count <= 2_000
    }

    private func updateValidation() {
        addButton.isEnabled = snippets.count < maximumSnippetCount
        let normalized = snippets.map { normalizedTrigger($0.trigger) }
        let duplicates = normalized.filter { !$0.isEmpty }.count != Set(normalized.filter { !$0.isEmpty }).count
        if duplicates { showStatus("Triggers must be unique") }
        else if snippets.contains(where: {
            $0.trigger.unicodeScalars.count > 200 || $0.content.unicodeScalars.count > 2_000
        }) {
            showStatus("Snippet is too long")
        } else if snippets.contains(where: { !isValid($0) }) { showStatus("Complete both columns") }
        else if editState.hasFailures { showStatus("Some snippets could not be saved") }
        else { showStatus(nil) }
    }

    private var canSave: Bool {
        let triggers = snippets
            .map { normalizedTrigger($0.trigger) }
            .filter { !$0.isEmpty }
        return triggers.count == Set(triggers).count
    }

    private func normalizedTrigger(_ trigger: String) -> String {
        VocabularyEntry.normalized(
            trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func showError(_ error: Error) {
        showStatus(error.localizedDescription)
    }

    private func showStatus(_ message: String?) {
        statusLabel.stringValue = message ?? ""
        statusLabel.toolTip = message
        statusLabel.isHidden = message == nil
    }
}
