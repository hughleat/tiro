import AppKit
import ApplicationServices
import AVFoundation
import Speech

@MainActor
final class PermissionSettingsView: NSStackView {
    var onPermissionChanged: (() -> Void)?

    private let microphone = PermissionRow(
        symbolName: "mic",
        title: "Microphone",
        explanation: "Allows Tiro to record speech for local transcription.",
        buttonTitle: "Request Access"
    )
    private let accessibility = PermissionRow(
        symbolName: "accessibility",
        title: "Accessibility",
        explanation: "Enables the global shortcut and pastes transcriptions into other apps.",
        buttonTitle: "Open System Settings"
    )
    private let speechRecognition = PermissionRow(
        symbolName: "waveform",
        title: "Speech Recognition",
        explanation: "Allows transcription when Apple Speech is selected.",
        buttonTitle: "Request Access"
    )
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previousSpeechStatus: SFSpeechRecognizerAuthorizationStatus?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopRefreshing() : startRefreshing()
    }

    func refresh() {
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let accessibilityGranted = AXIsProcessTrusted()
        microphone.setStatus(
            text: Self.microphoneStatusText(microphoneStatus),
            granted: microphoneStatus == .authorized,
            buttonTitle: microphoneStatus == .notDetermined ? "Request Access" : "Open System Settings"
        )
        accessibility.setStatus(
            text: accessibilityGranted ? "Allowed" : "Not allowed",
            granted: accessibilityGranted,
            buttonTitle: "Open System Settings"
        )
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechRecognition.setStatus(
            text: Self.speechStatusText(speechStatus),
            granted: speechStatus == .authorized,
            buttonTitle: speechStatus == .notDetermined ? "Request Access" : "Open System Settings"
        )
        if let previousSpeechStatus, previousSpeechStatus != speechStatus {
            onPermissionChanged?()
        }
        previousSpeechStatus = speechStatus
    }

    private func buildContent() {
        orientation = .vertical
        alignment = .leading
        spacing = 0

        microphone.onAction = { [weak self] in self?.requestMicrophone() }
        accessibility.onAction = { [weak self] in self?.requestAccessibility() }
        speechRecognition.onAction = { [weak self] in self?.requestSpeechRecognition() }
        let firstSeparator = divider()
        let secondSeparator = divider()
        [
            microphone,
            firstSeparator,
            accessibility,
            secondSeparator,
            speechRecognition,
        ].forEach(addArrangedSubview)
        microphone.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        firstSeparator.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        accessibility.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        secondSeparator.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        speechRecognition.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func startRefreshing() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    private func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else {
            openSystemSettings("Privacy_Microphone")
        }
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSystemSettings("Privacy_Accessibility")
    }

    private func requestSpeechRecognition() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else {
            openSystemSettings("Privacy_SpeechRecognition")
        }
    }

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func microphoneStatusText(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

    private static func speechStatusText(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
}

private final class PermissionRow: NSView {
    var onAction: (() -> Void)?

    private let title: String
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    init(symbolName: String, title: String, explanation: String, buttonTitle: String) {
        self.title = title
        super.init(frame: .zero)

        let icon = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        let explanationLabel = NSTextField(wrappingLabelWithString: explanation)
        explanationLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, explanationLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        actionButton.title = buttonTitle
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(performAction)

        let trailing = NSStackView(views: [statusLabel, actionButton])
        trailing.orientation = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 7

        [icon, labels, trailing].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 92),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -16),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setStatus(text: String, granted: Bool, buttonTitle: String) {
        statusLabel.stringValue = text
        statusLabel.textColor = granted ? .systemGreen : .secondaryLabelColor
        actionButton.title = buttonTitle
        actionButton.setAccessibilityLabel("\(buttonTitle) for \(title)")
        setAccessibilityValue(text)
    }

    @objc private func performAction() { onAction?() }
}
