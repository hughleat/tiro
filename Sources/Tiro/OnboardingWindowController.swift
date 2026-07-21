import AppKit
import AVFoundation
import Speech

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    var onRequestMicrophone: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onModelsChanged: (([ManagedModel]) -> Void)?
    var onDownloadCompleted: (() -> Void)?
    var onComplete: (() -> Void)?

    private let service: TiroService
    private let shortcutName: String
    private let microphoneRow = SetupStatusRow(title: "Microphone")
    private let accessibilityRow = SetupStatusRow(title: "Accessibility")
    private let modelRow = SetupStatusRow(title: "Model status")
    private let modelPicker = NSPopUpButton()
    private let downloadProgress = NSProgressIndicator()
    private let practiceField = NSTextField()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let finishButton = NSButton(title: "Start Using Tiro", target: nil, action: nil)
    private var selectedModelKey: String
    private var readiness = SetupReadiness(
        microphoneAllowed: false,
        accessibilityAllowed: false,
        selectedModelKey: DictationModel.coreMLCompactKey,
        usableModelKeys: []
    )
    private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private var models: [ManagedModel] = []
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var downloadRequestedKey: String?
    private var wasReady = false

    private static let starterModelKeys = [
        DictationModel.coreMLCompactKey,
        "coreml-parakeet-v2",
        "coreml-parakeet-v3",
        DictationModel.appleSpeechKey,
    ]

    init(service: TiroService, shortcutName: String) {
        self.service = service
        self.shortcutName = shortcutName
        let currentKey = DictationModel.selected.key
        selectedModelKey = Self.starterModelKeys.contains(currentKey)
            ? currentKey
            : DictationModel.coreMLCompactKey
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Tiro"
        window.minSize = NSSize(width: 600, height: 650)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTask?.cancel()
        pollTask?.cancel()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
        refreshModels()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTask?.cancel()
        refreshTask = nil
        stopPolling()
    }

    func updatePermissions(microphone: AVAuthorizationStatus, accessibilityAllowed: Bool) {
        microphoneStatus = microphone
        readiness = SetupReadiness(
            microphoneAllowed: microphone == .authorized,
            accessibilityAllowed: accessibilityAllowed,
            selectedModelKey: selectedModelKey,
            usableModelKeys: readiness.usableModelKeys
        )
        render()
    }

    var isPracticeFieldFocused: Bool {
        guard let editor = practiceField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Make Tiro ready for dictation")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let privacy = NSTextField(wrappingLabelWithString:
            "Your recordings and transcripts are processed locally on this Mac. Tiro does not send your speech to a transcription service."
        )
        privacy.textColor = .secondaryLabelColor

        microphoneRow.button.target = self
        microphoneRow.button.action = #selector(handleMicrophone)
        accessibilityRow.button.target = self
        accessibilityRow.button.action = #selector(handleAccessibility)
        modelRow.button.target = self

        modelPicker.target = self
        modelPicker.action = #selector(modelSelectionChanged)
        modelPicker.setAccessibilityLabel("Starter transcription model")
        for model in starterModels {
            modelPicker.addItem(withTitle: starterTitle(for: model))
            modelPicker.lastItem?.representedObject = model.key
        }
        selectPickerItem(for: selectedModelKey)

        downloadProgress.style = .bar
        downloadProgress.minValue = 0
        downloadProgress.maxValue = 100
        downloadProgress.isDisplayedWhenStopped = false
        downloadProgress.controlSize = .small
        downloadProgress.setAccessibilityLabel("Model download progress")

        let modelTitle = NSTextField(labelWithString: "Transcription model")
        modelTitle.font = .systemFont(ofSize: 13, weight: .medium)
        modelTitle.widthAnchor.constraint(equalToConstant: 158).isActive = true
        let modelSelectionRow = NSStackView(views: [modelTitle, modelPicker])
        modelSelectionRow.orientation = .horizontal
        modelSelectionRow.alignment = .centerY
        modelSelectionRow.spacing = 10

        let shortcutTitle = NSTextField(labelWithString: "Shortcut")
        shortcutTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let shortcutValue = NSTextField(labelWithString: shortcutName)
        shortcutValue.textColor = .secondaryLabelColor
        shortcutValue.alignment = .right
        let shortcutRow = NSStackView(views: [shortcutTitle, NSView(), shortcutValue])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 12

        let practiceTitle = NSTextField(labelWithString: "Try a dictation")
        practiceTitle.font = .systemFont(ofSize: 13, weight: .medium)
        practiceField.placeholderString = "Select this field, then use \(shortcutName)"
        practiceField.font = .systemFont(ofSize: 14)
        practiceField.isEnabled = false
        practiceField.setAccessibilityLabel("First dictation practice field")
        practiceField.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let practiceHint = NSTextField(wrappingLabelWithString:
            "Tap \(shortcutName) to start and stop. Hold it for push-to-talk. "
                + "Escape cancels. Tiro stays in the menu bar."
        )
        practiceHint.textColor = .secondaryLabelColor
        practiceHint.font = .systemFont(ofSize: 12)
        let practiceStack = NSStackView(views: [practiceTitle, practiceField, practiceHint])
        practiceStack.orientation = .vertical
        practiceStack.alignment = .leading
        practiceStack.spacing = 7

        messageLabel.textColor = .systemRed
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.maximumNumberOfLines = 2
        messageLabel.isHidden = true

        finishButton.keyEquivalent = "\r"
        finishButton.bezelStyle = .rounded
        finishButton.target = self
        finishButton.action = #selector(finishSetup)

        let footer = NSStackView(views: [messageLabel, NSView(), finishButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let firstSeparator = separator()
        let secondSeparator = separator()
        let stack = NSStackView(views: [
            title,
            privacy,
            firstSeparator,
            microphoneRow,
            accessibilityRow,
            modelSelectionRow,
            modelRow,
            downloadProgress,
            secondSeparator,
            shortcutRow,
            practiceStack,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(7, after: title)
        stack.setCustomSpacing(20, after: privacy)
        stack.setCustomSpacing(16, after: shortcutRow)
        stack.setCustomSpacing(20, after: practiceStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        for view in [privacy, firstSeparator, microphoneRow, accessibilityRow,
                     modelSelectionRow, modelRow, downloadProgress, secondSeparator,
                     shortcutRow, practiceStack, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        practiceField.widthAnchor.constraint(equalTo: practiceStack.widthAnchor).isActive = true
        practiceHint.widthAnchor.constraint(equalTo: practiceStack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
        ])
        render()
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func refreshModels() {
        refreshTask?.cancel()
        modelRow.set(status: "Checking...", ready: false, actionTitle: nil)
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let models = await service.models()
            guard !Task.isCancelled else { return }
            apply(models)
        }
    }

    private func apply(_ models: [ManagedModel]) {
        self.models = models
        let selected = selectedManagedModel
        if let selected, selected.downloading {
            downloadProgress.isIndeterminate = selected.progress == nil
            downloadProgress.doubleValue = (selected.progress ?? 0) * 100
            downloadProgress.setAccessibilityValue(selected.progress.map {
                "\(Int(($0 * 100).rounded())) percent"
            } ?? "Starting")
            downloadProgress.startAnimation(nil)
        } else {
            downloadProgress.stopAnimation(nil)
            downloadProgress.setAccessibilityValue(nil)
        }
        var usable = Set(models.lazy.filter { $0.usable && !$0.deleting }.map(\.key))
        var selectedModelChanged = false
        if selected?.usable == true,
           DictationModel.selected.key != selectedModelKey,
           let model = selected?.dictationModel {
            do {
                try service.select(model: model)
                selectedModelChanged = true
                messageLabel.isHidden = true
            } catch {
                usable.remove(selectedModelKey)
                showError(error.localizedDescription)
            }
        }
        readiness = SetupReadiness(
            microphoneAllowed: readiness.microphoneAllowed,
            accessibilityAllowed: readiness.accessibilityAllowed,
            selectedModelKey: selectedModelKey,
            usableModelKeys: usable
        )
        onModelsChanged?(models)
        render()
        if let requestedKey = downloadRequestedKey,
           models.first(where: { $0.key == requestedKey })?.usable == true {
            downloadRequestedKey = nil
            if requestedKey == selectedModelKey,
               DictationModel.selected.key == requestedKey {
                onDownloadCompleted?()
            }
        } else if selectedModelChanged {
            onDownloadCompleted?()
        }
        if models.contains(where: { $0.operation != nil }) {
            if pollTask == nil { startPolling() }
        } else {
            stopPolling()
        }
    }

    private func render() {
        let microphoneAction: String?
        switch microphoneStatus {
        case .authorized: microphoneAction = nil
        case .notDetermined: microphoneAction = "Allow"
        default: microphoneAction = "Open Settings"
        }
        microphoneRow.set(
            status: readiness.microphoneAllowed ? "Allowed" : permissionStatus(microphoneStatus),
            ready: readiness.microphoneAllowed,
            actionTitle: microphoneAction
        )
        accessibilityRow.set(
            status: readiness.accessibilityAllowed ? "Allowed" : "Required for the shortcut and auto-paste",
            ready: readiness.accessibilityAllowed,
            actionTitle: readiness.accessibilityAllowed ? nil : "Open Settings"
        )

        let selected = selectedManagedModel
        let activeModel = models.first { $0.operation != nil }
        modelPicker.isEnabled = activeModel == nil
        if case .downloading(let fraction) = selected?.operation {
            let status = fraction.map {
                "Downloading \(selected?.name ?? "model") · \(Int(($0 * 100).rounded()))%"
            } ?? "Starting download…"
            modelRow.set(status: status, ready: false, actionTitle: "Cancel")
            modelRow.button.action = #selector(cancelSelectedDownload)
        } else if case .cancelling = selected?.operation {
            modelRow.set(status: "Cancelling download...", ready: false, actionTitle: nil)
        } else if let activeModel {
            modelRow.set(
                status: "Managing \(activeModel.name)...",
                ready: readiness.selectedModelReady,
                actionTitle: activeModel.downloading ? "Cancel" : nil
            )
            modelRow.button.action = #selector(cancelActiveDownload)
        } else if selected?.isSystemManaged == true, selected?.usable == true {
            modelRow.set(status: "Ready · provided by macOS", ready: true, actionTitle: nil)
        } else if selected?.isSystemManaged == true, selected?.state == "unavailable" {
            modelRow.set(
                status: "Unavailable for this language. Choose another model.",
                ready: false,
                actionTitle: nil
            )
        } else if selected?.isSystemManaged == true {
            modelRow.set(
                status: "Speech Recognition permission required",
                ready: false,
                actionTitle: SFSpeechRecognizer.authorizationStatus() == .notDetermined
                    ? "Allow"
                    : "Open Settings"
            )
            modelRow.button.action = #selector(enableAppleSpeech)
        } else if selected?.installed == false,
                  let space = selected?.downloadSpace,
                  !space.hasEnoughSpace,
                  let available = space.availableBytes {
            modelRow.set(
                status: "Needs \(fileSize(space.requiredBytes)) free; "
                    + "\(fileSize(available)) is available",
                ready: false,
                actionTitle: nil
            )
        } else if selected?.installed == false,
                  let error = selected?.operationError {
            modelRow.set(status: error, ready: false, actionTitle: "Retry")
            modelRow.button.action = #selector(downloadSelectedModel)
        } else if readiness.selectedModelReady {
            modelRow.set(status: "Ready", ready: true, actionTitle: nil)
        } else {
            modelRow.set(
                status: selected.map { "\($0.name), \($0.sizeDescription)" } ?? "Checking…",
                ready: false,
                actionTitle: selected == nil ? nil : "Download"
            )
            modelRow.button.action = #selector(downloadSelectedModel)
        }
        finishButton.isEnabled = readiness.canFinish
        practiceField.isEnabled = readiness.canFinish
        if readiness.canFinish, !wasReady {
            AccessibilityAnnouncements.post(
                "Tiro is ready. Try a dictation or start using Tiro.",
                from: practiceField
            )
        }
        wasReady = readiness.canFinish
    }

    private var starterModels: [DictationModel] {
        Self.starterModelKeys.compactMap { key in
            DictationModel.all.first { $0.key == key }
        }
    }

    private var selectedManagedModel: ManagedModel? {
        models.first { $0.key == selectedModelKey }
    }

    private func starterTitle(for model: DictationModel) -> String {
        switch model.key {
        case DictationModel.coreMLCompactKey: "Fast English — Parakeet Compact (228 MB)"
        case "coreml-parakeet-v2": "Best English — Parakeet 0.6B v2 (500 MB)"
        case "coreml-parakeet-v3": "Multilingual — Parakeet 0.6B v3 (520 MB)"
        case DictationModel.appleSpeechKey: "Apple Speech — no Tiro download"
        default: model.name
        }
    }

    private func selectPickerItem(for key: String) {
        guard let item = modelPicker.itemArray.first(where: {
            $0.representedObject as? String == key
        }) else { return }
        modelPicker.select(item)
    }

    private func permissionStatus(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Needed to record your voice"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted by this Mac"
        case .authorized: return "Allowed"
        @unknown default: return "Permission required"
        }
    }

    @objc private func handleMicrophone() {
        messageLabel.isHidden = true
        onRequestMicrophone?()
    }

    @objc private func handleAccessibility() {
        messageLabel.isHidden = true
        onOpenAccessibility?()
    }

    @objc private func modelSelectionChanged() {
        guard let key = modelPicker.selectedItem?.representedObject as? String else { return }
        selectedModelKey = key
        readiness = SetupReadiness(
            microphoneAllowed: readiness.microphoneAllowed,
            accessibilityAllowed: readiness.accessibilityAllowed,
            selectedModelKey: key,
            usableModelKeys: readiness.usableModelKeys
        )
        if let selectedManagedModel, selectedManagedModel.usable,
           let model = selectedManagedModel.dictationModel {
            do {
                try service.select(model: model)
                messageLabel.isHidden = true
                onDownloadCompleted?()
            } catch {
                var usable = readiness.usableModelKeys
                usable.remove(key)
                readiness = SetupReadiness(
                    microphoneAllowed: readiness.microphoneAllowed,
                    accessibilityAllowed: readiness.accessibilityAllowed,
                    selectedModelKey: key,
                    usableModelKeys: usable
                )
                showError(error.localizedDescription)
            }
        }
        render()
    }

    @objc private func downloadSelectedModel() {
        messageLabel.isHidden = true
        downloadRequestedKey = service.startDownload(key: selectedModelKey)
            ? selectedModelKey
            : nil
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            apply(await service.models())
        }
        startPolling()
    }

    @objc private func cancelSelectedDownload() {
        downloadRequestedKey = nil
        service.cancelModelOperation(key: selectedModelKey)
        refreshModels()
    }

    @objc private func cancelActiveDownload() {
        guard let activeKey = models.first(where: { $0.downloading })?.key else { return }
        if downloadRequestedKey == activeKey { downloadRequestedKey = nil }
        service.cancelModelOperation(key: activeKey)
        refreshModels()
    }

    @objc private func enableAppleSpeech() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refreshModels() }
            }
        } else if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard let self, !Task.isCancelled else { return }
                apply(await service.models())
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func showError(_ message: String) {
        messageLabel.stringValue = message
        messageLabel.isHidden = false
        AccessibilityAnnouncements.post(message, from: messageLabel)
    }

    private func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @objc private func finishSetup() {
        guard readiness.canFinish else { return }
        onComplete?()
        close()
    }
}

private final class SetupStatusRow: NSStackView {
    let button = NSButton(title: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let title: String
    private let statusLabel = NSTextField(labelWithString: "")

    init(title: String) {
        self.title = title
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10

        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.widthAnchor.constraint(equalToConstant: 138).isActive = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(icon)
        addArrangedSubview(titleLabel)
        addArrangedSubview(statusLabel)
        addArrangedSubview(button)
    }

    required init?(coder: NSCoder) { nil }

    func set(status: String, ready: Bool, actionTitle: String?) {
        statusLabel.stringValue = status
        icon.image = NSImage(
            systemSymbolName: ready ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: ready ? "Ready" : "Action required"
        )
        icon.contentTintColor = ready ? .systemGreen : .secondaryLabelColor
        button.title = actionTitle ?? ""
        button.isHidden = actionTitle == nil
        button.setAccessibilityLabel(actionTitle.map { "\($0) \(title)" })
    }
}
