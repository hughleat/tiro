import AppKit

@MainActor
final class SettingsPageViewController: NSViewController {
    private let pageTitle: String
    private let contentView: NSView

    init(title: String, contentView: NSView) {
        pageTitle = title
        self.contentView = contentView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        let titleLabel = NSTextField(labelWithString: pageTitle)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel)
        root.addSubview(contentView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            contentView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
        view = root
    }
}

@MainActor
final class SettingsTabbedContentView: NSView {
    struct Tab {
        let title: String
        let view: NSView
    }

    private let tabs: [Tab]
    private let segmentedControl: NSSegmentedControl
    private let container = NSView()
    private weak var visibleView: NSView?

    init(tabs: [Tab]) {
        self.tabs = tabs
        segmentedControl = NSSegmentedControl(
            labels: tabs.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        segmentedControl.segmentStyle = .rounded
        segmentedControl.selectedSegment = 0
        segmentedControl.target = self
        segmentedControl.action = #selector(selectionChanged)
        segmentedControl.setAccessibilityLabel("Page view")
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segmentedControl)
        addSubview(container)
        NSLayoutConstraint.activate([
            segmentedControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            segmentedControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            segmentedControl.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 16),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        showTab(at: 0)
    }

    @objc private func selectionChanged() {
        showTab(at: segmentedControl.selectedSegment)
    }

    private func showTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        visibleView?.removeFromSuperview()
        let next = tabs[index].view
        next.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            next.topAnchor.constraint(equalTo: container.topAnchor),
            next.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        visibleView = next
    }
}
