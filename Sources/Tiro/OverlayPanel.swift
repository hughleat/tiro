import AppKit

enum OverlayState {
    case recording
    case transcribing
    case success
    case error

    var label: String {
        switch self {
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .success: return "Copied"
        case .error: return "Transcription failed"
        }
    }

    var color: NSColor {
        switch self {
        case .recording, .error: return NSColor.systemRed
        case .transcribing: return NSColor.systemOrange
        case .success: return NSColor.systemGreen
        }
    }
}

final class OverlayPanel: NSPanel {
    private let statusView = OverlayStatusView(frame: NSRect(x: 0, y: 0, width: 220, height: 48))
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
        pendingDismissal?.cancel()
        pendingDismissal = nil
        statusView.state = state
        positionOnActiveScreen()
        orderFrontRegardless()
    }

    func dismiss() {
        pendingDismissal?.cancel()
        pendingDismissal = nil
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()

        state.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 18, y: 16, width: 16, height: 16)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        state.label.draw(in: NSRect(x: 48, y: 14, width: 158, height: 22), withAttributes: attributes)
    }
}
