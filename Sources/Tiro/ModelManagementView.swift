import AppKit

@MainActor
final class ModelManagementView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    var onModelChanged: ((DictationModel) -> Void)?
    var onModelsChanged: (([ManagedModel]) -> Void)?

    private enum Operation: Equatable {
        case downloading
        case deleting

        var label: String {
            switch self {
            case .downloading: return "Downloading..."
            case .deleting: return "Deleting..."
            }
        }
    }

    private let workerClient: WorkerClient
    private let table = NSTableView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let stateProgress = NSProgressIndicator()
    private let stateButton = NSButton()
    private enum StateAction { case retry }
    private var stateAction: StateAction?
    private var models: [ManagedModel] = []
    private var operations: [String: Operation] = [:]
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var isApplyingSelection = false

    init(workerClient: WorkerClient) {
        self.workerClient = workerClient
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
        mutationTask?.cancel()
        pollTask?.cancel()
    }

    func refresh() {
        loadTask?.cancel()
        if models.isEmpty { showState("Loading models...", loading: true) }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await workerClient.models()
                guard !Task.isCancelled else { return }
                apply(loaded)
            } catch {
                guard !Task.isCancelled else { return }
                if models.isEmpty {
                    showState("Could not load models.\n\(error.localizedDescription)", action: .retry)
                }
            }
        }
    }

    func cancelWork() {
        loadTask?.cancel()
        loadTask = nil
        mutationTask?.cancel()
        mutationTask = nil
        operations.removeAll()
        stopPolling()
        table.reloadData()
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Transcription models")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.alignment = .center
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 3
        stateLabel.lineBreakMode = .byWordWrapping
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        stateProgress.style = .spinning
        stateProgress.controlSize = .small
        stateProgress.isDisplayedWhenStopped = false
        stateButton.bezelStyle = .rounded
        stateButton.target = self
        stateButton.action = #selector(performStateAction)
        let stateStack = NSStackView(views: [stateProgress, stateLabel, stateButton])
        stateStack.orientation = .vertical
        stateStack.alignment = .centerX
        stateStack.spacing = 10
        stateStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(stateStack)
        addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 178).isActive = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stateStack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stateStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            stateStack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    private func apply(_ loaded: [ManagedModel]) {
        let knownOrder = Dictionary(uniqueKeysWithValues: DictationModel.all.enumerated().map { ($0.element.key, $0.offset) })
        models = loaded.sorted {
            (knownOrder[$0.key] ?? Int.max, $0.name) < (knownOrder[$1.key] ?? Int.max, $1.name)
        }
        table.reloadData()
        showState(models.isEmpty ? "No models are available." : nil,
                  action: models.isEmpty ? .retry : nil)
        onModelsChanged?(models)
        restoreSafeSelection()
        if models.contains(where: { $0.downloading || $0.deleting }) { startPolling() }
    }

    private func restoreSafeSelection() {
        let selectedKey = DictationModel.selected.key
        let selectedRow = models.firstIndex {
            $0.key == selectedKey && $0.installed && !$0.deleting
        }
        let fallbackRow = models.firstIndex {
            $0.installed && !$0.deleting && $0.dictationModel != nil
        }
        guard let row = selectedRow ?? fallbackRow else {
            isApplyingSelection = true
            table.deselectAll(nil)
            isApplyingSelection = false
            return
        }
        isApplyingSelection = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingSelection = false
        if selectedRow == nil, let model = models[row].dictationModel {
            DictationModel.select(model)
            onModelChanged?(model)
        }
    }

    private func showState(_ message: String?, loading: Bool = false, action: StateAction? = nil) {
        stateLabel.stringValue = message ?? ""
        stateLabel.isHidden = message == nil
        table.isHidden = message != nil
        stateAction = action
        stateButton.isHidden = action == nil
        stateButton.title = "Retry"
        loading ? stateProgress.startAnimation(nil) : stateProgress.stopAnimation(nil)
    }

    @objc private func performStateAction() {
        switch stateAction {
        case .retry: refresh()
        case nil: break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { models.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard models.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ModelRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ModelRowView)
            ?? ModelRowView(identifier: identifier)
        let model = models[row]
        let downloadStatus = model.progress.map {
            "Downloading \(Int(($0 * 100).rounded()))%"
        } ?? "Downloading..."
        cell.configure(
            model: model,
            operation: model.downloading
                ? downloadStatus
                : operations[model.key]?.label
                    ?? (model.deleting ? "Deleting..." : nil),
            isSelectedModel: DictationModel.selected.key == model.key,
            row: row,
            target: self
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = table.selectedRow
        guard models.indices.contains(row), models[row].installed,
              operations[models[row].key] == nil,
              !models[row].downloading, !models[row].deleting,
              let model = models[row].dictationModel else {
            restoreSafeSelection()
            return
        }
        DictationModel.select(model)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onModelChanged?(model)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await workerClient.activate(model: model)
                if let loaded = try? await workerClient.models() {
                    apply(loaded)
                }
            } catch {
                window?.presentError(error)
            }
        }
    }

    @objc fileprivate func download(_ sender: NSButton) {
        guard models.indices.contains(sender.tag) else { return }
        beginMutation(.downloading, model: models[sender.tag])
    }

    @objc fileprivate func deleteModel(_ sender: NSButton) {
        guard models.indices.contains(sender.tag) else { return }
        let model = models[sender.tag]
        guard DictationModel.selected.key != model.key else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(model.name)?"
        alert.informativeText = "The downloaded model files will be removed. You can download them again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.beginMutation(.deleting, model: model)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    private func beginMutation(_ operation: Operation, model: ManagedModel) {
        guard operations[model.key] == nil, !model.downloading, !model.deleting else { return }
        operations[model.key] = operation
        table.reloadData()
        startPolling()
        mutationTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch operation {
                case .downloading: try await workerClient.downloadModel(key: model.key)
                case .deleting: try await workerClient.deleteModel(key: model.key)
                }
                guard !Task.isCancelled else { return }
                operations[model.key] = nil
                let loaded = try await workerClient.models()
                apply(loaded)
                stopPollingIfIdle()
            } catch {
                guard !Task.isCancelled else { return }
                operations[model.key] = nil
                stopPollingIfIdle()
                table.reloadData()
                window?.presentError(error)
            }
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard let self, !Task.isCancelled,
                      !operations.isEmpty || models.contains(where: { $0.downloading || $0.deleting }) else { break }
                if let loaded = try? await workerClient.models() { apply(loaded) }
            }
            self?.finishPolling(generation: generation)
        }
    }

    private func stopPollingIfIdle() {
        guard operations.isEmpty,
              !models.contains(where: { $0.downloading || $0.deleting }) else { return }
        stopPolling()
    }

    private func stopPolling() {
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }

    private func finishPolling(generation: Int) {
        guard generation == pollGeneration else { return }
        pollTask = nil
    }
}

private final class ModelRowView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let trailing = NSStackView(views: [statusLabel, progress, actionButton])
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 7
        labels.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 28),
            actionButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        nameLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
    }

    func configure(
        model: ManagedModel,
        operation: String?,
        isSelectedModel: Bool,
        row: Int,
        target: ModelManagementView
    ) {
        nameLabel.stringValue = model.name
        detailLabel.stringValue = [model.detail, model.sizeDescription].filter { !$0.isEmpty }.joined(separator: " · ")
        let serverState = model.state?.replacingOccurrences(of: "_", with: " ").capitalized
        statusLabel.stringValue = operation
            ?? (isSelectedModel ? "Selected" : nil)
            ?? (model.downloadError == nil ? serverState : "Download failed")
            ?? (model.installed ? "Installed" : "Not installed")
        statusLabel.textColor = model.installed ? .secondaryLabelColor : .tertiaryLabelColor

        if operation != nil {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }

        let isDelete = model.installed
        let label = isDelete ? "Delete \(model.name)" : "Download \(model.name)"
        actionButton.image = NSImage(
            systemSymbolName: isDelete ? "trash" : "arrow.down.circle",
            accessibilityDescription: label
        )
        actionButton.imagePosition = .imageOnly
        actionButton.bezelStyle = .texturedRounded
        actionButton.isBordered = false
        actionButton.tag = row
        actionButton.target = target
        actionButton.action = isDelete
            ? #selector(ModelManagementView.deleteModel(_:))
            : #selector(ModelManagementView.download(_:))
        let deletionBlocked = isDelete && (isSelectedModel || model.loaded)
        actionButton.isEnabled = operation == nil
            && !model.downloading
            && !model.deleting
            && !deletionBlocked
        if model.loaded && !isSelectedModel {
            actionButton.toolTip = "The loaded model cannot be deleted until another model is used"
        } else if isDelete && isSelectedModel {
            actionButton.toolTip = "Select another installed model before deleting"
        } else {
            actionButton.toolTip = model.downloadError ?? label
        }
        actionButton.setAccessibilityLabel(label)
        let selectionStatus = isSelectedModel ? "Selected model" : (model.installed ? "Installed" : "Not installed")
        setAccessibilityLabel(model.name)
        setAccessibilityValue("\(selectionStatus), \(detailLabel.stringValue), \(statusLabel.stringValue)")
        setAccessibilitySelected(isSelectedModel)
    }
}
