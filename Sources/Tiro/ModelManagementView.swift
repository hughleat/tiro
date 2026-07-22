import AppKit
import Speech

@MainActor
final class ModelManagementView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    var onModelChanged: ((DictationModel) -> Void)?
    var onModelsChanged: (([ManagedModel]) -> Void)?

    private let service: TiroService
    private let table = NSTableView()
    private let storageLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let stateProgress = NSProgressIndicator()
    private let stateButton = NSButton()
    private enum StateAction { case retry }
    private var stateAction: StateAction?
    private var models: [ManagedModel] = []
    private var loadTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var isApplyingSelection = false
    private var modelUseObserver: NSObjectProtocol?
    private var modelUseInProgress = false
    private var notifiedInventory: [ModelInventoryState] = []

    private struct ModelInventoryState: Equatable {
        let key: String
        let installed: Bool
        let usable: Bool
        let loaded: Bool
        let deleting: Bool
    }

    init(service: TiroService) {
        self.service = service
        super.init(frame: .zero)
        buildContent()
        modelUseInProgress = service.modelUseInProgress
        modelUseObserver = NotificationCenter.default.addObserver(
            forName: .tiroModelUseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.modelUseChanged() }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let modelUseObserver { NotificationCenter.default.removeObserver(modelUseObserver) }
        loadTask?.cancel()
        selectionTask?.cancel()
        pollTask?.cancel()
    }

    func refresh() {
        loadTask?.cancel()
        if models.isEmpty { showState("Loading models...", loading: true) }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await service.models()
            guard !Task.isCancelled else { return }
            apply(loaded)
        }
    }

    func cancelWork() {
        loadTask?.cancel()
        loadTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        stopPolling()
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 7

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 68
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
            stateStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        storageLabel.font = .systemFont(ofSize: 11)
        storageLabel.textColor = .secondaryLabelColor
        storageLabel.alignment = .right
        addArrangedSubview(storageLabel)
        storageLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func apply(_ loaded: [ManagedModel]) {
        let order = Dictionary(uniqueKeysWithValues: DictationModel.all.enumerated().map {
            ($0.element.key, $0.offset)
        })
        let updated = loaded.sorted {
            (order[$0.key] ?? Int.max, $0.name) < (order[$1.key] ?? Int.max, $1.name)
        }
        let previous = models
        models = updated
        if let available = models.lazy.compactMap({ $0.downloadSpace?.availableBytes }).first {
            storageLabel.stringValue = "\(Self.fileSize(available)) available for models"
            storageLabel.isHidden = false
        } else {
            storageLabel.isHidden = true
        }
        if let changedRows = Self.rowsRequiringReload(from: previous, to: updated) {
            if !changedRows.isEmpty {
                table.reloadData(
                    forRowIndexes: changedRows,
                    columnIndexes: IndexSet(integer: 0)
                )
            }
        } else {
            table.reloadData()
        }
        showState(
            models.isEmpty ? "No models are available." : nil,
            action: models.isEmpty ? .retry : nil
        )
        let inventory = models.map {
            ModelInventoryState(
                key: $0.key,
                installed: $0.installed,
                usable: $0.usable,
                loaded: $0.loaded,
                deleting: $0.deleting
            )
        }
        if inventory != notifiedInventory {
            notifiedInventory = inventory
            onModelsChanged?(models)
        }
        restoreSafeSelection()
        models.contains(where: { $0.operation != nil }) ? startPolling() : stopPolling()
    }

    private func restoreSafeSelection() {
        let selectedKey = DictationModel.selected.key
        let selectedRow = models.firstIndex {
            $0.key == selectedKey
                && ($0.usable || ($0.isSystemManaged && $0.installed))
                && !$0.deleting
        }
        let fallbackRow = models.firstIndex {
            $0.usable && !$0.deleting && $0.dictationModel != nil
        }
        guard let row = selectedRow ?? fallbackRow else {
            selectTableRow(nil)
            return
        }
        selectTableRow(row)
        if selectedRow == nil, let model = models[row].dictationModel {
            do {
                try service.select(model: model)
                onModelChanged?(model)
            } catch {
                window?.presentError(error)
            }
        }
    }

    private func selectTableRow(_ row: Int?) {
        if table.selectedRow == row { return }
        isApplyingSelection = true
        defer { isApplyingSelection = false }
        if let row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    private func showState(
        _ message: String?,
        loading: Bool = false,
        action: StateAction? = nil
    ) {
        stateLabel.stringValue = message ?? ""
        stateLabel.isHidden = message == nil
        table.isHidden = message != nil
        stateAction = action
        stateButton.isHidden = action == nil
        stateButton.title = "Retry"
        loading ? stateProgress.startAnimation(nil) : stateProgress.stopAnimation(nil)
    }

    @objc private func performStateAction() {
        if stateAction == .retry { refresh() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { models.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard models.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ModelRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ModelRowView)
            ?? ModelRowView(identifier: identifier)
        cell.configure(
            model: models[row],
            mutationInProgress: modelUseInProgress || models.contains { $0.operation != nil },
            modelUseInProgress: modelUseInProgress,
            isSelectedModel: DictationModel.selected.key == models[row].key,
            row: row,
            target: self
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let row = table.selectedRow
        guard !modelUseInProgress,
              models.indices.contains(row),
              models[row].usable || (models[row].isSystemManaged && models[row].installed),
              models[row].operation == nil,
              let model = models[row].dictationModel else {
            restoreSafeSelection()
            return
        }
        guard DictationModel.selected.key != model.key else {
            table.reloadData()
            selectTableRow(row)
            return
        }
        do {
            try service.select(model: model)
        } catch {
            restoreSafeSelection()
            window?.presentError(error)
            return
        }
        table.reloadData()
        selectTableRow(row)
        onModelChanged?(model)
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.activate(model: model)
                guard !Task.isCancelled else { return }
                apply(await service.models())
            } catch {
                guard !Task.isCancelled else { return }
                window?.presentError(error)
            }
        }
    }

    @objc fileprivate func download(_ sender: NSButton) {
        guard models.indices.contains(sender.tag) else { return }
        service.startDownload(key: models[sender.tag].key)
        refreshAfterCommand()
    }

    @objc fileprivate func cancelDownload(_ sender: NSButton) {
        guard models.indices.contains(sender.tag) else { return }
        service.cancelModelOperation(key: models[sender.tag].key)
        refreshAfterCommand()
    }

    @objc fileprivate func deleteModel(_ sender: NSButton) {
        guard models.indices.contains(sender.tag) else { return }
        let model = models[sender.tag]
        guard DictationModel.selected.key != model.key else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(model.name)?"
        alert.informativeText =
            "The downloaded model files will be removed. You can download them again later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.service.startDelete(key: model.key)
            self?.refreshAfterCommand()
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    @objc fileprivate func allowSystemModel(_ sender: NSButton) {
        guard models.indices.contains(sender.tag),
              models[sender.tag].isSystemManaged else { return }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshAfterCommand() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await service.models()
            guard !Task.isCancelled else { return }
            apply(snapshot)
        }
    }

    private func modelUseChanged() {
        let updated = service.modelUseInProgress
        guard updated != modelUseInProgress else { return }
        modelUseInProgress = updated
        table.reloadData()
        restoreSafeSelection()
    }

    static func rowsRequiringReload(
        from previous: [ManagedModel],
        to updated: [ManagedModel]
    ) -> IndexSet? {
        guard previous.map(\.key) == updated.map(\.key) else { return nil }
        if previous.contains(where: { $0.operation != nil })
            != updated.contains(where: { $0.operation != nil }) {
            return IndexSet(updated.indices)
        }
        return IndexSet(updated.indices.filter { previous[$0] != updated[$0] })
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { break }
                let snapshot = await service.models()
                apply(snapshot)
                if !snapshot.contains(where: { $0.operation != nil }) { break }
            }
            self?.finishPolling(generation: generation)
        }
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

    fileprivate static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Model operation progress")

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let trailing = NSStackView(views: [statusLabel, progress, actionButton])
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 8
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
            progress.widthAnchor.constraint(equalToConstant: 88),
            actionButton.widthAnchor.constraint(equalToConstant: 28),
            actionButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        nameLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        detailLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
    }

    func configure(
        model: ManagedModel,
        mutationInProgress: Bool,
        modelUseInProgress: Bool,
        isSelectedModel: Bool,
        row: Int,
        target: ModelManagementView
    ) {
        let insufficientSpace = !model.installed
            && model.downloadSpace?.hasEnoughSpace == false
        let showsOperationError = model.operationError != nil && !insufficientSpace
        nameLabel.stringValue = model.name
        nameLabel.textColor = .labelColor
        detailLabel.stringValue = detail(for: model)
        detailLabel.textColor = showsOperationError ? .systemRed : .secondaryLabelColor
        detailLabel.toolTip = showsOperationError || insufficientSpace
            ? detailLabel.stringValue
            : nil
        statusLabel.stringValue = status(for: model, selected: isSelectedModel)
        statusLabel.textColor = showsOperationError
            ? .systemRed
            : (model.usable ? .secondaryLabelColor : .tertiaryLabelColor)

        configureProgress(for: model)
        configureAction(
            for: model,
            mutationInProgress: mutationInProgress,
            modelUseInProgress: modelUseInProgress,
            selected: isSelectedModel,
            row: row,
            target: target
        )

        let selectionStatus = isSelectedModel
            ? "Selected model"
            : (model.isSystemManaged
                ? "Provided by macOS"
                : (model.installed ? "Installed" : "Not installed"))
        setAccessibilityLabel(model.name)
        setAccessibilityValue(
            "\(selectionStatus), \(detailLabel.stringValue), \(statusLabel.stringValue)"
        )
        setAccessibilitySelected(isSelectedModel)
    }

    private func detail(for model: ManagedModel) -> String {
        if !model.installed, let space = model.downloadSpace, !space.hasEnoughSpace,
           let available = space.availableBytes {
            return "Needs \(ModelManagementView.fileSize(space.requiredBytes)) free · "
                + "\(ModelManagementView.fileSize(available)) available"
        }
        if let error = model.operationError { return error }
        return [model.detail, model.sizeDescription]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func status(for model: ManagedModel, selected: Bool) -> String {
        switch model.operation {
        case .downloading(let fraction):
            guard let fraction else { return "Starting download..." }
            let percent = Int((fraction * 100).rounded())
            let downloaded = ModelManagementView.fileSize(
                Int64(Double(model.downloadSizeBytes ?? 0) * fraction)
            )
            return "\(percent)% · \(downloaded) of \(model.sizeDescription)"
        case .cancelling:
            return "Cancelling..."
        case .deleting:
            return "Deleting..."
        case nil:
            if !model.installed, model.downloadSpace?.hasEnoughSpace == false {
                return "Not enough space"
            }
            if model.operationError != nil { return "Operation failed" }
            if selected { return model.usable ? "Selected" : "Selected · Unavailable" }
            let state = model.state?.replacingOccurrences(of: "_", with: " ").capitalized
            return state ?? (model.installed ? "Installed" : "Not installed")
        }
    }

    private func configureProgress(for model: ManagedModel) {
        switch model.operation {
        case .downloading(let fraction):
            progress.isHidden = false
            progress.isIndeterminate = fraction == nil
            progress.doubleValue = fraction ?? 0
            progress.startAnimation(nil)
            progress.setAccessibilityValue(fraction.map {
                "\(Int(($0 * 100).rounded())) percent"
            } ?? "Starting")
        case .cancelling, .deleting:
            progress.isHidden = false
            progress.isIndeterminate = true
            progress.startAnimation(nil)
            progress.setAccessibilityValue(
                model.operation?.isDeleting == true ? "Deleting" : "Cancelling"
            )
        case nil:
            progress.stopAnimation(nil)
            progress.isHidden = true
            progress.setAccessibilityValue(nil)
        }
    }

    private func configureAction(
        for model: ManagedModel,
        mutationInProgress: Bool,
        modelUseInProgress: Bool,
        selected: Bool,
        row: Int,
        target: ModelManagementView
    ) {
        let isDelete = model.installed && !model.isSystemManaged
        let isActiveDownload = model.operation?.isDownloading == true
        let insufficientSpace = !model.installed
            && model.downloadSpace?.hasEnoughSpace == false
        let label: String
        let symbol: String
        let action: Selector

        if isActiveDownload {
            label = "Cancel \(model.name) download"
            symbol = "xmark.circle"
            action = #selector(ModelManagementView.cancelDownload(_:))
        } else if model.isSystemManaged {
            label = "Allow \(model.name)"
            symbol = "lock.open"
            action = #selector(ModelManagementView.allowSystemModel(_:))
        } else if isDelete {
            label = "Delete \(model.name)"
            symbol = "trash"
            action = #selector(ModelManagementView.deleteModel(_:))
        } else {
            label = model.operationError == nil || insufficientSpace
                ? "Download \(model.name)"
                : "Retry \(model.name) download"
            symbol = model.operationError == nil || insufficientSpace
                ? "arrow.down.circle"
                : "arrow.clockwise"
            action = #selector(ModelManagementView.download(_:))
        }

        actionButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )
        actionButton.imagePosition = .imageOnly
        actionButton.bezelStyle = .texturedRounded
        actionButton.isBordered = false
        actionButton.tag = row
        actionButton.target = target
        actionButton.action = action
        actionButton.isHidden = (model.isSystemManaged && model.installed)
            || model.operation?.isDeleting == true
        let deletionBlocked = isDelete && (selected || model.loaded)
        if case .downloading = model.operation {
            actionButton.isEnabled = true
        } else {
            actionButton.isEnabled = model.operation == nil
                && !mutationInProgress
                && !deletionBlocked
                && !insufficientSpace
        }
        if modelUseInProgress && !isActiveDownload {
            actionButton.toolTip = "Wait for recording or transcription to finish"
        } else if model.loaded && !selected {
            actionButton.toolTip =
                "The loaded model cannot be deleted until another model is used"
        } else if isDelete && selected {
            actionButton.toolTip = "Select another installed model before deleting"
        } else if insufficientSpace {
            actionButton.toolTip = detail(for: model)
        } else {
            actionButton.toolTip = label
        }
        actionButton.setAccessibilityLabel(label)
    }
}
