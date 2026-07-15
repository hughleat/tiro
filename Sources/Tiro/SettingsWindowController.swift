import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onModelChanged: ((DictationModel) -> Void)?
    var onModelsChanged: (([ManagedModel]) -> Void)?
    var onAutoPasteChanged: ((Bool) -> Void)?
    var onShortcutChanged: ((DictationShortcut) -> Void)?
    var onShortcutCaptureChanged: ((Bool, Set<UInt16>) -> Void)?

    private let autoPasteButton = NSButton(checkboxWithTitle: "Paste after transcription", target: nil, action: nil)
    private let soundFeedbackButton = NSButton(checkboxWithTitle: "Recording sounds", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch Tiro at login", target: nil, action: nil)
    private let shortcutRecorder = ShortcutRecorderView()
    private let vocabularyEditor: VocabularyEditorView
    private let suggestionsView: VocabularySuggestionsView
    private let historyView: HistoryView
    private let modelManagementView: ModelManagementView
    private let modelComparisonView: ModelComparisonView

    init(workerClient: WorkerClient) {
        vocabularyEditor = VocabularyEditorView(workerClient: workerClient)
        suggestionsView = VocabularySuggestionsView(workerClient: workerClient)
        historyView = HistoryView(workerClient: workerClient)
        modelManagementView = ModelManagementView(workerClient: workerClient)
        modelComparisonView = ModelComparisonView(workerClient: workerClient)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tiro"
        window.center()
        window.minSize = NSSize(width: 480, height: 500)
        super.init(window: window)
        window.delegate = self
        modelManagementView.onModelChanged = { [weak self] model in
            self?.onModelChanged?(model)
        }
        modelManagementView.onModelsChanged = { [weak self, weak modelComparisonView] models in
            modelComparisonView?.setModels(models)
            self?.onModelsChanged?(models)
        }
        suggestionsView.onSuggestionsChanged = { [weak vocabularyEditor, weak historyView] in
            vocabularyEditor?.load()
            historyView?.refresh()
        }
        historyView.onCorrectionSaved = { [weak suggestionsView, weak modelComparisonView] in
            suggestionsView?.refresh()
            modelComparisonView?.refresh()
        }
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        shortcutRecorder.endCapture()
        modelManagementView.cancelWork()
        modelComparisonView.cancelWork()
    }

    func windowDidResignKey(_ notification: Notification) {
        shortcutRecorder.endCapture()
    }

    func refresh() {
        refreshModel()
        autoPasteButton.state = UserDefaults.standard.bool(forKey: "autoPaste") ? .on : .off
        soundFeedbackButton.state = UserDefaults.standard.bool(forKey: "soundFeedback") ? .on : .off
        refreshLaunchAtLogin()
        vocabularyEditor.load()
        suggestionsView.refresh()
        modelComparisonView.refresh()
        refreshHistory()
    }

    func refreshModel() {
        modelManagementView.refresh()
    }

    func refreshHistory() {
        historyView.refresh()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Dictation Settings")
        title.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let modelLabel = NSTextField(labelWithString: "Models")
        modelLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let comparisonLabel = NSTextField(labelWithString: "Compare Models")
        comparisonLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let shortcutLabel = NSTextField(labelWithString: "Shortcut")
        shortcutLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        shortcutRecorder.onShortcutChanged = { [weak self] shortcut in
            self?.onShortcutChanged?(shortcut)
        }
        shortcutRecorder.onCaptureStarted = { [weak self] in
            self?.onShortcutCaptureChanged?(true, [])
        }
        shortcutRecorder.onCaptureEnded = { [weak self] suppressedKeys in
            self?.onShortcutCaptureChanged?(false, suppressedKeys)
        }

        autoPasteButton.target = self
        autoPasteButton.action = #selector(autoPasteChanged)
        soundFeedbackButton.target = self
        soundFeedbackButton.action = #selector(soundFeedbackChanged)
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginChanged)

        let historyLabel = NSTextField(labelWithString: "Recent Transcriptions")
        historyLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let stack = NSStackView(views: [
            title, modelLabel, modelManagementView, comparisonLabel, modelComparisonView,
            shortcutLabel, shortcutRecorder,
            autoPasteButton, soundFeedbackButton, launchAtLoginButton,
            vocabularyEditor, suggestionsView, historyLabel, historyView
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: title)
        stack.setCustomSpacing(18, after: modelManagementView)
        stack.setCustomSpacing(18, after: modelComparisonView)
        stack.setCustomSpacing(18, after: launchAtLoginButton)
        stack.setCustomSpacing(18, after: vocabularyEditor)
        stack.setCustomSpacing(18, after: suggestionsView)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        modelManagementView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        modelComparisonView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        shortcutRecorder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        vocabularyEditor.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        suggestionsView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        historyView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24)
        ])
    }

    @objc private func autoPasteChanged() {
        let enabled = autoPasteButton.state == .on
        UserDefaults.standard.set(enabled, forKey: "autoPaste")
        onAutoPasteChanged?(enabled)
    }

    @objc private func soundFeedbackChanged() {
        UserDefaults.standard.set(soundFeedbackButton.state == .on, forKey: "soundFeedback")
    }

    @objc private func launchAtLoginChanged() {
        do {
            try LoginItemManager.setEnabled(launchAtLoginButton.state == .on)
            refreshLaunchAtLogin()
        } catch {
            refreshLaunchAtLogin()
            window?.presentError(error)
        }
    }

    private func refreshLaunchAtLogin() {
        launchAtLoginButton.state = LoginItemManager.isEnabled ? .on : .off
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
