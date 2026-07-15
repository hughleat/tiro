import AppKit
import AVFoundation
import ApplicationServices

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State { case idle, starting, recording, transcribing }

    private let recorder = AudioRecorder()
    private let worker = WorkerClient()
    private let overlay = OverlayPanel()
    private let recordingSounds = RecordingSoundPlayer()
    private let hotkeys = HotkeyManager()
    private let destinationTracker = DestinationTracker()
    private let pasteCoordinator = PasteCoordinator()
    private lazy var settingsWindow = SettingsWindowController(workerClient: worker)
    private var statusItem: NSStatusItem!
    private var state: State = .idle
    private var menuToggleItem: NSMenuItem!
    private var shortcutStatusItem: NSMenuItem!
    private var modelStatusItem: NSMenuItem!
    private var modelMenuItems: [NSMenuItem] = []
    private var installedModelKeys: Set<String> = []
    private var modelStartupTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var hotkeysStarted = false
    private var isCapturingShortcut = false
    private var destinationSession: DestinationSession?
    private var originApplication: ApplicationIdentity?
    private var shouldAutoPaste = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoPaste": true, "soundFeedback": true])
        _ = try? VocabularyFile.load()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureSettings()
        requestPermissionsAndStart()
        prepareInstalledModel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        modelStartupTask?.cancel()
        hotkeys.stop()
        worker.stopOwnedWorker()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Tiro")

        let menu = NSMenu()
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
        let settings = NSMenuItem(title: "Settings & History…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tiro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func configureSettings() {
        settingsWindow.onModelChanged = { [weak self] model in
            self?.updateModelChecks()
            if self?.installedModelKeys.contains(model.key) == true {
                self?.modelStatusItem.title = "Model: Loads on First Dictation"
            }
        }
        settingsWindow.onModelsChanged = { [weak self] models in
            self?.applyModelInventory(models)
        }
        settingsWindow.onShortcutChanged = { [weak self] shortcut in
            guard let self else { return }
            do {
                try shortcut.save()
                try self.hotkeys.updateShortcut(shortcut)
                self.updateShortcutStatus(trusted: AXIsProcessTrusted())
            } catch {
                self.presentError(error)
            }
        }
        settingsWindow.onShortcutCaptureChanged = { [weak self] isCapturing, suppressedKeys in
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
    }

    private func requestPermissionsAndStart() {
        hotkeys.onTap = { [weak self] in self?.toggleRecording() }
        hotkeys.onHoldStart = { [weak self] in self?.startRecording() == true }
        hotkeys.onHoldEnd = { [weak self] in self?.stopRecording() }
        hotkeys.onHoldCancel = { [weak self] in self?.cancelRecording() }
        hotkeys.onEscape = { [weak self] in self?.cancelRecording() }
        hotkeys.shouldHandleEscape = { [weak self] in
            self?.state == .starting || self?.state == .recording
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        installHotkeysWhenPermitted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.installHotkeysWhenPermitted() }
        }
    }

    private func installHotkeysWhenPermitted() {
        let trusted = AXIsProcessTrusted()
        updateShortcutStatus(trusted: trusted)
        if !trusted {
            if hotkeysStarted {
                hotkeys.stop()
                hotkeysStarted = false
            }
            return
        }

        guard !isCapturingShortcut else { return }
        guard !hotkeysStarted else { return }
        do {
            try hotkeys.start()
            hotkeysStarted = true
        } catch {
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

    @objc private func toggleRecording() {
        switch state {
        case .idle: startRecording()
        case .starting: cancelRecording()
        case .recording: stopRecording()
        case .transcribing: break
        }
    }

    @discardableResult
    private func startRecording() -> Bool {
        guard state == .idle else { return false }
        guard installedModelKeys.contains(DictationModel.selected.key) else {
            modelStatusItem.title = "Model: Download One in Settings"
            return false
        }
        shouldAutoPaste = UserDefaults.standard.bool(forKey: "autoPaste")
        originApplication = destinationTracker.captureApplicationIdentity()
        destinationSession = destinationTracker.capture()
        if shouldAutoPaste, destinationSession == nil {
            NSLog("Could not capture the focused destination; transcription will be copied.")
        }
        state = .starting
        menuToggleItem.title = "Cancel Starting"
        if UserDefaults.standard.bool(forKey: "soundFeedback") {
            recordingSounds.playStart { [weak self] in self?.beginRecording() }
        } else {
            beginRecording()
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
                    let response = try await worker.transcribe(
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
        if !response.text.isEmpty {
            if shouldAutoPaste, let destination {
                do {
                    try await pasteCoordinator.paste(response.text, to: destination)
                } catch {
                    copyToClipboard(response.text)
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
        overlay.show(.success)
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
    }

    @objc private func showSettings() {
        settingsWindow.showWindow(nil)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              installedModelKeys.contains(key),
              let model = DictationModel.all.first(where: { $0.key == key }) else { return }
        DictationModel.select(model)
        updateModelChecks()
        settingsWindow.refreshModel()
        modelStatusItem.title = "Model: Loads on First Dictation"
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
        modelStatusItem.title = "Model: Checking Installed Models…"
        modelStartupTask?.cancel()
        modelStartupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await worker.models()
                guard !Task.isCancelled else { return }
                guard let model = applyModelInventory(models) else {
                    modelStatusItem.title = "Model: None Installed"
                    return
                }
                modelStatusItem.title = "Model: Loading…"
                try await worker.preload(model: model)
                guard !Task.isCancelled else { return }
                if DictationModel.selected == model {
                    modelStatusItem.title = "Model: Ready"
                }
            } catch {
                guard !Task.isCancelled else { return }
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
            modelStatusItem.title = "Model: None Installed"
            return nil
        }
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
