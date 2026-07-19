import AppKit

@MainActor
final class VocabularySuggestionsView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    var onSuggestionsChanged: (() -> Void)?

    private let service: TiroService
    private let table = NSTableView()
    private let stateLabel = NSTextField(labelWithString: "")
    private var suggestions: [VocabularySuggestion] = []
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?

    init(service: TiroService) {
        self.service = service
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTask?.cancel()
        actionTask?.cancel()
    }

    func refresh() {
        refreshTask?.cancel()
        if suggestions.isEmpty { showState("Loading suggestions...") }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await service.suggestions()
                guard !Task.isCancelled else { return }
                suggestions = results
                table.reloadData()
                showState(results.isEmpty ? "No vocabulary suggestions." : nil)
            } catch {
                guard !Task.isCancelled else { return }
                suggestions = []
                table.reloadData()
                showState("Could not load suggestions.\n\(error.localizedDescription)")
            }
        }
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 8

        let label = NSTextField(labelWithString: "Vocabulary Suggestions")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.title = "Suggestions"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = table
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.alignment = .center
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.maximumNumberOfLines = 2
        stateLabel.lineBreakMode = .byWordWrapping
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            stateLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        addArrangedSubview(label)
        addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    private func showState(_ message: String?) {
        stateLabel.stringValue = message ?? ""
        stateLabel.isHidden = message == nil
        table.isHidden = message != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard suggestions.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("VocabularySuggestionRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? VocabularySuggestionRowView)
            ?? VocabularySuggestionRowView(identifier: identifier)
        cell.configure(suggestion: suggestions[row], row: row, target: self)
        return cell
    }

    @objc fileprivate func acceptForApp(_ sender: NSButton) {
        guard suggestions.indices.contains(sender.tag) else { return }
        let suggestion = suggestions[sender.tag]
        performAction(for: suggestion, scope: suggestion.origin_bundle_id == nil ? .global : .profile)
    }

    @objc fileprivate func acceptGlobally(_ sender: NSButton) {
        guard suggestions.indices.contains(sender.tag) else { return }
        performAction(for: suggestions[sender.tag], scope: .global)
    }

    @objc fileprivate func dismiss(_ sender: NSButton) {
        guard suggestions.indices.contains(sender.tag) else { return }
        guard actionTask == nil else { return }
        let suggestion = suggestions[sender.tag]
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { actionTask = nil }
            do {
                try await service.dismissSuggestion(id: suggestion.id)
                guard !Task.isCancelled else { return }
                onSuggestionsChanged?()
                refresh()
            } catch {
                guard !Task.isCancelled else { return }
                window?.presentError(error)
            }
        }
    }

    private func performAction(for suggestion: VocabularySuggestion, scope: SuggestionScope) {
        guard actionTask == nil else { return }
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { actionTask = nil }
            do {
                try await service.acceptSuggestion(id: suggestion.id, scope: scope)
                guard !Task.isCancelled else { return }
                onSuggestionsChanged?()
                refresh()
            } catch {
                guard !Task.isCancelled else { return }
                window?.presentError(error)
            }
        }
    }
}

private final class VocabularySuggestionRowView: NSTableCellView {
    private let replacementLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")
    private let appButton = NSButton()
    private let globalButton = NSButton()
    private let dismissButton = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        replacementLabel.font = .systemFont(ofSize: 13)
        replacementLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingMiddle

        let labels = NSStackView(views: [replacementLabel, metadataLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let buttons = NSStackView(views: [appButton, globalButton, dismissButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        addSubview(buttons)

        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        for button in [appButton, globalButton, dismissButton] {
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        replacementLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        metadataLabel.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
    }

    func configure(suggestion: VocabularySuggestion, row: Int, target: VocabularySuggestionsView) {
        replacementLabel.stringValue = "\(suggestion.spoken)  →  \(suggestion.written)"
        let app = suggestion.origin_app_name?.isEmpty == false
            ? suggestion.origin_app_name!
            : suggestion.displayBundleID
        metadataLabel.stringValue = [app, "Used \(suggestion.count)×"].compactMap { $0 }.joined(separator: "  ·  ")

        let hasApp = suggestion.origin_bundle_id?.isEmpty == false
        configure(
            appButton,
            symbol: hasApp ? "app.badge.checkmark" : "globe",
            label: hasApp ? "Accept for \(app ?? "app")" : "Accept globally",
            row: row,
            target: target,
            action: #selector(VocabularySuggestionsView.acceptForApp(_:))
        )
        configure(
            globalButton,
            symbol: "globe",
            label: "Accept globally",
            row: row,
            target: target,
            action: #selector(VocabularySuggestionsView.acceptGlobally(_:))
        )
        globalButton.isHidden = !hasApp
        configure(
            dismissButton,
            symbol: "xmark",
            label: "Dismiss suggestion",
            row: row,
            target: target,
            action: #selector(VocabularySuggestionsView.dismiss(_:))
        )
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
