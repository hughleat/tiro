import AppKit

@MainActor
final class SupportPromptWindowController: NSWindowController, NSWindowDelegate {
    static let titleText = "Support Tiro"
    static let messageText = """
    Sorry for the interruption. Tiro is free and open source, and sponsorship helps fund an Apple Developer membership and ongoing development.

    We'll only ask once every six months. If you already support Tiro, tell us and we won't ask again.
    """

    var onSupport: (() -> Void)?
    var onAlreadySupporting: (() -> Void)?

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = Self.titleText
        window.center()
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = true
        window.level = .floating
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        window?.center()
        window?.orderFrontRegardless()
    }

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: Self.titleText)
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let message = NSTextField(wrappingLabelWithString: Self.messageText)
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 0

        let supportButton = NSButton(
            title: "Support Tiro",
            target: self,
            action: #selector(supportTiro)
        )
        supportButton.bezelStyle = .rounded
        supportButton.keyEquivalent = "\r"

        let alreadySupportingButton = NSButton(
            title: "I already support",
            target: self,
            action: #selector(alreadySupporting)
        )
        alreadySupportingButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [alreadySupportingButton, supportButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [title, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        buttons.alignment = .centerY
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        return container
    }

    @objc private func supportTiro() {
        close()
        onSupport?()
    }

    @objc private func alreadySupporting() {
        close()
        onAlreadySupporting?()
    }
}
