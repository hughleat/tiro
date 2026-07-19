import AppKit
import AVFoundation

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
    private let modelRow = SetupStatusRow(title: "Transcription model")
    private let downloadProgress = NSProgressIndicator()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let finishButton = NSButton(title: "Finish Setup", target: nil, action: nil)
    private var readiness = SetupReadiness(
        microphoneAllowed: false,
        accessibilityAllowed: false,
        installedModelKeys: []
    )
    private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private var models: [ManagedModel] = []
    private var refreshTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(service: TiroService, shortcutName: String) {
        self.service = service
        self.shortcutName = shortcutName
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Tiro"
        window.minSize = NSSize(width: 540, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        refreshTask?.cancel()
        downloadTask?.cancel()
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
            installedModelKeys: readiness.installedModelKeys
        )
        render()
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
        modelRow.button.action = #selector(downloadCompactModel)

        downloadProgress.style = .bar
        downloadProgress.minValue = 0
        downloadProgress.maxValue = 100
        downloadProgress.isDisplayedWhenStopped = false
        downloadProgress.controlSize = .small

        let shortcutTitle = NSTextField(labelWithString: "Shortcut")
        shortcutTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let shortcutValue = NSTextField(labelWithString: shortcutName)
        shortcutValue.textColor = .secondaryLabelColor
        shortcutValue.alignment = .right
        let shortcutRow = NSStackView(views: [shortcutTitle, NSView(), shortcutValue])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 12

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
            modelRow,
            downloadProgress,
            secondSeparator,
            shortcutRow,
            footer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(7, after: title)
        stack.setCustomSpacing(20, after: privacy)
        stack.setCustomSpacing(20, after: shortcutRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        for view in [privacy, firstSeparator, microphoneRow, accessibilityRow, modelRow,
                     downloadProgress, secondSeparator, shortcutRow, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
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
        if let compact = models.first(where: { $0.key == DictationModel.coreMLCompactKey }),
           compact.downloading {
            downloadProgress.isIndeterminate = compact.progress == nil
            downloadProgress.doubleValue = (compact.progress ?? 0) * 100
            downloadProgress.startAnimation(nil)
        }
        let installed = Set(models.lazy.filter { $0.installed && !$0.deleting }.map(\.key))
        readiness = SetupReadiness(
            microphoneAllowed: readiness.microphoneAllowed,
            accessibilityAllowed: readiness.accessibilityAllowed,
            installedModelKeys: installed
        )
        onModelsChanged?(models)
        render()
        if models.contains(where: { $0.downloading }) {
            if pollTask == nil { startPolling() }
        } else if downloadTask == nil {
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

        if readiness.hasInstalledModel {
            let installedName = models.first(where: { readiness.installedModelKeys.contains($0.key) })?.name
                ?? "Installed"
            modelRow.set(status: installedName, ready: true, actionTitle: nil)
        } else if models.first(where: { $0.key == "coreml-compact" })?.downloading == true
                    || downloadTask != nil {
            modelRow.set(status: "Downloading Parakeet Compact...", ready: false, actionTitle: nil)
        } else {
            modelRow.set(status: "Parakeet Compact, 220 MB", ready: false, actionTitle: "Download")
            modelRow.button.action = #selector(downloadCompactModel)
        }
        finishButton.isEnabled = readiness.canFinish
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

    @objc private func retryModels() {
        messageLabel.isHidden = true
        modelRow.button.action = #selector(downloadCompactModel)
        refreshModels()
    }

    @objc private func downloadCompactModel() {
        guard downloadTask == nil else { return }
        messageLabel.isHidden = true
        downloadProgress.startAnimation(nil)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.downloadModel(key: "coreml-compact")
                guard !Task.isCancelled else { return }
                DictationModel.select(DictationModel.all[0])
                let models = await service.models()
                downloadTask = nil
                stopPolling()
                downloadProgress.stopAnimation(nil)
                apply(models)
                onDownloadCompleted?()
            } catch {
                guard !Task.isCancelled else { return }
                downloadTask = nil
                stopPolling()
                downloadProgress.stopAnimation(nil)
                showError(error.localizedDescription)
                render()
            }
        }
        render()
        startPolling()
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
