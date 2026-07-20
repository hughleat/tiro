import AppKit

@MainActor
final class CommandLineToolSettingsView: NSStackView {
    private let installer = CommandLineToolInstaller()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install...", target: nil, action: nil)
    private let uninstallButton = NSButton(title: "Uninstall", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        spacing = 8

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        installButton.target = self
        installButton.action = #selector(install)
        uninstallButton.target = self
        uninstallButton.action = #selector(uninstall)

        let actions = NSStackView(views: [installButton, uninstallButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        addArrangedSubview(statusLabel)
        addArrangedSubview(actions)
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let state = installer.state
        statusLabel.stringValue = state.detail
        switch state {
        case .available:
            installButton.title = "Install..."
            installButton.isEnabled = true
            uninstallButton.isHidden = true
        case .installed:
            installButton.title = "Installed"
            installButton.isEnabled = false
            uninstallButton.isHidden = false
        case .needsRepair:
            installButton.title = "Repair..."
            installButton.isEnabled = true
            uninstallButton.isHidden = false
        case .conflict:
            installButton.title = "Path in Use"
            installButton.isEnabled = false
            uninstallButton.isHidden = true
        case .unavailable:
            installButton.title = "Unavailable"
            installButton.isEnabled = false
            uninstallButton.isHidden = true
        }
    }

    @objc private func install() {
        do {
            try installer.install()
            refresh()
        } catch is CancellationError {
            return
        } catch {
            window?.presentError(error)
        }
    }

    @objc private func uninstall() {
        do {
            try installer.uninstall()
            refresh()
        } catch is CancellationError {
            return
        } catch {
            window?.presentError(error)
        }
    }
}
