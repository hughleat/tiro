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
    private lazy var settingsWindow = SettingsWindowController()
    private var statusItem: NSStatusItem!
    private var state: State = .idle
    private var menuToggleItem: NSMenuItem!
    private var shortcutStatusItem: NSMenuItem!
    private var modelStatusItem: NSMenuItem!
    private var modelMenuItems: [NSMenuItem] = []
    private var permissionTimer: Timer?
    private var hotkeysStarted = false
    private var destinationSession: DestinationSession?
    private var shouldAutoPaste = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["autoPaste": true, "soundFeedback": true])
        _ = try? VocabularyFile.load()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureSettings()
        requestPermissionsAndStart()
        preloadSelectedModel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
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
        settingsWindow.onModelChanged = { [weak self] _ in
            self?.updateModelChecks()
            self?.modelStatusItem.title = "Model: Loads on First Dictation"
        }
    }

    private func requestPermissionsAndStart() {
        hotkeys.onTap = { [weak self] in self?.toggleRecording() }
        hotkeys.onHoldStart = { [weak self] in self?.startRecording() }
        hotkeys.onHoldEnd = { [weak self] in self?.stopRecording() }
        hotkeys.onEscape = { [weak self] in self?.cancelRecording() }

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
        if !trusted {
            if hotkeysStarted {
                hotkeys.stop()
                hotkeysStarted = false
            }
            shortcutStatusItem.title = "Enable Right Command Shortcut…"
            shortcutStatusItem.state = .off
            return
        }

        shortcutStatusItem.title = "Right Command Shortcut Enabled"
        shortcutStatusItem.state = .on
        guard !hotkeysStarted else { return }
        do {
            try hotkeys.start()
            hotkeysStarted = true
        } catch {
            shortcutStatusItem.title = "Right Command Shortcut Unavailable"
            shortcutStatusItem.state = .off
            NSLog("Could not install global dictation keys: %@", error.localizedDescription)
        }
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

    private func startRecording() {
        guard state == .idle else { return }
        destinationSession = destinationTracker.capture()
        shouldAutoPaste = UserDefaults.standard.bool(forKey: "autoPaste")
        state = .starting
        menuToggleItem.title = "Cancel Starting"
        if UserDefaults.standard.bool(forKey: "soundFeedback") {
            recordingSounds.playStart { [weak self] in self?.beginRecording() }
        } else {
            beginRecording()
        }
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

            Task {
                defer { try? FileManager.default.removeItem(at: wavURL) }
                do {
                    let response = try await worker.transcribe(wavURL: wavURL, model: model)
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
            state = .idle
            menuToggleItem.title = "Start Recording"
            return
        }
        guard state == .recording else { return }
        recorder.cancel()
        destinationSession = nil
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
              let model = DictationModel.all.first(where: { $0.key == key }) else { return }
        DictationModel.select(model)
        updateModelChecks()
        settingsWindow.refreshModel()
        modelStatusItem.title = "Model: Loads on First Dictation"
    }

    private func updateModelChecks() {
        let selected = DictationModel.selected
        for item in modelMenuItems {
            item.state = (item.representedObject as? String) == selected.key ? .on : .off
        }
    }

    private func preloadSelectedModel() {
        let model = DictationModel.selected
        modelStatusItem.title = "Model: Loading…"
        Task {
            do {
                try await worker.preload(model: model)
                if DictationModel.selected == model {
                    modelStatusItem.title = "Model: Ready"
                }
            } catch {
                if DictationModel.selected == model {
                    modelStatusItem.title = "Model: Preload Failed; Will Retry"
                }
                NSLog("Could not preload %@: %@", model.name, error.localizedDescription)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
