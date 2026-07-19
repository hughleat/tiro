import AppKit
import AVFoundation
import ApplicationServices

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, starting, recording, transcribing }

    private let recorder = AudioRecorder()
    private let service = TiroService()
    private let overlay = OverlayPanel()
    private let recordingSounds = RecordingSoundPlayer()
    private let hotkeys = HotkeyManager()
    private let destinationTracker = DestinationTracker()
    private let pasteCoordinator = PasteCoordinator()
    private let supportPromptPolicy = SupportPromptPolicy()
    private lazy var supportPromptWindow = makeSupportPromptWindow()
    private lazy var settingsWindow = makeSettingsWindow()
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
    private var permissionTimer: Timer?
    private var supportPromptTimer: Timer?
    private var hotkeysStarted = false
    private var isCapturingShortcut = false
    private var destinationSession: DestinationSession?
    private var originApplication: ApplicationIdentity?
    private var shouldAutoPaste = false
    private var awaitingPrivacyReview = false
    private var isPresentingRecovery = false
    private var supportPromptSuppressedUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoPaste": true, "soundFeedback": true])
        supportPromptPolicy.registerLaunch()
        AudioRecorder.removeStaleRecordings()
        _ = try? VocabularyFile.load()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePermissionsAndStart()
        prepareInstalledModel()
        if !UserDefaults.standard.bool(forKey: "setupCompleted") {
            showSetup()
        } else {
            scheduleNextSupportPromptCheck(minimumDelay: 1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        supportPromptTimer?.invalidate()
        modelStartupTask?.cancel()
        hotkeys.stop()
        PasteEventGate.shared.stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")

        let menu = NSMenu()
        menu.delegate = self
        menuToggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        menuToggleItem.target = self
        menu.addItem(menuToggleItem)

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
        let support = NSMenuItem(title: "Support Tiro…", action: #selector(supportTiro), keyEquivalent: "")
        support.target = self
        menu.addItem(support)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tiro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
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

    private func makeSupportPromptWindow() -> SupportPromptWindowController {
        let controller = SupportPromptWindowController()
        controller.onSupport = {
            NSWorkspace.shared.open(SupportPromptPolicy.sponsorsURL)
        }
        controller.onAlreadySupporting = { [weak self] in
            self?.supportPromptPolicy.markAlreadySupporting()
            self?.supportPromptTimer?.invalidate()
        }
        return controller
    }

    private func configurePermissionsAndStart() {
        hotkeys.onTap = { [weak self] in self?.toggleRecording() }
        hotkeys.onHoldStart = { [weak self] in self?.startRecording(playStartSound: false) == true }
        hotkeys.onHoldEnd = { [weak self] in self?.stopRecording() }
        hotkeys.onHoldCancel = { [weak self] in self?.cancelRecording() }
        hotkeys.onEscape = { [weak self] in self?.cancelRecording() }
        hotkeys.shouldHandleEscape = { [weak self] in
            self?.state == .starting || self?.state == .recording
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
        supportPromptWindow.close()
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

    private func beginRecording() {
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
            presentError(error)
        }
    }

    private func stopRecording() {
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

            Task {
                defer { try? FileManager.default.removeItem(at: wavURL) }
                do {
                    let response = try await service.transcribe(
                        wavURL: wavURL,
                        model: model,
                        originBundleID: originBundleID,
                        originName: originName
                    )
                    await complete(response, model: model)
                } catch {
                    await MainActor.run { presentError(error) }
                }
            }
        } catch {
            presentError(error)
        }
    }

    private func cancelRecording() {
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
        destinationSession = nil
        originApplication = nil
        if UserDefaults.standard.bool(forKey: "soundFeedback") { recordingSounds.playStop() }
        state = .idle
        menuToggleItem.title = "Start Recording"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")
        statusItem.button?.contentTintColor = nil
        overlay.dismiss()
    }

    private func complete(_ response: TranscriptionResponse, model: DictationModel) async {
        let destination = destinationSession
        destinationSession = nil
        originApplication = nil
        var completionOverlay = OverlayState.copied
        if !response.text.isEmpty {
            supportPromptPolicy.recordSuccessfulTranscription()
            scheduleNextSupportPromptCheck(minimumDelay: 1)
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
            supportPromptSuppressedUntil = Date().addingTimeInterval(60)
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
        case .openMicrophoneSettings, .openAccessibilitySettings: return "Open Permissions"
        case .openModels: return "Open Models"
        case .retryModels: return "Retry"
        case .retryTranscription: return "OK"
        }
    }

    private func performRecovery(_ action: RecoveryAction) {
        switch action {
        case .openMicrophoneSettings, .openAccessibilitySettings:
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

    @objc private func supportTiro() {
        NSWorkspace.shared.open(SupportPromptPolicy.sponsorsURL)
    }

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
            self?.scheduleNextSupportPromptCheck()
        }
        return controller
    }

    func menuDidClose(_ menu: NSMenu) {
        handleSupportPromptCheck()
    }

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
        DictationModel.select(model)
        updateModelChecks()
        settingsWindow.refreshModel()
        modelStatusItem.title = "Model: Loads on First Dictation"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.activate(model: model)
                let models = await service.models()
                applyModelInventory(models)
            } catch {
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
        installedModelKeys = Set(models.lazy.filter { $0.installed && !$0.deleting }.map(\.key))
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
