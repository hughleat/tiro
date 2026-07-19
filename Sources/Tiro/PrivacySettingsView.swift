import AppKit

@MainActor
final class PrivacySettingsView: NSStackView {
    var onStoredDataChanged: (() -> Void)?
    var onSettingsLoaded: (() -> Void)?

    private static let retentionOptions = [1, 7, 30, 90, 0]

    private let service: TiroService
    private let historySwitch = NSSwitch()
    private let recordingsSwitch = NSSwitch()
    private let retentionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let deleteButton = NSButton(title: "Delete All History...", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var settings: PrivacySettings?
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?

    init(service: TiroService) {
        self.service = service
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        mutationTask?.cancel()
    }

    func refresh() {
        guard mutationTask == nil else { return }
        loadTask?.cancel()
        setControlsEnabled(false)
        statusLabel.stringValue = "Loading privacy settings..."
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await service.privacySettings()
                guard !Task.isCancelled else { return }
                settings = loaded
                statusLabel.stringValue = ""
                retryButton.isHidden = true
                render()
                onSettingsLoaded?()
            } catch {
                guard !Task.isCancelled else { return }
                statusLabel.stringValue = "Privacy settings could not be loaded."
                retryButton.isHidden = false
                setControlsEnabled(false)
            }
        }
    }

    func cancelWork() {
        loadTask?.cancel()
        loadTask = nil
        mutationTask?.cancel()
        mutationTask = nil
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 0

        let localOnly = NSTextField(wrappingLabelWithString:
            "Transcription runs locally on this Mac. Tiro only keeps the history and recordings you choose."
        )
        localOnly.textColor = .secondaryLabelColor

        historySwitch.target = self
        historySwitch.action = #selector(historyChanged)
        historySwitch.setAccessibilityLabel("Save transcription history")
        recordingsSwitch.target = self
        recordingsSwitch.action = #selector(recordingsChanged)
        recordingsSwitch.setAccessibilityLabel("Keep recordings after transcription")

        retentionPicker.addItems(withTitles: ["1 day", "7 days", "30 days", "90 days", "Forever"])
        retentionPicker.target = self
        retentionPicker.action = #selector(retentionChanged)
        retentionPicker.setAccessibilityLabel("History retention")

        deleteButton.bezelStyle = .rounded
        deleteButton.hasDestructiveAction = true
        deleteButton.target = self
        deleteButton.action = #selector(confirmDeleteAll)
        deleteButton.setAccessibilityLabel("Delete all transcription history")

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryLoad)
        retryButton.isHidden = true

        let storageLabel = sectionLabel("Future Dictations")
        let historyRow = preferenceRow(
            title: "Save transcription history",
            detail: "Keeps transcript text, model details, and the originating app.",
            control: historySwitch
        )
        let recordingsRow = preferenceRow(
            title: "Keep recordings",
            detail: "Keeps audio for playback and model comparison. Otherwise it is discarded after transcription.",
            control: recordingsSwitch
        )
        let retentionRow = preferenceRow(
            title: "Keep history for",
            detail: "Older transcripts and their recordings are removed from Tiro automatically.",
            control: retentionPicker
        )

        let existingLabel = sectionLabel("Existing Data")
        let deleteText = NSTextField(wrappingLabelWithString:
            "Remove all transcripts, recordings, corrections, and suggestion evidence currently stored by Tiro."
        )
        deleteText.textColor = .secondaryLabelColor
        let deleteRow = NSStackView(views: [deleteText, deleteButton])
        deleteRow.orientation = .horizontal
        deleteRow.alignment = .centerY
        deleteRow.spacing = 18

        let statusRow = NSStackView(views: [statusLabel, NSView(), retryButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
        let historyDivider = divider()
        let recordingsDivider = divider()

        for view in [
            localOnly, storageLabel, historyRow, historyDivider, recordingsRow,
            recordingsDivider, retentionRow, existingLabel, deleteRow, statusRow,
        ] {
            addArrangedSubview(view)
        }
        setCustomSpacing(24, after: localOnly)
        setCustomSpacing(10, after: storageLabel)
        setCustomSpacing(28, after: retentionRow)
        setCustomSpacing(10, after: existingLabel)
        setCustomSpacing(14, after: deleteRow)

        for view in [
            localOnly, historyRow, historyDivider, recordingsRow, recordingsDivider,
            retentionRow, deleteRow, statusRow,
        ] {
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        render()
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func preferenceRow(title: String, detail: String, control: NSView) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        control.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [labels, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        return row
    }

    private func divider() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func render() {
        guard let settings else {
            historySwitch.state = .off
            recordingsSwitch.state = .off
            retentionPicker.selectItem(at: 2)
            setControlsEnabled(false)
            return
        }
        historySwitch.state = settings.store_history ? .on : .off
        recordingsSwitch.state = settings.store_recordings ? .on : .off
        retentionPicker.selectItem(at: Self.retentionOptions.firstIndex(of: settings.retention_days) ?? 2)
        setControlsEnabled(mutationTask == nil)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        historySwitch.isEnabled = enabled
        recordingsSwitch.isEnabled = enabled && settings?.store_history == true
        retentionPicker.isEnabled = enabled
        deleteButton.isEnabled = mutationTask == nil
        retryButton.isEnabled = mutationTask == nil
        recordingsSwitch.setAccessibilityHelp(
            recordingsSwitch.isEnabled
                ? "Keep audio after transcription"
                : "Enable transcription history before keeping recordings"
        )
    }

    @objc private func historyChanged() {
        guard let settings else { return }
        let enabled = historySwitch.state == .on
        let announcement = !enabled && settings.store_recordings
            ? "Recording storage turned off because transcription history is off."
            : nil
        save(PrivacySettings(
            store_history: enabled,
            store_recordings: enabled && settings.store_recordings,
            retention_days: settings.retention_days
        ), successAnnouncement: announcement)
    }

    @objc private func recordingsChanged() {
        guard let settings else { return }
        save(PrivacySettings(
            store_history: settings.store_history,
            store_recordings: recordingsSwitch.state == .on,
            retention_days: settings.retention_days
        ))
    }

    @objc private func retentionChanged() {
        guard let settings,
              Self.retentionOptions.indices.contains(retentionPicker.indexOfSelectedItem) else { return }
        let days = Self.retentionOptions[retentionPicker.indexOfSelectedItem]
        guard days != settings.retention_days else { return }
        guard days != 0 else {
            save(settings.withRetention(days))
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keep only the last \(days) \(days == 1 ? "day" : "days")?"
        alert.informativeText = "Older transcripts and recordings will be removed from Tiro."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Apply")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                save(settings.withRetention(days))
            } else {
                render()
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func save(_ updated: PrivacySettings, successAnnouncement: String? = nil) {
        let previous = settings
        mutationTask?.cancel()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            setControlsEnabled(false)
            statusLabel.stringValue = "Saving..."
            do {
                let saved = try await service.updatePrivacySettings(updated)
                guard !Task.isCancelled else { return }
                settings = saved
                mutationTask = nil
                statusLabel.stringValue = ""
                render()
                onStoredDataChanged?()
                if let successAnnouncement {
                    NSAccessibility.post(
                        element: recordingsSwitch,
                        notification: .announcementRequested,
                        userInfo: [
                            .announcement: successAnnouncement,
                            .priority: NSAccessibilityPriorityLevel.high.rawValue,
                        ]
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                settings = previous
                mutationTask = nil
                statusLabel.stringValue = ""
                render()
                window?.presentError(error)
            }
        }
    }

    @objc private func confirmDeleteAll() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete all Tiro history?"
        alert.informativeText = "This removes transcripts, recordings, corrections, and suggestion evidence stored by Tiro."
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete All History")
        delete.hasDestructiveAction = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.deleteAll()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc private func retryLoad() {
        retryButton.isHidden = true
        refresh()
    }

    private func deleteAll() {
        guard mutationTask == nil else { return }
        mutationTask = Task { [weak self] in
            guard let self else { return }
            setControlsEnabled(false)
            statusLabel.stringValue = "Deleting Tiro history..."
            do {
                try await service.deleteAllHistory()
                guard !Task.isCancelled else { return }
                mutationTask = nil
                statusLabel.stringValue = "All Tiro history was removed."
                render()
                onStoredDataChanged?()
                NSAccessibility.post(
                    element: deleteButton,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: "All Tiro history was removed.",
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ]
                )
                window?.makeFirstResponder(deleteButton)
            } catch {
                guard !Task.isCancelled else { return }
                mutationTask = nil
                statusLabel.stringValue = ""
                render()
                window?.presentError(error)
            }
        }
    }
}

private extension PrivacySettings {
    func withRetention(_ days: Int) -> PrivacySettings {
        PrivacySettings(
            store_history: store_history,
            store_recordings: store_recordings,
            retention_days: days
        )
    }
}
