import AppKit

@MainActor
final class VocabularyEditorView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private let service: TiroService
    private let profilePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "Complete both columns")
    private var globalEntries: [VocabularyEntry] = []
    private var globalBaseline: [VocabularyEntry] = []
    private var profilesDocument = VocabularyProfilesDocument()
    private var profileBaselines: [String: VocabularyProfile] = [:]
    private var entries: [VocabularyEntry] = []
    private var hasUnsavedChanges = false
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0
    private var loadGeneration = 0
    private var editRevision = 0
    private var refreshPending = false

    init(service: TiroService) {
        self.service = service
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        saveTask?.cancel()
    }

    func load() {
        guard !hasUnsavedChanges else {
            refreshPending = true
            return
        }
        refreshPending = false
        loadGeneration += 1
        let generation = loadGeneration
        let startingEditRevision = editRevision
        let selectedBundleID = selectedProfile?.bundle_id
        do {
            globalEntries = try VocabularyFile.load()
            globalBaseline = globalEntries
            setEditorEnabled(true)
            if selectedBundleID == nil {
                entries = globalEntries
                table.reloadData()
                updateValidation()
            }
        } catch {
            setEditorEnabled(false)
            NSLog("Could not load Tiro vocabulary: %@", error.localizedDescription)
            return
        }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await service.vocabularyProfiles()
                guard !Task.isCancelled,
                      generation == loadGeneration,
                      startingEditRevision == editRevision else { return }
                let bundleToKeepSelected = selectedProfile?.bundle_id
                profilesDocument = document
                profileBaselines = Self.profilesByBundleID(document.profiles)
                rebuildProfilePicker(selectingBundleID: bundleToKeepSelected)
            } catch {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                NSLog("Could not load Tiro vocabulary profiles: %@", error.localizedDescription)
            }
        }
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 10

        let label = NSTextField(labelWithString: "Vocabulary")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        profilePicker.addItem(withTitle: "Global")
        profilePicker.target = self
        profilePicker.action = #selector(profileChanged)
        profilePicker.toolTip = "Choose vocabulary scope"
        profilePicker.setAccessibilityLabel("Vocabulary scope")

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
        addArrangedSubview(profilePicker)
        addArrangedSubview(scrollView)
        addArrangedSubview(controls)

        profilePicker.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scrollView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
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

    private func rebuildProfilePicker(selectingBundleID bundleID: String?) {
        let selectedBundleID = bundleID ?? selectedProfile?.bundle_id
        profilePicker.removeAllItems()
        profilePicker.addItem(withTitle: "Global")
        for profile in profilesDocument.profiles {
            let title = profile.name.isEmpty ? profile.displayBundleID : profile.displayName
            profilePicker.addItem(withTitle: title)
            profilePicker.lastItem?.representedObject = profile.bundle_id
            profilePicker.lastItem?.toolTip = profile.displayBundleID
        }
        if let selectedBundleID,
           let index = profilesDocument.profiles.firstIndex(where: { $0.bundle_id == selectedBundleID }) {
            profilePicker.selectItem(at: index + 1)
        } else {
            profilePicker.selectItem(at: 0)
        }
        showSelectedEntries()
    }

    private var selectedProfileIndex: Int? {
        let index = profilePicker.indexOfSelectedItem - 1
        return profilesDocument.profiles.indices.contains(index) ? index : nil
    }

    private var selectedProfile: VocabularyProfile? {
        guard let index = selectedProfileIndex else { return nil }
        return profilesDocument.profiles[index]
    }

    private func showSelectedEntries() {
        entries = selectedProfile?.entries ?? globalEntries
        table.deselectAll(nil)
        table.reloadData()
        removeButton.isEnabled = false
        updateValidation()
    }

    @objc private func profileChanged() {
        window?.makeFirstResponder(nil)
        showSelectedEntries()
    }

    private func save() {
        if let index = selectedProfileIndex {
            profilesDocument.profiles[index].entries = entries
            guard !entries.contains(where: { $0.spoken.isEmpty || $0.written.isEmpty }) else {
                hasUnsavedChanges = true
                return
            }
            saveProfiles()
        } else {
            globalEntries = entries
            guard !entries.contains(where: { $0.spoken.isEmpty || $0.written.isEmpty }) else {
                hasUnsavedChanges = true
                return
            }
            saveGlobalVocabulary()
        }
    }

    private func saveGlobalVocabulary() {
        saveGeneration += 1
        let generation = saveGeneration
        let editedEntries = globalEntries
        let baselineEntries = globalBaseline
        let revision = editRevision
        let previousSave = saveTask
        hasUnsavedChanges = true
        setSaving(true)
        saveTask = Task { [weak self] in
            _ = await previousSave?.value
            guard let self, !Task.isCancelled else { return }
            do {
                let savedEntries = try await service.saveGlobalVocabulary(
                    editedEntries,
                    replacing: baselineEntries
                )
                guard !Task.isCancelled,
                      generation == saveGeneration,
                      revision == editRevision else { return }
                globalEntries = savedEntries
                globalBaseline = savedEntries
                entries = savedEntries
                table.reloadData()
                hasUnsavedChanges = false
                table.backgroundColor = .textBackgroundColor
                setSaving(false)
                performPendingRefreshIfNeeded()
            } catch {
                guard !Task.isCancelled, generation == saveGeneration else { return }
                setSaving(false)
                markSaveFailed(error)
            }
        }
    }

    private func saveProfiles() {
        saveGeneration += 1
        let generation = saveGeneration
        let document = profilesDocument
        guard let profileIndex = selectedProfileIndex else { return }
        let editedProfile = document.profiles[profileIndex]
        let baselineProfile = profileBaselines[editedProfile.bundle_id]
            ?? VocabularyProfile(
                bundle_id: editedProfile.bundle_id,
                name: editedProfile.name,
                entries: []
            )
        let revision = editRevision
        let previousSave = saveTask
        hasUnsavedChanges = true
        setSaving(true)
        saveTask = Task { [weak self] in
            _ = await previousSave?.value
            guard let self, !Task.isCancelled else { return }
            do {
                let savedDocument = try await service.saveVocabularyProfile(
                    editedProfile,
                    replacing: baselineProfile
                )
                guard !Task.isCancelled,
                      generation == saveGeneration,
                      revision == editRevision else { return }
                let selectedBundleID = selectedProfile?.bundle_id
                profilesDocument = savedDocument
                profileBaselines = Self.profilesByBundleID(savedDocument.profiles)
                hasUnsavedChanges = false
                table.backgroundColor = .textBackgroundColor
                rebuildProfilePicker(selectingBundleID: selectedBundleID)
                setSaving(false)
                performPendingRefreshIfNeeded()
            } catch {
                guard !Task.isCancelled, generation == saveGeneration else { return }
                setSaving(false)
                markSaveFailed(error)
            }
        }
    }

    private func markSaveFailed(_ error: Error) {
        hasUnsavedChanges = true
        table.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12)
        window?.presentError(error)
        NSLog("Could not save Tiro vocabulary: %@", error.localizedDescription)
    }

    private func performPendingRefreshIfNeeded() {
        guard refreshPending else { return }
        load()
    }

    private func setEditorEnabled(_ enabled: Bool) {
        table.isEnabled = enabled
        profilePicker.isEnabled = enabled
        addButton.isEnabled = enabled
        table.backgroundColor = enabled ? .textBackgroundColor : .controlBackgroundColor
    }

    private func setSaving(_ saving: Bool) {
        table.isEnabled = !saving
        profilePicker.isEnabled = !saving
        addButton.isEnabled = !saving
        removeButton.isEnabled = !saving && table.selectedRow >= 0
    }

    private func updateValidation() {
        statusLabel.isHidden = !entries.contains { $0.spoken.isEmpty != $0.written.isEmpty }
    }

    private static func profilesByBundleID(
        _ profiles: [VocabularyProfile]
    ) -> [String: VocabularyProfile] {
        Dictionary(profiles.map { ($0.bundle_id, $0) }, uniquingKeysWith: { _, last in last })
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
        editRevision += 1
        entries.append(VocabularyEntry(spoken: "", written: ""))
        if let index = selectedProfileIndex {
            profilesDocument.profiles[index].entries = entries
            hasUnsavedChanges = true
        } else {
            globalEntries = entries
            hasUnsavedChanges = true
        }
        let row = entries.count - 1
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeEntry() {
        let row = table.selectedRow
        guard entries.indices.contains(row) else { return }
        editRevision += 1
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
        editRevision += 1
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
