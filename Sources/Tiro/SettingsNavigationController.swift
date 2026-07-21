import AppKit

enum SettingsSection: String, CaseIterable {
    case general
    case models
    case permissions
    case privacy
    case vocabulary
    case history
    case about

    init?(deepLink url: URL) {
        guard url.scheme == "tiro", url.host == "settings" else { return nil }
        let components = url.path.split(separator: "/")
        guard components.count <= 1 else { return nil }
        let name = components.first.map(String.init) ?? Self.general.rawValue
        self.init(rawValue: name)
    }
}

@MainActor
final class SettingsNavigationController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        let section: SettingsSection
        let title: String
        let symbolName: String
        let viewController: NSViewController
    }

    private let items: [Item]
    private let tableView = NSTableView()
    private let detailContainer = NSViewController()
    private var selectedViewController: NSViewController?

    init(items: [Item]) {
        self.items = items
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    static func configureSidebarIcon(_ imageView: NSImageView, symbolName: String) {
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.setAccessibilityElement(false)
        imageView.contentTintColor = .secondaryLabelColor
    }

    func show(_ section: SettingsSection) {
        guard let index = items.firstIndex(where: { $0.section == section }) else { return }
        loadViewIfNeeded()
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        showItem(at: index)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebar = NSViewController()
        sidebar.view = makeSidebar()
        detailContainer.view = NSView()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 220
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)
        addSplitViewItem(NSSplitViewItem(viewController: detailContainer))

        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showItem(at: 0)
        }
    }

    private func makeSidebar() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.style = .sourceList
        tableView.allowsEmptySelection = false
        tableView.setAccessibilityLabel("Settings sections")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8)
        ])
        return background
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SettingsSidebarRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? NSTableCellView()
        cell.identifier = identifier

        let imageView = cell.imageView ?? NSImageView()
        let textField = cell.textField ?? NSTextField(labelWithString: "")
        if cell.imageView == nil {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.textField = textField
            cell.addSubview(imageView)
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let item = items[row]
        Self.configureSidebarIcon(imageView, symbolName: item.symbolName)
        textField.stringValue = item.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showItem(at: tableView.selectedRow)
    }

    private func showItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        let next = items[index].viewController
        guard next !== selectedViewController else { return }

        if let selectedViewController {
            selectedViewController.view.removeFromSuperview()
            selectedViewController.removeFromParent()
        }
        detailContainer.addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.view.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            next.view.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: detailContainer.view.bottomAnchor)
        ])
        selectedViewController = next
        view.window?.title = "Tiro Settings - \(items[index].title)"
    }
}
