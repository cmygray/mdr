import AppKit
import MdrKit

/// 목차 사이드바입니다. 제목을 단계만큼 들여 보여 주고, 지금 읽는 절을 강조합니다.
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [OutlineItem] = []
    private var minLevel = 1
    private var isSyncingSelection = false

    var onSelect: ((OutlineItem) -> Void)?

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("목차")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        view = scrollView
    }

    func update(_ items: [OutlineItem]) {
        self.items = items
        minLevel = items.map(\.level).min() ?? 1
        tableView.reloadData()
    }

    /// 본문의 맨 위 위치가 속한 절을 선택 상태로 만듭니다.
    func highlight(characterIndex: Int) {
        var low = 0
        var high = items.count
        while low < high {
            let middle = (low + high) / 2
            if items[middle].location <= characterIndex {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let row = low - 1
        guard row != tableView.selectedRow else { return }
        isSyncingSelection = true
        if row >= 0 {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingSelection = false
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: OutlineCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? OutlineCellView {
            cell = reused
        } else {
            cell = OutlineCellView()
            cell.identifier = identifier
        }
        let item = items[row]
        cell.configure(title: item.title, depth: item.level - minLevel)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, tableView.selectedRow >= 0 else { return }
        onSelect?(items[tableView.selectedRow])
    }
}

private final class OutlineCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(title: String, depth: Int) {
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: depth == 0 ? .medium : .regular)
        label.textColor = depth <= 1 ? .labelColor : .secondaryLabelColor
        leading.constant = 4 + CGFloat(min(depth, 4)) * 12
        toolTip = title
    }
}
