import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onModelChanged: ((DictationModel) -> Void)?
    var onModelsChanged: (([ManagedModel]) -> Void)?
    var onAutoPasteChanged: ((Bool) -> Void)?
    var onShortcutChanged: ((DictationShortcut) -> Void)?
    var onShortcutCaptureChanged: ((Bool, Set<UInt16>) -> Void)?
    var onPrivacySettingsLoaded: (() -> Void)?

    private let autoPasteButton = NSButton(checkboxWithTitle: "Paste after transcription", target: nil, action: nil)
    private let soundFeedbackButton = NSButton(checkboxWithTitle: "Recording feedback", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch Tiro at login", target: nil, action: nil)
    private let shortcutRecorder = ShortcutRecorderView()
    private let dictationPreferencesView = DictationPreferencesView()
    private let snippetEditor: SnippetEditorView
    private let vocabularyEditor: VocabularyEditorView
    private let suggestionsView: VocabularySuggestionsView
    private let historyView: HistoryView
    private let modelManagementView: ModelManagementView
    private let modelComparisonView: ModelComparisonView
    private let permissionSettingsView = PermissionSettingsView()
    private let privacySettingsView: PrivacySettingsView
    private var navigationController: SettingsNavigationController?

    init(service: TiroService) {
        vocabularyEditor = VocabularyEditorView(service: service)
        snippetEditor = SnippetEditorView(service: service)
        suggestionsView = VocabularySuggestionsView(service: service)
        historyView = HistoryView(service: service)
        modelManagementView = ModelManagementView(service: service)
        modelComparisonView = ModelComparisonView(service: service)
        privacySettingsView = PrivacySettingsView(service: service)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tiro Settings"
        window.center()
        window.minSize = NSSize(width: 720, height: 520)
        window.setFrameAutosaveName("TiroSettingsWindow")
        super.init(window: window)
        window.delegate = self
        modelManagementView.onModelChanged = { [weak self] model in
            self?.dictationPreferencesView.setModel(model)
            self?.onModelChanged?(model)
        }
        modelManagementView.onModelsChanged = { [weak self, weak modelComparisonView] models in
            modelComparisonView?.setModels(models)
            self?.onModelsChanged?(models)
        }
        permissionSettingsView.onPermissionChanged = { [weak modelManagementView] in
            modelManagementView?.refresh()
        }
        suggestionsView.onSuggestionsChanged = { [weak vocabularyEditor, weak historyView] in
            vocabularyEditor?.load()
            historyView?.refresh()
        }
        historyView.onCorrectionSaved = { [weak suggestionsView, weak modelComparisonView] in
            suggestionsView?.refresh()
            modelComparisonView?.refresh()
        }
        privacySettingsView.onStoredDataChanged = { [weak historyView, weak suggestionsView, weak modelComparisonView] in
            historyView?.refresh()
            suggestionsView?.refresh()
            modelComparisonView?.refresh()
        }
        privacySettingsView.onSettingsLoaded = { [weak self] in
            self?.onPrivacySettingsLoaded?()
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
        snippetEditor.cancelWork()
        privacySettingsView.cancelWork()
    }

    func windowDidResignKey(_ notification: Notification) {
        shortcutRecorder.endCapture()
    }

    func refresh() {
        refreshModel()
        dictationPreferencesView.refresh()
        dictationPreferencesView.setModel(DictationModel.selected)
        snippetEditor.load()
        autoPasteButton.state = UserDefaults.standard.bool(forKey: "autoPaste") ? .on : .off
        soundFeedbackButton.state = UserDefaults.standard.bool(forKey: "soundFeedback") ? .on : .off
        refreshLaunchAtLogin()
        vocabularyEditor.load()
        suggestionsView.refresh()
        modelComparisonView.refresh()
        refreshHistory()
        permissionSettingsView.refresh()
        privacySettingsView.refresh()
    }

    func showGeneralSettings() { showSettings(.general) }
    func showModelsSettings() { showSettings(.models) }
    func showPermissionsSettings() { showSettings(.permissions) }
    func showPrivacySettings() { showSettings(.privacy) }

    func refreshModel() {
        dictationPreferencesView.setModel(DictationModel.selected)
        modelManagementView.refresh()
    }

    func refreshHistory() {
        historyView.refresh()
    }

    private func buildContent() {
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

        let general = SettingsPageViewController(title: "General", contentView: makeGeneralView())
        let models = SettingsPageViewController(
            title: "Models",
            contentView: SettingsTabbedContentView(tabs: [
                .init(title: "Model Library", view: modelManagementView),
                .init(title: "Compare", view: modelComparisonView)
            ])
        )
        let vocabulary = SettingsPageViewController(
            title: "Vocabulary",
            contentView: SettingsTabbedContentView(tabs: [
                .init(title: "Replacements", view: vocabularyEditor),
                .init(title: "Snippets", view: snippetEditor),
                .init(title: "Suggestions", view: suggestionsView)
            ])
        )
        let history = SettingsPageViewController(title: "History", contentView: historyView)
        let permissions = SettingsPageViewController(title: "Permissions", contentView: permissionSettingsView)
        let privacy = SettingsPageViewController(
            title: "Privacy",
            contentView: SettingsScrollView(document: privacySettingsView)
        )
        let about = SettingsPageViewController(title: "About", contentView: makeAboutView())
        let navigation = SettingsNavigationController(items: [
            .init(section: .general, title: "General", symbolName: "gearshape", viewController: general),
            .init(section: .models, title: "Models", symbolName: "square.stack.3d.up", viewController: models),
            .init(section: .permissions, title: "Permissions", symbolName: "lock.shield", viewController: permissions),
            .init(section: .privacy, title: "Privacy", symbolName: "hand.raised", viewController: privacy),
            .init(section: .vocabulary, title: "Vocabulary", symbolName: "text.book.closed", viewController: vocabulary),
            .init(section: .history, title: "History", symbolName: "clock.arrow.circlepath", viewController: history),
            .init(section: .about, title: "About", symbolName: "info.circle", viewController: about)
        ])
        navigationController = navigation
        contentViewController = navigation
    }

    private func showSettings(_ section: SettingsSection) {
        showWindow(nil)
        navigationController?.show(section)
    }

    private func makeGeneralView() -> NSView {
        let dictationLabel = sectionLabel("Dictation")
        let shortcutLabel = sectionLabel("Shortcut")
        let stack = NSStackView(views: [
            dictationLabel, dictationPreferencesView,
            shortcutLabel, shortcutRecorder,
            autoPasteButton, soundFeedbackButton, launchAtLoginButton,
            NSView()
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: dictationPreferencesView)
        stack.setCustomSpacing(18, after: shortcutRecorder)
        dictationPreferencesView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        shortcutRecorder.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeAboutView() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let name = NSTextField(labelWithString: "Tiro")
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let versionLabel = NSTextField(labelWithString: Self.versionText(version: version, build: build))
        versionLabel.textColor = .secondaryLabelColor
        var detailViews: [NSView] = [name, versionLabel]
#if TIRO_SPONSORSHIP_ENABLED
        let supportButton = NSButton(
            title: BuildFeatures.sponsorshipButtonTitle!,
            target: self,
            action: #selector(supportTiro)
        )
        supportButton.bezelStyle = .rounded
        detailViews.append(supportButton)
#endif
        let details = NSStackView(views: detailViews)
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        let row = NSStackView(views: [icon, details, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        let stack = NSStackView(views: [row, NSView()])
        stack.orientation = .vertical
        stack.alignment = .leading
        return stack
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    private static func versionText(version: String?, build: String?) -> String {
        switch (version, build) {
        case let (version?, build?) where version != build: return "Version \(version) (\(build))"
        case let (version?, _): return "Version \(version)"
        case let (_, build?): return "Build \(build)"
        default: return "Local development build"
        }
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

#if TIRO_SPONSORSHIP_ENABLED
    @objc private func supportTiro() {
        NSWorkspace.shared.open(BuildFeatures.sponsorsURL)
    }
#endif

    private func refreshLaunchAtLogin() {
        launchAtLoginButton.state = LoginItemManager.isEnabled ? .on : .off
    }
}
