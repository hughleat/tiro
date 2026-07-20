import AppKit
import AVFoundation
import ApplicationServices
import TiroIPC
import TiroRecognition
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, starting, recording, transcribing }
    private struct CommandRecording {
        let session: UUID
        let model: DictationModel
        let saveToHistory: Bool
    }

    private let recorder = AudioRecorder()
    private let service = TiroService()
    private let overlay = OverlayPanel()
    private let recordingSounds = RecordingSoundPlayer()
    private let hotkeys = HotkeyManager()
    private let destinationTracker = DestinationTracker()
    private let pasteCoordinator = PasteCoordinator()
    private let commandServer = TiroCommandSocketServer()
#if TIRO_SPONSORSHIP_ENABLED
    private let supportPromptPolicy = SupportPromptPolicy()
    private lazy var supportPromptWindow = makeSupportPromptWindow()
#endif
    private lazy var settingsWindow = makeSettingsWindow()
    private lazy var fileTranscriptionWindow = makeFileTranscriptionWindow()
    private var onboardingWindow: OnboardingWindowController?
    private var statusItem: NSStatusItem!
    private var state: State = .idle
    private var menuToggleItem: NSMenuItem!
    private var shortcutStatusItem: NSMenuItem!
    private var pasteRecoveryItem: NSMenuItem!
    private var privacyNoticeItem: NSMenuItem!
    private var modelStatusItem: NSMenuItem!
    private var modelMenuItems: [NSMenuItem] = []
    private var installedModelKeys: Set<String> = []
    private var modelInventoryStatus = ModelInventoryStatus.loading
    private var modelStartupTask: Task<Void, Never>?
    private var modelSelectionTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionID: UUID?
    private var commandRecording: CommandRecording?
    private var commandTranscriptionTask: Task<TranscriptionResponse, Error>?
    private var externalOperationID: UUID?
    private var permissionTimer: Timer?
#if TIRO_SPONSORSHIP_ENABLED
    private var supportPromptTimer: Timer?
#endif
    private var hotkeysStarted = false
    private var isCapturingShortcut = false
    private var destinationSession: DestinationSession?
    private var originApplication: ApplicationIdentity?
    private var shouldAutoPaste = false
    private var awaitingPrivacyReview = false
    private var isPresentingRecovery = false
#if TIRO_SPONSORSHIP_ENABLED
    private var supportPromptSuppressedUntil: Date?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoPaste": true, "soundFeedback": true])
#if TIRO_SPONSORSHIP_ENABLED
        supportPromptPolicy.registerLaunch()
#endif
        AudioRecorder.removeStaleRecordings()
        _ = try? VocabularyFile.load()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        startCommandServer()
        configurePermissionsAndStart()
        prepareInstalledModel()
        if !UserDefaults.standard.bool(forKey: "setupCompleted") {
            showSetup()
        }
#if TIRO_SPONSORSHIP_ENABLED
        if UserDefaults.standard.bool(forKey: "setupCompleted") {
            scheduleNextSupportPromptCheck(minimumDelay: 1)
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
#if TIRO_SPONSORSHIP_ENABLED
        supportPromptTimer?.invalidate()
#endif
        modelStartupTask?.cancel()
        modelSelectionTask?.cancel()
        transcriptionTask?.cancel()
        commandTranscriptionTask?.cancel()
        hotkeys.stop()
        PasteEventGate.shared.stop()
        commandServer.stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")

        let menu = NSMenu()
        menu.delegate = self
        menuToggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        menuToggleItem.target = self
        menu.addItem(menuToggleItem)

        let transcribeFile = NSMenuItem(
            title: "Transcribe Audio File...",
            action: #selector(showFileTranscription),
            keyEquivalent: "o"
        )
        transcribeFile.target = self
        menu.addItem(transcribeFile)

        let modelMenu = NSMenu()
        for model in DictationModel.all {
            let item = NSMenuItem(title: "\(model.name) — \(model.detail)", action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.key
            modelMenu.addItem(item)
            modelMenuItems.append(item)
        }
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)
        updateModelChecks()
        modelStatusItem = NSMenuItem(title: "Model: Loading…", action: nil, keyEquivalent: "")
        modelStatusItem.isEnabled = false
        menu.addItem(modelStatusItem)

        menu.addItem(.separator())
        shortcutStatusItem = NSMenuItem(
            title: "Right Command Shortcut: Checking…",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        shortcutStatusItem.target = self
        menu.addItem(shortcutStatusItem)
        pasteRecoveryItem = NSMenuItem(
            title: "Auto-paste needs Accessibility permission...",
            action: #selector(showPermissionsSettings),
            keyEquivalent: ""
        )
        pasteRecoveryItem.target = self
        pasteRecoveryItem.isHidden = true
        menu.addItem(pasteRecoveryItem)
        privacyNoticeItem = NSMenuItem(
            title: "Review Updated Privacy Settings...",
            action: #selector(reviewPrivacySettings),
            keyEquivalent: ""
        )
        privacyNoticeItem.target = self
        let hasLegacyStorage = FileManager.default.fileExists(atPath: AppPaths.historyFile.path)
            || FileManager.default.fileExists(atPath: AppPaths.legacyRetentionFile.path)
        privacyNoticeItem.isHidden = !hasLegacyStorage
            || UserDefaults.standard.bool(forKey: "privacyMigrationNoticeReviewed")
        menu.addItem(privacyNoticeItem)
        let settings = NSMenuItem(title: "Settings & History…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let setup = NSMenuItem(title: "Setup…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
#if TIRO_SPONSORSHIP_ENABLED
        let support = NSMenuItem(
            title: BuildFeatures.sponsorshipMenuTitle!,
            action: #selector(supportTiro),
            keyEquivalent: ""
        )
        support.target = self
        menu.addItem(support)
#endif
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tiro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func startCommandServer() {
        do {
            try commandServer.start { [weak self] request, responder in
                guard let self else {
                    try await responder.sendFailure(
                        code: "app_unavailable",
                        message: "Tiro is shutting down."
                    )
                    return
                }
                await self.handleCommand(request, responder: responder)
            }
        } catch {
            NSLog("Could not start Tiro command server: %@", error.localizedDescription)
        }
    }

    private func handleCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async {
        do {
            if request.command != .status,
               request.command != .models,
               !UserDefaults.standard.bool(forKey: "setupCompleted") {
                try await responder.sendFailure(
                    code: "setup_required",
                    message: "Finish Tiro setup before using command-line transcription."
                )
                return
            }
            switch request.command {
            case .status:
                try await responder.sendSuccess(TiroCommandResult(
                    kind: "status",
                    state: commandState,
                    selectedModel: DictationModel.selected.key
                ))
            case .models:
                let models = await service.models()
                try await responder.sendSuccess(TiroCommandResult(
                    kind: "models",
                    models: models.map {
                        TiroCommandModel(
                            key: $0.key,
                            name: $0.name,
                            installed: $0.installed,
                            transcription: $0.dictationModel != nil
                        )
                    }
                ))
            case .transcribe:
                try await handleTranscribeCommand(request, responder: responder)
            case .recordStart:
                try await handleRecordStartCommand(request, responder: responder)
            case .recordStop:
                try await handleRecordStopCommand(request, responder: responder)
            case .recordCancel:
                try await handleRecordCancelCommand(request, responder: responder)
            }
        } catch {
            try? await responder.sendFailure(
                code: "transcription_failed",
                message: error.localizedDescription
            )
        }
    }

    private func handleTranscribeCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async throws {
        guard state == .idle, commandRecording == nil, externalOperationID == nil else {
            try await responder.sendFailure(
                code: "busy",
                message: "Tiro is already recording or transcribing."
            )
            return
        }
        let operationID = UUID()
        externalOperationID = operationID
        state = .transcribing
        menuToggleItem.title = "Transcribing..."
        defer {
            if externalOperationID == operationID {
                externalOperationID = nil
                state = .idle
                menuToggleItem.title = "Start Recording"
            }
        }
        guard let arguments = request.arguments, let path = arguments.path else {
            throw TiroError.message("The command did not include an audio file.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: url.path),
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else {
            throw TiroError.message("The requested audio file is unavailable or unsupported.")
        }
        let model: DictationModel
        if let key = arguments.model {
            guard let requested = DictationModel.all.first(where: { $0.key == key }) else {
                throw TiroError.message("No Tiro model has the key \(key).")
            }
            model = requested
        } else {
            model = DictationModel.selected
        }

        try await responder.sendEvent(name: "transcribing", detail: url.lastPathComponent)
        let response = try await service.transcribe(
            audioURL: url,
            model: model,
            sourceFilename: url.lastPathComponent,
            archiveAudio: false,
            identifySpeakers: arguments.diarize ?? false,
            saveToHistory: arguments.saveHistory ?? true
        )
        if arguments.copy == true {
            copyToClipboard(response.text)
        }
        settingsWindow.refreshHistory()
        try await responder.sendSuccess(TiroCommandResult(
            kind: "transcript",
            text: response.text,
            model: response.model,
            historyID: (arguments.saveHistory ?? true) ? response.id : nil,
            transcriptionSeconds: response.transcription_seconds,
            segments: commandSegments(response.segments)
        ))
    }

    private func handleRecordStartCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async throws {
        guard state == .idle, commandRecording == nil else {
            try await responder.sendFailure(
                code: "busy",
                message: "Tiro is already recording or transcribing."
            )
            return
        }
        let arguments = request.arguments
        let model: DictationModel
        if let key = arguments?.model {
            guard let requested = DictationModel.all.first(where: { $0.key == key }) else {
                throw TiroError.message("No Tiro model has the key \(key).")
            }
            model = requested
        } else {
            model = DictationModel.selected
        }
        let recording = CommandRecording(
            session: UUID(),
            model: model,
            saveToHistory: arguments?.saveHistory ?? true
        )
        commandRecording = recording
        destinationSession = nil
        originApplication = nil
        shouldAutoPaste = false
        state = .starting
        menuToggleItem.title = "Recording from Command Line"
        do {
            try await service.preload(model: model)
        } catch {
            if commandRecording?.session == recording.session {
                commandRecording = nil
                finishCancelledTranscription()
            }
            throw error
        }
        guard commandRecording?.session == recording.session, state == .starting else {
            throw CancellationError()
        }
        beginRecording(reportErrors: false)
        guard state == .recording else {
            commandRecording = nil
            throw TiroError.message("Tiro could not start recording.")
        }
        do {
            try await responder.sendSuccess(TiroCommandResult(
                kind: "recording",
                model: model.key,
                state: "recording",
                session: recording.session.uuidString.lowercased()
            ))
        } catch {
            recorder.cancel()
            commandRecording = nil
            finishCancelledTranscription()
            throw error
        }
    }

    private func handleRecordStopCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async throws {
        guard let recording = matchingCommandRecording(request) else {
            try await responder.sendFailure(
                code: "recording_not_found",
                message: "That command-line recording session is not active."
            )
            return
        }
        guard state == .recording else {
            try await responder.sendFailure(
                code: "busy",
                message: "The recording is not ready to stop."
            )
            return
        }

        let audioURL = try recorder.stop()
        state = .transcribing
        menuToggleItem.title = "Transcribing..."
        overlay.show(.transcribing)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let task = Task { @MainActor [service] in
            try await service.transcribe(
                audioURL: audioURL,
                model: recording.model,
                archiveAudio: recording.saveToHistory,
                saveToHistory: recording.saveToHistory
            )
        }
        commandTranscriptionTask = task
        do {
            try await responder.sendEvent(name: "transcribing")
            let response = try await task.value
            guard commandRecording?.session == recording.session else {
                throw CancellationError()
            }
            if request.arguments?.copy == true {
                copyToClipboard(response.text)
            }
            commandRecording = nil
            commandTranscriptionTask = nil
            finishCancelledTranscription()
            settingsWindow.refreshHistory()
            try await responder.sendSuccess(TiroCommandResult(
                kind: "transcript",
                text: response.text,
                model: response.model,
                historyID: recording.saveToHistory ? response.id : nil,
                transcriptionSeconds: response.transcription_seconds,
                segments: commandSegments(response.segments)
            ))
        } catch {
            task.cancel()
            _ = await task.result
            if commandRecording?.session == recording.session {
                commandRecording = nil
                commandTranscriptionTask = nil
                finishCancelledTranscription()
            }
            throw error
        }
    }

    private func handleRecordCancelCommand(
        _ request: TiroCommandRequest,
        responder: TiroCommandResponder
    ) async throws {
        guard matchingCommandRecording(request) != nil else {
            try await responder.sendFailure(
                code: "recording_not_found",
                message: "That command-line recording session is not active."
            )
            return
        }
        if state == .transcribing {
            let task = commandTranscriptionTask
            task?.cancel()
            commandTranscriptionTask = nil
            commandRecording = nil
            if let task { _ = await task.result }
        } else {
            recorder.cancel()
            commandRecording = nil
        }
        finishCancelledTranscription()
        try await responder.sendSuccess(TiroCommandResult(
            kind: "cancelled",
            state: "idle"
        ))
    }

    private func matchingCommandRecording(_ request: TiroCommandRequest) -> CommandRecording? {
        guard let recording = commandRecording,
              let session = request.arguments?.session,
              UUID(uuidString: session) == recording.session else {
            return nil
        }
        return recording
    }

    private var commandState: String {
        switch state {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .transcribing: "transcribing"
        }
    }

    private func commandSegments(_ segments: [TranscriptSegment]) -> [TiroCommandSegment] {
        segments.map {
            TiroCommandSegment(
                text: $0.text,
                startTime: $0.startSeconds,
                endTime: $0.endSeconds,
                speakerID: $0.speakerID
            )
        }
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let controller = SettingsWindowController(service: service)
        controller.onModelChanged = { [weak self] model in
            self?.updateModelChecks()
            if self?.installedModelKeys.contains(model.key) == true {
                self?.modelStatusItem.title = "Model: Loads on First Dictation"
            }
        }
        controller.onModelsChanged = { [weak self] models in
            self?.applyModelInventory(models)
        }
        controller.onShortcutChanged = { [weak self] shortcut in
            guard let self else { return }
            do {
                try shortcut.save()
                try self.hotkeys.updateShortcut(shortcut)
                self.updateShortcutStatus(trusted: AXIsProcessTrusted())
            } catch {
                self.presentError(error)
            }
        }
        controller.onShortcutCaptureChanged = { [weak self] isCapturing, suppressedKeys in
            guard let self else { return }
            self.isCapturingShortcut = isCapturing
            if isCapturing {
                self.hotkeys.stop()
                self.hotkeysStarted = false
            } else {
                self.hotkeys.suppressUntilRelease(suppressedKeys)
                self.installHotkeysWhenPermitted()
            }
        }
        controller.onPrivacySettingsLoaded = { [weak self] in
            guard self?.awaitingPrivacyReview == true else { return }
            self?.awaitingPrivacyReview = false
            UserDefaults.standard.set(true, forKey: "privacyMigrationNoticeReviewed")
            self?.privacyNoticeItem.isHidden = true
        }
        return controller
    }

    private func makeFileTranscriptionWindow() -> FileTranscriptionWindowController {
        let controller = FileTranscriptionWindowController(service: service)
        controller.requestOperation = { [weak self] in
            guard let self,
                  self.state == .idle,
                  self.commandRecording == nil,
                  self.externalOperationID == nil else { return false }
            self.externalOperationID = UUID()
            self.state = .transcribing
            self.menuToggleItem.title = "Transcribing File..."
            return true
        }
        controller.onOperationEnded = { [weak self] in
            guard let self, self.externalOperationID != nil else { return }
            self.externalOperationID = nil
            self.state = .idle
            self.menuToggleItem.title = "Start Recording"
        }
        controller.onTranscriptionCompleted = { [weak self] in
            self?.settingsWindow.refreshHistory()
        }
        return controller
    }

#if TIRO_SPONSORSHIP_ENABLED
    private func makeSupportPromptWindow() -> SupportPromptWindowController {
        let controller = SupportPromptWindowController()
        controller.onSupport = {
            NSWorkspace.shared.open(BuildFeatures.sponsorsURL)
        }
        controller.onAlreadySupporting = { [weak self] in
            self?.supportPromptPolicy.markAlreadySupporting()
            self?.supportPromptTimer?.invalidate()
        }
        return controller
    }
#endif

    private func configurePermissionsAndStart() {
        hotkeys.onTap = { [weak self] in self?.toggleRecording() }
        hotkeys.onHoldStart = { [weak self] in self?.startRecording(playStartSound: false) == true }
        hotkeys.onHoldEnd = { [weak self] in self?.stopRecording() }
        hotkeys.onHoldCancel = { [weak self] in self?.cancelRecording() }
        hotkeys.onEscape = { [weak self] in self?.cancelRecording() }
        hotkeys.shouldHandleEscape = { [weak self] in
            guard let self,
                  self.commandRecording == nil,
                  self.externalOperationID == nil else { return false }
            return self.state == .starting || self.state == .recording
                || self.state == .transcribing
        }

        installHotkeysWhenPermitted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.installHotkeysWhenPermitted()
                self?.refreshSetupPermissions()
            }
        }
    }

    private func installHotkeysWhenPermitted() {
        let trusted = AXIsProcessTrusted()
        updateShortcutStatus(trusted: trusted)
        if !trusted {
            if hotkeysStarted {
                hotkeys.stop()
                PasteEventGate.shared.stop()
                hotkeysStarted = false
            }
            return
        }

        guard !isCapturingShortcut else { return }
        do {
            if hotkeysStarted {
                try hotkeys.maintain()
                try PasteEventGate.shared.maintain()
            } else {
                try PasteEventGate.shared.start()
                try hotkeys.start()
                hotkeysStarted = true
                NSLog("Installed the global dictation shortcut.")
            }
        } catch {
            hotkeys.stop()
            PasteEventGate.shared.stop()
            hotkeysStarted = false
            shortcutStatusItem.title = "\(hotkeys.shortcut.displayName) Shortcut Unavailable"
            shortcutStatusItem.state = .off
            NSLog("Could not install global dictation keys: %@", error.localizedDescription)
        }
    }

    private func updateShortcutStatus(trusted: Bool) {
        let name = hotkeys.shortcut.displayName
        shortcutStatusItem.title = trusted ? "\(name) Shortcut Enabled" : "Enable \(name) Shortcut…"
        shortcutStatusItem.state = trusted ? .on : .off
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestMicrophoneAccess() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshSetupPermissions() }
            }
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleRecording() {
        guard commandRecording == nil else { return }
        switch state {
        case .idle: startRecording()
        case .starting: cancelRecording()
        case .recording: stopRecording()
        case .transcribing: break
        }
    }

    @discardableResult
    private func startRecording(playStartSound: Bool = true) -> Bool {
        guard state == .idle else { return false }
#if TIRO_SPONSORSHIP_ENABLED
        supportPromptWindow.close()
#endif
        switch modelInventoryStatus {
        case .loading:
            modelStatusItem.title = "Model: Checking Installed Models..."
            overlay.show(.startingUp)
            overlay.dismiss(after: 1.2)
            return false
        case .unavailable:
            presentRecovery(ErrorRecovery.presentation(for: .modelServiceUnavailable))
            return false
        case .missing:
            modelStatusItem.title = "Model: Download One in Settings"
            presentRecovery(ErrorRecovery.presentation(for: .missingModel))
            return false
        case .available:
            break
        }
        shouldAutoPaste = UserDefaults.standard.bool(forKey: "autoPaste")
        originApplication = destinationTracker.captureApplicationIdentity()
        destinationSession = destinationTracker.capture()
        if shouldAutoPaste, destinationSession == nil {
            NSLog("Could not capture the focused destination; transcription will be copied.")
        }
        state = .starting
        menuToggleItem.title = "Cancel Starting"
        if playStartSound, UserDefaults.standard.bool(forKey: "soundFeedback") {
            recordingSounds.playStart { [weak self] in self?.beginRecording() }
        } else {
            beginRecording()
            if UserDefaults.standard.bool(forKey: "soundFeedback") {
                recordingSounds.playHoldStart()
            }
        }
        return true
    }

    private func beginRecording(reportErrors: Bool = true) {
        guard state == .starting else { return }
        do {
            try recorder.start()
            state = .recording
            menuToggleItem.title = "Stop Recording"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            statusItem.button?.contentTintColor = .systemRed
            overlay.showRecording(levelProvider: { [weak self] in
                self?.recorder.normalizedMicrophoneLevel ?? 0
            })
        } catch {
            if reportErrors {
                presentError(error)
            } else {
                commandRecording = nil
                state = .idle
                menuToggleItem.title = "Start Recording"
                NSLog("Could not start command-line recording: %@", error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        guard commandRecording == nil else { return }
        if state == .starting {
            cancelRecording()
            return
        }
        guard state == .recording else { return }
        do {
            let wavURL = try recorder.stop()
            if UserDefaults.standard.bool(forKey: "soundFeedback") { recordingSounds.playStop() }
            state = .transcribing
            menuToggleItem.title = "Transcribing…"
            overlay.show(.transcribing)
            let model = DictationModel.selected
            let originBundleID = originApplication?.bundleIdentifier
            let originName = originApplication?.applicationName

            let transcriptionID = UUID()
            self.transcriptionID = transcriptionID
            transcriptionTask = Task { [weak self] in
                guard let self else { return }
                defer { try? FileManager.default.removeItem(at: wavURL) }
                defer {
                    if self.transcriptionID == transcriptionID {
                        self.transcriptionTask = nil
                        self.transcriptionID = nil
                    }
                }
                do {
                    let response = try await service.transcribe(
                        audioURL: wavURL,
                        model: model,
                        originBundleID: originBundleID,
                        originName: originName
                    )
                    try Task.checkCancellation()
                    guard self.transcriptionID == transcriptionID else { return }
                    await complete(response, model: model)
                } catch is CancellationError {
                    if self.transcriptionID == transcriptionID {
                        finishCancelledTranscription()
                    }
                } catch {
                    if self.transcriptionID == transcriptionID {
                        await MainActor.run { self.presentError(error) }
                    }
                }
            }
        } catch {
            presentError(error)
        }
    }

    private func cancelRecording() {
        guard commandRecording == nil, externalOperationID == nil else { return }
        if state == .transcribing {
            transcriptionTask?.cancel()
            transcriptionID = nil
            finishCancelledTranscription()
            return
        }
        if state == .starting {
            recordingSounds.cancelStart()
            destinationSession = nil
            originApplication = nil
            state = .idle
            menuToggleItem.title = "Start Recording"
            return
        }
        guard state == .recording else { return }
        recorder.cancel()
        commandRecording = nil
        destinationSession = nil
        originApplication = nil
        if UserDefaults.standard.bool(forKey: "soundFeedback") { recordingSounds.playStop() }
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")
        statusItem.button?.contentTintColor = nil
        overlay.dismiss()
    }

    private func finishCancelledTranscription() {
        transcriptionTask = nil
        transcriptionID = nil
        destinationSession = nil
        originApplication = nil
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Tiro"
        )
        statusItem.button?.contentTintColor = nil
        overlay.dismiss()
    }

    private func complete(_ response: TranscriptionResponse, model: DictationModel) async {
        let destination = destinationSession
        destinationSession = nil
        originApplication = nil
        var completionOverlay = OverlayState.copied
        if !response.text.isEmpty {
#if TIRO_SPONSORSHIP_ENABLED
            supportPromptPolicy.recordSuccessfulTranscription()
            scheduleNextSupportPromptCheck(minimumDelay: 1)
#endif
            if shouldAutoPaste, let destination {
                do {
                    let result = try await pasteCoordinator.paste(response.text, to: destination)
                    completionOverlay = result == .confirmed ? .pasted : .pasteSent
                    pasteRecoveryItem.isHidden = true
                } catch {
                    copyToClipboard(response.text)
                    completionOverlay = .pasteFailed
                    pasteRecoveryItem.isHidden = ErrorRecovery.presentation(for: error).action
                        != .openAccessibilitySettings
                    NSLog("Could not auto-paste transcription: %@", error.localizedDescription)
                }
            } else {
                copyToClipboard(response.text)
            }
        }
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")
        statusItem.button?.contentTintColor = nil
        settingsWindow.refreshHistory()
        overlay.show(completionOverlay)
        overlay.dismiss(after: 0.8)
        if DictationModel.selected == model {
            modelStatusItem.title = "Model: Ready"
        }
    }

    private func presentError(_ error: Error) {
        if recorder.isRecording { recorder.cancel() }
        commandRecording = nil
        destinationSession = nil
        originApplication = nil
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")
        statusItem.button?.contentTintColor = nil
        overlay.show(.error)
        overlay.dismiss(after: 2.0)
        NSLog("Tiro error: %@", error.localizedDescription)
        presentRecovery(ErrorRecovery.presentation(
            for: error,
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        ))
    }

    private func presentRecovery(_ presentation: RecoveryPresentation) {
        guard presentation.action != .retryTranscription else { return }
        guard !isPresentingRecovery else { return }
        isPresentingRecovery = true
        defer {
            isPresentingRecovery = false
#if TIRO_SPONSORSHIP_ENABLED
            supportPromptSuppressedUntil = Date().addingTimeInterval(60)
#endif
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.detail
        alert.addButton(withTitle: recoveryButtonTitle(for: presentation.action))
        alert.addButton(withTitle: "Dismiss")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performRecovery(presentation.action)
    }

    private func recoveryButtonTitle(for action: RecoveryAction) -> String {
        switch action {
        case .openMicrophoneSettings, .openSpeechRecognitionSettings,
             .openAccessibilitySettings:
            return "Open Permissions"
        case .openModels: return "Open Models"
        case .retryModels: return "Retry"
        case .retryTranscription: return "OK"
        }
    }

    private func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .openMicrophoneSettings, .openSpeechRecognitionSettings,
             .openAccessibilitySettings:
            settingsWindow.showPermissionsSettings()
        case .openModels:
            settingsWindow.showModelsSettings()
        case .retryModels:
            prepareInstalledModel()
        case .retryTranscription:
            break
        }
    }

    @objc private func showSettings() {
        settingsWindow.showWindow(nil)
    }

    @objc private func showFileTranscription() {
        guard UserDefaults.standard.bool(forKey: "setupCompleted") else {
            showSetup()
            return
        }
        fileTranscriptionWindow.showWindow(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard UserDefaults.standard.bool(forKey: "setupCompleted") else {
            showSetup()
            presentError(TiroError.message(
                "Finish Tiro setup, then open the audio file again."
            ))
            return
        }
        guard urls.count == 1, let url = urls.first else {
            presentError(TiroError.message("Open one audio file at a time."))
            return
        }
        fileTranscriptionWindow.transcribe(url)
    }

#if TIRO_SPONSORSHIP_ENABLED
    @objc private func supportTiro() {
        NSWorkspace.shared.open(BuildFeatures.sponsorsURL)
    }
#endif

    @objc private func showPermissionsSettings() {
        settingsWindow.showPermissionsSettings()
    }

    @objc private func reviewPrivacySettings() {
        awaitingPrivacyReview = true
        settingsWindow.showPrivacySettings()
    }

    @objc private func showSetup() {
        let controller = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = controller
        controller.updatePermissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            accessibilityAllowed: AXIsProcessTrusted()
        )
        controller.showWindow(nil)
    }

    private func makeOnboardingWindow() -> OnboardingWindowController {
        let controller = OnboardingWindowController(
            service: service,
            shortcutName: hotkeys.shortcut.displayName
        )
        controller.onRequestMicrophone = { [weak self] in self?.requestMicrophoneAccess() }
        controller.onOpenAccessibility = { [weak self] in self?.openAccessibilitySettings() }
        controller.onModelsChanged = { [weak self] models in
            self?.applyModelInventory(models)
        }
        controller.onDownloadCompleted = { [weak self] in self?.prepareInstalledModel() }
        controller.onComplete = { [weak self] in
            UserDefaults.standard.set(true, forKey: "setupCompleted")
#if TIRO_SPONSORSHIP_ENABLED
            self?.scheduleNextSupportPromptCheck()
#endif
        }
        return controller
    }

    func menuDidClose(_ menu: NSMenu) {
#if TIRO_SPONSORSHIP_ENABLED
        handleSupportPromptCheck()
#endif
    }

#if TIRO_SPONSORSHIP_ENABLED
    private func scheduleNextSupportPromptCheck(minimumDelay: TimeInterval = 0) {
        supportPromptTimer?.invalidate()
        guard let due = supportPromptPolicy.nextPromptDate() else { return }
        let delay = max(minimumDelay, due.timeIntervalSinceNow)
        supportPromptTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleSupportPromptCheck() }
        }
    }

    private func handleSupportPromptCheck() {
        guard supportPromptPolicy.shouldPrompt() else {
            scheduleNextSupportPromptCheck()
            return
        }
        let presentation = SupportPromptPresentationState(
            isIdle: state == .idle,
            setupCompleted: UserDefaults.standard.bool(forKey: "setupCompleted"),
            onboardingVisible: onboardingWindow?.window?.isVisible == true,
            presentingRecovery: isPresentingRecovery,
            overlayVisible: overlay.isVisible,
            promptVisible: supportPromptWindow.window?.isVisible == true,
            suppressedUntil: supportPromptSuppressedUntil
        )
        guard presentation.canPresent() else {
            supportPromptTimer?.invalidate()
            supportPromptTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.handleSupportPromptCheck() }
            }
            return
        }
        supportPromptPolicy.markShown()
        supportPromptWindow.showWindow(nil)
        scheduleNextSupportPromptCheck()
    }
#endif

    private func refreshSetupPermissions() {
        guard let onboardingWindow, onboardingWindow.window?.isVisible == true else { return }
        onboardingWindow.updatePermissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio),
            accessibilityAllowed: AXIsProcessTrusted()
        )
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              installedModelKeys.contains(key),
              let model = DictationModel.all.first(where: { $0.key == key }) else { return }
        do {
            try service.select(model: model)
        } catch {
            presentError(error)
            return
        }
        updateModelChecks()
        settingsWindow.refreshModel()
        modelStatusItem.title = "Model: Loads on First Dictation"
        modelSelectionTask?.cancel()
        modelSelectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.activate(model: model)
                guard !Task.isCancelled else { return }
                let models = await service.models()
                guard !Task.isCancelled else { return }
                applyModelInventory(models)
            } catch {
                guard !Task.isCancelled else { return }
                presentError(error)
            }
        }
    }

    private func updateModelChecks() {
        let selected = DictationModel.selected
        for item in modelMenuItems {
            let key = item.representedObject as? String
            let isInstalled = key.map(installedModelKeys.contains) ?? false
            item.isEnabled = isInstalled
            item.state = isInstalled && key == selected.key ? .on : .off
        }
        menuToggleItem.isEnabled = installedModelKeys.contains(selected.key)
    }

    private func prepareInstalledModel() {
        modelInventoryStatus = .loading
        modelStatusItem.title = "Model: Checking Installed Models…"
        modelStartupTask?.cancel()
        modelStartupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = await service.models()
                guard !Task.isCancelled else { return }
                guard let model = applyModelInventory(models) else {
                    modelStatusItem.title = "Model: None Installed"
                    return
                }
                modelStatusItem.title = "Model: Loading…"
                try await service.preload(model: model)
                guard !Task.isCancelled else { return }
                if DictationModel.selected == model {
                    modelStatusItem.title = "Model: Ready"
                }
            } catch {
                guard !Task.isCancelled else { return }
                modelInventoryStatus = modelInventoryStatus.afterPreparationFailure
                modelStatusItem.title = "Model: Installed Models Unavailable"
                updateModelChecks()
                NSLog("Could not prepare an installed model: %@", error.localizedDescription)
            }
        }
    }

    @discardableResult
    private func applyModelInventory(_ models: [ManagedModel]) -> DictationModel? {
        installedModelKeys = Set(models.lazy.filter { $0.usable && !$0.deleting }.map(\.key))
        var selected = DictationModel.selected
        if !installedModelKeys.contains(selected.key),
           let fallback = DictationModel.all.first(where: { installedModelKeys.contains($0.key) }) {
            DictationModel.select(fallback)
            selected = fallback
        }
        updateModelChecks()
        guard installedModelKeys.contains(selected.key) else {
            modelInventoryStatus = .missing
            modelStatusItem.title = "Model: None Installed"
            return nil
        }
        modelInventoryStatus = .available
        if models.first(where: { $0.key == selected.key })?.loaded == true {
            modelStatusItem.title = "Model: Ready"
        } else {
            modelStatusItem.title = "Model: Loads on First Dictation"
        }
        return selected
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
