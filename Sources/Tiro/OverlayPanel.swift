import AppKit

enum OverlayState: Equatable {
    case recording
    case startingUp
    case transcribing
    case pasted
    case pasteSent
    case copied
    case noSpeech
    case modelBusy
    case pasteFailed
    case error

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .startingUp: return "Tiro is starting"
        case .transcribing: return "Transcribing"
        case .pasted: return "Pasted"
        case .pasteSent: return "Paste sent"
        case .copied: return "Copied"
        case .noSpeech: return "No speech detected"
        case .modelBusy: return "Models are being updated"
        case .pasteFailed: return "Copied, paste failed"
        case .error: return "Transcription failed"
        }
    }

    var color: NSColor {
        switch self {
        case .recording, .error: return NSColor.systemRed
        case .startingUp, .transcribing, .pasteSent, .noSpeech, .modelBusy, .pasteFailed:
            return NSColor.systemOrange
        case .pasted, .copied: return NSColor.systemGreen
        }
    }

    var announcement: String {
        switch self {
        case .recording: return "Tiro is recording."
        case .startingUp: return "Tiro is starting. Try dictating again shortly."
        case .transcribing: return "Tiro is transcribing."
        case .pasted: return "Dictation pasted."
        case .pasteSent: return "Paste sent."
        case .copied: return "Dictation copied to the clipboard."
        case .noSpeech: return "No speech detected."
        case .modelBusy: return "Wait for the current model operation to finish."
        case .pasteFailed: return "Automatic paste failed. Dictation copied to the clipboard."
        case .error: return "Dictation failed."
        }
    }
}

final class OverlayPanel: NSPanel {
    private let statusView = OverlayStatusView(frame: NSRect(x: 0, y: 0, width: 340, height: 52))
    private var pendingDismissal: DispatchWorkItem?

    init() {
        super.init(
            contentRect: statusView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = statusView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
    }

    func show(_ state: OverlayState) {
        let shouldAnnounce = !isVisible || statusView.state != state
        pendingDismissal?.cancel()
        pendingDismissal = nil
        statusView.state = state
        statusView.stopRecordingFeedback()
        positionOnActiveScreen()
        orderFrontRegardless()
        if shouldAnnounce {
            statusView.announce(state)
        }
    }

    func showRecording(levelProvider: @escaping () -> Float) {
        show(.recording)
        statusView.startRecordingFeedback(levelProvider: levelProvider)
    }

    func dismiss() {
        pendingDismissal?.cancel()
        pendingDismissal = nil
        statusView.stopRecordingFeedback()
        orderOut(nil)
    }

    func dismiss(after delay: TimeInterval) {
        pendingDismissal?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.dismiss() }
        pendingDismissal = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func positionOnActiveScreen() {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.maxY - 68))
    }
}

final class OverlayStatusView: NSView {
    var state: OverlayState = .recording { didSet { needsDisplay = true } }
    private let elapsedAccessibilityElement = NSAccessibilityElement()
    private let levelAccessibilityElement = NSAccessibilityElement()
    private var feedbackTimer: Timer?
    private var levelProvider: (() -> Float)?
    private var recordingStartedAt: TimeInterval = 0
    private var displayedLevel: Float = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        elapsedAccessibilityElement.setAccessibilityRole(.staticText)
        elapsedAccessibilityElement.setAccessibilityLabel("Recording duration")
        elapsedAccessibilityElement.setAccessibilityParent(self)
        levelAccessibilityElement.setAccessibilityRole(.progressIndicator)
        levelAccessibilityElement.setAccessibilityLabel("Microphone level")
        levelAccessibilityElement.setAccessibilityMinValue(0)
        levelAccessibilityElement.setAccessibilityMaxValue(100)
        levelAccessibilityElement.setAccessibilityParent(self)
    }

    required init?(coder: NSCoder) { nil }

    func startRecordingFeedback(levelProvider: @escaping () -> Float) {
        stopRecordingFeedback()
        self.levelProvider = levelProvider
        recordingStartedAt = ProcessInfo.processInfo.systemUptime
        displayedLevel = 0
        setAccessibilityLabel("Tiro recording status")
        setAccessibilityChildren([elapsedAccessibilityElement, levelAccessibilityElement])

        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            self?.refreshRecordingFeedback()
        }
        feedbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshRecordingFeedback()
    }

    func stopRecordingFeedback() {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        levelProvider = nil
        displayedLevel = 0
        setAccessibilityLabel("Tiro status: \(state.label)")
        setAccessibilityChildren([])
    }

    func announce(_ state: OverlayState) {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: state.announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func refreshRecordingFeedback() {
        let target = max(0, min(1, levelProvider?() ?? 0))
        let smoothing: Float = target > displayedLevel ? 0.45 : 0.16
        displayedLevel += (target - displayedLevel) * smoothing
        let elapsed = elapsedSeconds
        elapsedAccessibilityElement.setAccessibilityValue(Self.elapsedText(elapsed))
        levelAccessibilityElement.setAccessibilityValue(Int(displayedLevel * 100))
        needsDisplay = true
    }

    private var elapsedSeconds: Int {
        min(99 * 60 + 59, max(0, Int(ProcessInfo.processInfo.systemUptime - recordingStartedAt)))
    }

    private static func elapsedText(_ elapsed: Int) -> String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()

        state.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: 18, width: 16, height: 16)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        state.label.draw(in: NSRect(x: 48, y: 15, width: 150, height: 22), withAttributes: attributes)

        guard state == .recording, feedbackTimer != nil else { return }

        let meterRect = NSRect(x: 206, y: 22, width: 66, height: 8)
        NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: meterRect, xRadius: 4, yRadius: 4).fill()
        let fillRect = NSRect(x: meterRect.minX, y: meterRect.minY,
                              width: meterRect.width * CGFloat(displayedLevel), height: meterRect.height)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()

        let timerText = Self.elapsedText(elapsedSeconds)
        let timerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.82)
        ]
        timerText.draw(in: NSRect(x: 282, y: 17, width: 46, height: 18), withAttributes: timerAttributes)
    }
}
