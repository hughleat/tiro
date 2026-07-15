import AppKit

final class SettingsWindowController: NSWindowController {
    var onModelChanged: ((DictationModel) -> Void)?
    var onAutoPasteChanged: ((Bool) -> Void)?

    private let modelPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoPasteButton = NSButton(checkboxWithTitle: "Paste after transcription", target: nil, action: nil)
    private let vocabularyView = NSTextView(frame: .zero)
    private let historyView = NSTextView(frame: .zero)
    private var isLoadingVocabulary = false
    private var vocabularyHasUnsavedChanges = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tiro"
        window.center()
        window.minSize = NSSize(width: 480, height: 360)
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        refreshModel()
        autoPasteButton.state = UserDefaults.standard.bool(forKey: "autoPaste") ? .on : .off
        loadVocabularyEditor()
        refreshHistory()
    }

    func refreshModel() {
        if let index = DictationModel.all.firstIndex(of: DictationModel.selected) {
            modelPicker.selectItem(at: index)
        }
    }

    func refreshHistory() {
        historyView.string = loadHistory()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Dictation Settings")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)

        let modelLabel = NSTextField(labelWithString: "Model")
        modelLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        modelPicker.addItems(withTitles: DictationModel.all.map { "\($0.name) — \($0.detail)" })
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)

        autoPasteButton.target = self
        autoPasteButton.action = #selector(autoPasteChanged)

        let vocabularyLabel = NSTextField(labelWithString: "Vocabulary")
        vocabularyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        vocabularyView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        vocabularyView.textContainerInset = NSSize(width: 8, height: 8)
        vocabularyView.delegate = self
        let vocabularyScrollView = NSScrollView()
        vocabularyScrollView.hasVerticalScroller = true
        vocabularyScrollView.borderType = .bezelBorder
        vocabularyScrollView.documentView = vocabularyView

        let historyLabel = NSTextField(labelWithString: "Recent Transcriptions")
        historyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        historyView.isEditable = false
        historyView.isSelectable = true
        historyView.font = NSFont.systemFont(ofSize: 14)
        historyView.textContainerInset = NSSize(width: 10, height: 10)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = historyView

        let stack = NSStackView(views: [
            title, modelLabel, modelPicker, autoPasteButton,
            vocabularyLabel, vocabularyScrollView, historyLabel, scrollView
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: title)
        stack.setCustomSpacing(18, after: autoPasteButton)
        stack.setCustomSpacing(18, after: vocabularyScrollView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        modelPicker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        vocabularyScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        vocabularyScrollView.heightAnchor.constraint(equalToConstant: 110).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    @objc private func modelChanged() {
        let model = DictationModel.all[modelPicker.indexOfSelectedItem]
        DictationModel.select(model)
        onModelChanged?(model)
    }

    @objc private func autoPasteChanged() {
        let enabled = autoPasteButton.state == .on
        UserDefaults.standard.set(enabled, forKey: "autoPaste")
        onAutoPasteChanged?(enabled)
    }

    private func loadHistory() -> String {
        guard let contents = try? String(contentsOf: AppPaths.historyFile, encoding: .utf8) else {
            return "No transcriptions yet."
        }
        let decoder = JSONDecoder()
        let entries = contents.split(separator: "\n").compactMap {
            try? decoder.decode(HistoryEntry.self, from: Data($0.utf8))
        }
        guard !entries.isEmpty else { return "No transcriptions yet." }
        return entries.suffix(30).reversed().map { entry in
            let model = entry.model.split(separator: "/").last.map(String.init) ?? entry.model
            return "\(entry.text)\n\(model) · \(String(format: "%.2fs", entry.transcription_seconds))"
        }.joined(separator: "\n\n")
    }

    private func loadVocabularyEditor() {
        guard !vocabularyHasUnsavedChanges else { return }
        isLoadingVocabulary = true
        defer { isLoadingVocabulary = false }
        do {
            vocabularyView.string = try VocabularyFile.load()
            vocabularyView.isEditable = true
            vocabularyView.backgroundColor = .textBackgroundColor
        } catch {
            vocabularyView.string = "Vocabulary file could not be read."
            vocabularyView.isEditable = false
            NSLog("Could not load Tiro vocabulary: %@", error.localizedDescription)
        }
    }

}

extension SettingsWindowController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard !isLoadingVocabulary,
              notification.object as? NSTextView === vocabularyView else { return }
        do {
            try VocabularyFile.save(vocabularyView.string)
            vocabularyHasUnsavedChanges = false
            vocabularyView.backgroundColor = .textBackgroundColor
        } catch {
            vocabularyHasUnsavedChanges = true
            vocabularyView.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12)
            window?.presentError(error)
            NSLog("Could not save Tiro vocabulary: %@", error.localizedDescription)
        }
    }
}
