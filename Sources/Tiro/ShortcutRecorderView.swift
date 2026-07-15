import AppKit

final class ShortcutRecorderView: NSStackView {
    var onShortcutChanged: ((DictationShortcut) -> Void)?
    var onCaptureStarted: (() -> Void)?
    var onCaptureEnded: ((Set<UInt16>) -> Void)?

    var shortcut: DictationShortcut {
        didSet { updateButtonTitle() }
    }

    private let shortcutButton = NSButton()
    private let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    private let validationLabel = NSTextField(labelWithString: "")
    private var eventMonitor: Any?
    private var pressedModifierKeys = Set<UInt16>()
    private var modifierKeysInGesture = Set<UInt16>()
    private var capturedOrdinaryKey = false
    private var pendingOrdinaryShortcut: DictationShortcut?
    private var pendingOrdinaryKeyReleased = false
    private var suppressedKeyCodes = Set<UInt16>()

    init(shortcut: DictationShortcut = .load()) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    func beginCapture() {
        guard eventMonitor == nil else { return }
        pressedModifierKeys.removeAll()
        modifierKeysInGesture.removeAll()
        capturedOrdinaryKey = false
        pendingOrdinaryShortcut = nil
        pendingOrdinaryKeyReleased = false
        suppressedKeyCodes.removeAll()
        validationLabel.stringValue = "Press a shortcut"
        validationLabel.textColor = .secondaryLabelColor
        validationLabel.isHidden = false
        shortcutButton.title = "Recording..."
        shortcutButton.setAccessibilityLabel("Recording dictation shortcut")
        onCaptureStarted?()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
            [weak self] event in
            self?.capture(event) ?? event
        }
    }

    func endCapture() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
        let keysToDrain = suppressedKeyCodes
        pressedModifierKeys.removeAll()
        modifierKeysInGesture.removeAll()
        capturedOrdinaryKey = false
        pendingOrdinaryShortcut = nil
        pendingOrdinaryKeyReleased = false
        suppressedKeyCodes.removeAll()
        validationLabel.isHidden = true
        updateButtonTitle()
        onCaptureEnded?(keysToDrain)
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 6

        shortcutButton.target = self
        shortcutButton.action = #selector(recordShortcut)
        shortcutButton.bezelStyle = .rounded
        shortcutButton.toolTip = "Change dictation shortcut"
        shortcutButton.setAccessibilityRole(.button)

        resetButton.target = self
        resetButton.action = #selector(resetShortcut)
        resetButton.bezelStyle = .rounded
        resetButton.toolTip = "Reset to Right Command"

        validationLabel.textColor = .systemRed
        validationLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.lineBreakMode = .byWordWrapping
        validationLabel.maximumNumberOfLines = 2
        validationLabel.isHidden = true

        let controls = NSStackView(views: [shortcutButton, resetButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        addArrangedSubview(controls)
        addArrangedSubview(validationLabel)
        updateButtonTitle()
    }

    private func capture(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode
        if event.type == .flagsChanged, keyCode == 57 || keyCode == 63 {
            let isDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
            if isDown { suppressedKeyCodes.insert(keyCode) } else { suppressedKeyCodes.remove(keyCode) }
            showValidation(keyCode == 57 ? "Caps Lock cannot be used as the dictation shortcut."
                : "Fn cannot be used as the dictation shortcut.")
            return nil
        }
        if event.type == .flagsChanged, let modifier = DictationShortcut.ModifierKey(keyCode: keyCode) {
            let isDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
            if isDown {
                pressedModifierKeys.insert(keyCode)
                modifierKeysInGesture.insert(keyCode)
                suppressedKeyCodes.insert(keyCode)
            } else {
                pressedModifierKeys.remove(keyCode)
                suppressedKeyCodes.remove(keyCode)
                if pressedModifierKeys.isEmpty, !capturedOrdinaryKey {
                    if modifierKeysInGesture.count == 1 {
                        accept(.modifier(modifier))
                    } else {
                        showValidation("Use one side-specific modifier by itself, or add an ordinary key.")
                        modifierKeysInGesture.removeAll()
                    }
                } else if pressedModifierKeys.isEmpty {
                    if let candidate = pendingOrdinaryShortcut, pendingOrdinaryKeyReleased {
                        accept(candidate)
                        return nil
                    }
                    capturedOrdinaryKey = false
                    modifierKeysInGesture.removeAll()
                }
            }
            return nil
        }

        if event.type == .keyUp {
            suppressedKeyCodes.remove(event.keyCode)
            if let candidate = pendingOrdinaryShortcut,
               case let .ordinary(keyCode, _) = candidate.key,
               keyCode == event.keyCode {
                pendingOrdinaryKeyReleased = true
                if pressedModifierKeys.isEmpty {
                    accept(candidate)
                } else {
                    validationLabel.stringValue = "Release modifiers to save"
                    validationLabel.textColor = .secondaryLabelColor
                }
                return nil
            }
            if pressedModifierKeys.isEmpty {
                capturedOrdinaryKey = false
                modifierKeysInGesture.removeAll()
            }
            return nil
        }
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        suppressedKeyCodes.insert(keyCode)
        capturedOrdinaryKey = true
        let candidate = DictationShortcut.ordinary(
            keyCode: keyCode,
            modifiers: .init(eventFlags: event.modifierFlags),
            characters: event.charactersIgnoringModifiers ?? ""
        )
        if let error = candidate.validationError {
            showValidation(error.localizedDescription)
        } else {
            pendingOrdinaryShortcut = candidate
            pendingOrdinaryKeyReleased = false
            validationLabel.stringValue = "Release shortcut to save"
            validationLabel.textColor = .secondaryLabelColor
            validationLabel.isHidden = false
        }
        return nil
    }

    private func accept(_ candidate: DictationShortcut) {
        shortcut = candidate
        validationLabel.isHidden = true
        endCapture()
        onShortcutChanged?(candidate)
    }

    private func showValidation(_ message: String) {
        validationLabel.stringValue = message
        validationLabel.textColor = .systemRed
        validationLabel.isHidden = false
        shortcutButton.title = "Recording..."
    }

    private func updateButtonTitle() {
        shortcutButton.title = shortcut.displayName
        shortcutButton.setAccessibilityLabel("Dictation shortcut: \(shortcut.displayName)")
    }

    @objc private func recordShortcut() {
        eventMonitor == nil ? beginCapture() : endCapture()
    }

    @objc private func resetShortcut() {
        endCapture()
        shortcut = .default
        validationLabel.isHidden = true
        onShortcutChanged?(shortcut)
    }
}
