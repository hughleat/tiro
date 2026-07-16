import AppKit
import AVFoundation

@MainActor
final class HistoryView: NSStackView, NSSearchFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate, AVAudioPlayerDelegate {
    var onCorrectionSaved: (() -> Void)?

    private let workerClient: WorkerClient
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let stateLabel = NSTextField(labelWithString: "")
    private var entries: [HistoryEntry] = []
    private var searchTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var correctionTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var audioPlayer: AVAudioPlayer?
    private var playingEntryID: String?

    init(workerClient: WorkerClient) {
        self.workerClient = workerClient
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        searchTask?.cancel()
        audioTask?.cancel()
        correctionTask?.cancel()
    }

    func refresh() {
        scheduleSearch(after: nil)
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 8

        searchField.placeholderString = "Search transcriptions"
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search transcription history")

        let controls = NSStackView(views: [searchField])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.title = "Transcriptions"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 66
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table

        stateLabel.alignment = .center
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 3
        stateLabel.lineBreakMode = .byWordWrapping
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        let tableContainer = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tableContainer.addSubview(scrollView)
        tableContainer.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableContainer.leadingAnchor, constant: 24),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableContainer.trailingAnchor, constant: -24),
            stateLabel.centerXAnchor.constraint(equalTo: tableContainer.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: tableContainer.centerYAnchor)
        ])

        addArrangedSubview(controls)
        addArrangedSubview(tableContainer)
        controls.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        tableContainer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    func controlTextDidChange(_ notification: Notification) {
        scheduleSearch(after: 250_000_000)
    }

    private func scheduleSearch(after delay: UInt64?) {
        searchTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if entries.isEmpty { showState("Loading history...") }

        searchTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            do {
                let results = try await workerClient.searchHistory(query: query, limit: 200)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                entries = newestFirst(results)
                table.reloadData()
                showState(entries.isEmpty ? (query.isEmpty ? "No transcriptions yet." : "No matching transcriptions.") : nil)
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                entries = []
                table.reloadData()
                showState("Could not load history.\n\(error.localizedDescription)")
            }
        }
    }

    private func newestFirst(_ results: [HistoryEntry]) -> [HistoryEntry] {
        results.enumerated().sorted { lhs, rhs in
            let left = Self.parseDate(lhs.element.timestamp)
            let right = Self.parseDate(rhs.element.timestamp)
            if left == right { return lhs.offset < rhs.offset }
            return (left ?? .distantPast) > (right ?? .distantPast)
        }.map(\.element)
    }

    private func showState(_ message: String?) {
        stateLabel.stringValue = message ?? ""
        stateLabel.isHidden = message == nil
        table.isHidden = message != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("HistoryRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryRowView)
            ?? HistoryRowView(identifier: identifier)
        let entry = entries[row]
        cell.configure(
            entry: entry,
            metadata: metadata(for: entry),
            row: row,
            isPlaying: playingEntryID == entry.id,
            target: self
        )
        return cell
    }

    private func metadata(for entry: HistoryEntry) -> String {
        let date = Self.parseDate(entry.timestamp).map(Self.dateFormatter.string) ?? entry.timestamp
        let model = entry.model.split(separator: "/").last.map(String.init) ?? entry.model
        let duration = String(format: "%.1fs", entry.transcription_seconds)
        return [date, model, duration].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    @objc fileprivate func copyEntry(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entries[sender.tag].displayText, forType: .string)
    }

    @objc fileprivate func correctEntry(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let entry = entries[sender.tag]
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
        field.stringValue = entry.corrected_text ?? entry.text
        field.placeholderString = "Corrected transcription"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Corrected transcription")

        let alert = NSAlert()
        alert.messageText = "Correct Transcription"
        alert.informativeText = "Save the text exactly as it should have been transcribed."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak field] response in
            guard response == .alertFirstButtonReturn, let correctedText = field?.stringValue else { return }
            self?.performCorrection(entry, correctedText: correctedText)
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                completion(response)
            }
        } else {
            completion(alert.runModal())
        }
    }

    private func performCorrection(_ entry: HistoryEntry, correctedText: String) {
        correctionTask?.cancel()
        correctionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await workerClient.correctHistoryEntry(id: entry.id, correctedText: correctedText)
                guard !Task.isCancelled else { return }
                onCorrectionSaved?()
                refresh()
            } catch {
                guard !Task.isCancelled else { return }
                window?.presentError(error)
            }
        }
    }

    @objc fileprivate func togglePlayback(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let entry = entries[sender.tag]
        if playingEntryID == entry.id {
            stopPlayback()
            return
        }

        stopPlayback()
        playingEntryID = entry.id
        table.reloadData()
        audioTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await workerClient.historyAudio(id: entry.id)
                guard !Task.isCancelled, playingEntryID == entry.id else { return }
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                guard player.prepareToPlay(), player.play() else {
                    throw WorkerError.server("The recording could not be played.")
                }
                audioPlayer = player
            } catch {
                guard !Task.isCancelled else { return }
                stopPlayback()
                window?.presentError(error)
            }
        }
    }

    private func stopPlayback() {
        audioTask?.cancel()
        audioTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        guard playingEntryID != nil else { return }
        playingEntryID = nil
        table.reloadData()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, audioPlayer === player else { return }
            stopPlayback()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, audioPlayer === player else { return }
            stopPlayback()
            window?.presentError(error ?? WorkerError.server("The recording could not be decoded."))
        }
    }

    @objc fileprivate func deleteEntry(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }
        let entry = entries[sender.tag]
        let alert = NSAlert()
        alert.messageText = "Delete this transcription?"
        alert.informativeText = "The transcript and its recording will be permanently deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(entry)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func performDelete(_ entry: HistoryEntry) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await workerClient.deleteHistoryEntry(id: entry.id)
                if playingEntryID == entry.id { stopPlayback() }
                refresh()
            } catch {
                window?.presentError(error)
            }
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        ISO8601DateFormatter.tiroWithFractionalSeconds.date(from: value)
            ?? ISO8601DateFormatter.tiroWithoutFractionalSeconds.date(from: value)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

private final class HistoryRowView: NSTableCellView {
    private let excerptLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let correctButton = NSButton()
    private let playButton = NSButton()
    private let deleteButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        excerptLabel.font = .systemFont(ofSize: 13)
        excerptLabel.maximumNumberOfLines = 2
        excerptLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingMiddle

        let labels = NSStackView(views: [excerptLabel, metadataLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let buttons = NSStackView(views: [copyButton, correctButton, playButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        addSubview(buttons)

        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        for button in [copyButton, correctButton, playButton, deleteButton] {
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        excerptLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        metadataLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
    }

    func configure(
        entry: HistoryEntry,
        metadata: String,
        row: Int,
        isPlaying: Bool,
        target: HistoryView
    ) {
        excerptLabel.stringValue = entry.displayText.isEmpty ? "Untitled transcription" : entry.displayText
        metadataLabel.stringValue = metadata
        configure(copyButton, symbol: "doc.on.doc", label: "Copy transcript", row: row, target: target,
                  action: #selector(HistoryView.copyEntry(_:)))
        configure(correctButton, symbol: "square.and.pencil", label: "Correct transcript", row: row,
                  target: target, action: #selector(HistoryView.correctEntry(_:)))
        configure(playButton, symbol: isPlaying ? "stop.fill" : "play.fill",
                  label: isPlaying ? "Stop playback" : "Play recording", row: row, target: target,
                  action: #selector(HistoryView.togglePlayback(_:)))
        playButton.isEnabled = entry.audio_available
        configure(deleteButton, symbol: "trash", label: "Delete transcription", row: row, target: target,
                  action: #selector(HistoryView.deleteEntry(_:)))
    }

    private func configure(
        _ button: NSButton,
        symbol: String,
        label: String,
        row: Int,
        target: AnyObject,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.tag = row
        button.target = target
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
}

private extension ISO8601DateFormatter {
    static let tiroWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let tiroWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
