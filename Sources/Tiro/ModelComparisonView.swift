import AppKit

@MainActor
final class ModelComparisonView: NSStackView {
    private let service: TiroService
    private let recordingPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelChoices = NSStackView()
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let activityIndicator = NSProgressIndicator()
    private let resultsContainer = NSView()
    private let resultsScrollView = NSScrollView()
    private let resultsStack = NSStackView()
    private let stateLabel = NSTextField(labelWithString: "No comparison results.")
    private var history: [HistoryEntry] = []
    private var installedModels: [ManagedModel] = []
    private var selectedModelKeys: Set<String> = []
    private var modelChoiceButtons: [NSButton] = []
    private var historyTask: Task<Void, Never>?
    private var comparisonTask: Task<Void, Never>?
    private var comparisonID: String?

    init(service: TiroService) {
        self.service = service
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        historyTask?.cancel()
        comparisonTask?.cancel()
    }

    func refresh() {
        historyTask?.cancel()
        recordingPicker.isEnabled = false
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await service.searchHistory(limit: 200).filter(\.audio_available)
                guard !Task.isCancelled else { return }
                history = entries
                rebuildRecordingPicker()
            } catch {
                guard !Task.isCancelled else { return }
                history = []
                rebuildRecordingPicker()
            }
        }
    }

    func cancelWork() {
        historyTask?.cancel()
        historyTask = nil
        comparisonTask?.cancel()
        comparisonTask = nil
        if let comparisonID {
            service.cancelComparison(id: comparisonID)
        }
        comparisonID = nil
        setComparing(false)
    }

    func setModels(_ models: [ManagedModel]) {
        let previouslySelected = selectedModelKeys
        installedModels = models.filter(\.installed)
        selectedModelKeys = previouslySelected.intersection(installedModels.map(\.key))
        if selectedModelKeys.count < 2 {
            selectedModelKeys.formUnion(installedModels.prefix(2).map(\.key))
        }
        rebuildModelChoices()
        updateCompareButton()
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let recordingLabel = NSTextField(labelWithString: "Recording")
        recordingLabel.textColor = .secondaryLabelColor
        recordingLabel.setContentHuggingPriority(.required, for: .horizontal)
        recordingPicker.setAccessibilityLabel("Recording to compare")
        recordingPicker.target = self
        recordingPicker.action = #selector(selectionChanged)
        recordingPicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let recordingRow = NSStackView(views: [recordingLabel, recordingPicker])
        recordingRow.orientation = .horizontal
        recordingRow.alignment = .centerY
        recordingRow.spacing = 8

        modelChoices.orientation = .vertical
        modelChoices.alignment = .leading
        modelChoices.spacing = 5

        compareButton.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Compare models")
        compareButton.imagePosition = .imageLeading
        compareButton.target = self
        compareButton.action = #selector(compare)
        compareButton.setAccessibilityLabel("Compare selected models")
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isDisplayedWhenStopped = false
        let actionRow = NSStackView(views: [modelChoices, NSView(), activityIndicator, compareButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        resultsStack.orientation = .horizontal
        resultsStack.alignment = .top
        resultsStack.distribution = .fillEqually
        resultsStack.spacing = 14
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(resultsStack)
        resultsScrollView.documentView = document
        NSLayoutConstraint.activate([
            resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
            resultsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.heightAnchor.constraint(equalTo: resultsScrollView.contentView.heightAnchor)
        ])
        resultsScrollView.hasHorizontalScroller = true
        resultsScrollView.hasVerticalScroller = false
        resultsScrollView.drawsBackground = false
        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.alignment = .center
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.addSubview(resultsScrollView)
        resultsContainer.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            resultsScrollView.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            resultsScrollView.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
            resultsScrollView.topAnchor.constraint(equalTo: resultsContainer.topAnchor),
            resultsScrollView.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: resultsContainer.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: resultsContainer.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: resultsContainer.leadingAnchor, constant: 16),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: resultsContainer.trailingAnchor, constant: -16)
        ])

        addArrangedSubview(recordingRow)
        addArrangedSubview(actionRow)
        addArrangedSubview(resultsContainer)
        recordingRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        actionRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        resultsContainer.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        resultsContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 208).isActive = true
        updateCompareButton()
    }

    private func rebuildRecordingPicker() {
        let selectedID = selectedHistoryEntry?.id
        recordingPicker.removeAllItems()
        recordingPicker.addItems(withTitles: history.map(Self.recordingTitle))
        if let selectedID, let index = history.firstIndex(where: { $0.id == selectedID }) {
            recordingPicker.selectItem(at: index)
        }
        recordingPicker.isEnabled = !history.isEmpty && comparisonTask == nil
        recordingPicker.toolTip = history.isEmpty ? "No saved recordings are available" : nil
        updateCompareButton()
    }

    private func rebuildModelChoices() {
        for view in modelChoices.arrangedSubviews {
            modelChoices.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        modelChoiceButtons = []
        for (index, model) in installedModels.enumerated() {
            let button = NSButton(checkboxWithTitle: model.name, target: self, action: #selector(modelChoiceChanged(_:)))
            button.tag = index
            button.state = selectedModelKeys.contains(model.key) ? .on : .off
            button.setAccessibilityLabel("Include \(model.name) in comparison")
            modelChoiceButtons.append(button)
        }
        for start in stride(from: 0, to: modelChoiceButtons.count, by: 2) {
            let row = NSStackView(views: Array(modelChoiceButtons[start..<min(start + 2, modelChoiceButtons.count)]))
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            modelChoices.addArrangedSubview(row)
        }
        if installedModels.isEmpty {
            let label = NSTextField(labelWithString: "No installed models")
            label.textColor = .secondaryLabelColor
            modelChoices.addArrangedSubview(label)
        }
    }

    @objc private func modelChoiceChanged(_ sender: NSButton) {
        guard installedModels.indices.contains(sender.tag) else { return }
        let key = installedModels[sender.tag].key
        if sender.state == .on { selectedModelKeys.insert(key) }
        else { selectedModelKeys.remove(key) }
        updateCompareButton()
    }

    @objc private func selectionChanged() {
        updateCompareButton()
    }

    private var selectedHistoryEntry: HistoryEntry? {
        let index = recordingPicker.indexOfSelectedItem
        return history.indices.contains(index) ? history[index] : nil
    }

    private func updateCompareButton() {
        compareButton.isEnabled = comparisonTask == nil
            && selectedHistoryEntry != nil
            && selectedModelKeys.count >= 2
    }

    @objc private func compare() {
        if comparisonTask != nil {
            cancelWork()
            showState("Comparison cancelled.")
            return
        }
        guard let entry = selectedHistoryEntry else { return }
        let keys = installedModels.map(\.key).filter(selectedModelKeys.contains)
        guard keys.count >= 2 else { return }

        comparisonTask?.cancel()
        let comparisonID = UUID().uuidString
        self.comparisonID = comparisonID
        setComparing(true)
        showState("Comparing models...")
        comparisonTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await service.compareModels(
                    historyID: entry.id,
                    modelKeys: keys,
                    comparisonID: comparisonID
                )
                guard !Task.isCancelled else { return }
                comparisonTask = nil
                self.comparisonID = nil
                setComparing(false)
                show(results: results, requestedKeys: keys)
            } catch {
                guard !Task.isCancelled else { return }
                comparisonTask = nil
                self.comparisonID = nil
                setComparing(false)
                showState("Comparison failed.\n\(error.localizedDescription)")
            }
        }
    }

    private func setComparing(_ comparing: Bool) {
        recordingPicker.isEnabled = !comparing && !history.isEmpty
        for button in modelChoiceButtons { button.isEnabled = !comparing }
        if comparing { activityIndicator.startAnimation(nil) }
        else { activityIndicator.stopAnimation(nil) }
        compareButton.title = comparing ? "Cancel" : "Compare"
        compareButton.image = NSImage(
            systemSymbolName: comparing ? "xmark" : "rectangle.split.2x1",
            accessibilityDescription: comparing ? "Cancel comparison" : "Compare models"
        )
        if comparing {
            compareButton.isEnabled = true
        } else {
            updateCompareButton()
        }
    }

    private func show(results: [ModelComparisonResult], requestedKeys: [String]) {
        clearResults()
        let byKey = Dictionary(results.map { ($0.modelKey, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = requestedKeys.compactMap { byKey[$0] } + results.filter { !requestedKeys.contains($0.modelKey) }
        guard !ordered.isEmpty else {
            showState("No comparison results were returned.")
            return
        }
        for result in ordered {
            let knownName = installedModels.first(where: { $0.key == result.modelKey })?.name
            let column = ComparisonResultView(
                name: result.modelName ?? knownName ?? result.modelKey,
                seconds: result.transcriptionSeconds,
                transcript: result.text
            )
            resultsStack.addArrangedSubview(column)
            column.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
            column.heightAnchor.constraint(equalTo: resultsStack.heightAnchor).isActive = true
        }
        stateLabel.isHidden = true
        resultsScrollView.isHidden = false
    }

    private func showState(_ message: String) {
        clearResults()
        stateLabel.stringValue = message
        stateLabel.isHidden = false
        resultsScrollView.isHidden = true
    }

    private func clearResults() {
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private static func recordingTitle(_ entry: HistoryEntry) -> String {
        let excerpt = entry.displayText.replacingOccurrences(of: "\n", with: " ")
        let shortened = excerpt.count > 64 ? String(excerpt.prefix(61)) + "..." : excerpt
        guard let date = ISO8601DateFormatter.comparisonWithFraction.date(from: entry.timestamp)
            ?? ISO8601DateFormatter.comparisonWithoutFraction.date(from: entry.timestamp) else {
            return shortened.isEmpty ? "Untitled recording" : shortened
        }
        return "\(comparisonDateFormatter.string(from: date)) — \(shortened.isEmpty ? "Untitled recording" : shortened)"
    }

    private static let comparisonDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private final class ComparisonResultView: NSStackView {
    init(name: String, seconds: Double, transcript: String) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        let timingLabel = NSTextField(labelWithString: String(format: "%.2f seconds", seconds))
        timingLabel.font = .systemFont(ofSize: 11)
        timingLabel.textColor = .secondaryLabelColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 12)
        textView.string = transcript
        textView.textContainerInset = NSSize(width: 7, height: 7)
        textView.setAccessibilityLabel("Transcript from \(name)")
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        addArrangedSubview(nameLabel)
        addArrangedSubview(timingLabel)
        addArrangedSubview(scrollView)
        nameLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        timingLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scrollView.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }
}

private extension ISO8601DateFormatter {
    static let comparisonWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let comparisonWithoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
