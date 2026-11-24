import AppKit
import MdrKit

/// 목차 사이드바입니다. 제목을 단계만큼 들여 보여 주고, 지금 읽는 절을 강조합니다.
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var items: [OutlineItem] = []
    /// 각 제목의 들여쓰기 단계입니다. 제목 단계 숫자가 아니라 실제로 몇 겹 안에 있는지로 정합니다.
    /// (h1 바로 아래에 h6이 와도 한 단계만 들입니다.)
    private var depths: [Int] = []
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
        var stack: [Int] = []
        depths = items.map { item in
            while let last = stack.last, last >= item.level { stack.removeLast() }
            stack.append(item.level)
            return stack.count - 1
        }
        tableView.reloadData()
    }

    /// 그 줄을 누른 것처럼 선택합니다(검증용). 선택이 바뀌면 `onSelect`가 불립니다.
    func selectRow(_ row: Int) {
        guard items.indices.contains(row) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
    }

    func title(atRow row: Int) -> String? {
        items.indices.contains(row) ? items[row].title : nil
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
        updateCurrentRowStyle()
    }

    /// 지금 읽는 절의 줄은 단계와 상관없이 강조색으로 보여 줍니다.
    private func updateCurrentRowStyle() {
        let selected = tableView.selectedRow
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? OutlineCellView)?.isCurrent = row == selected
        }
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
        cell.configure(title: item.title, depth: depths[row])
        cell.isCurrent = row == tableView.selectedRow
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateCurrentRowStyle()
        guard !isSyncingSelection, tableView.selectedRow >= 0 else { return }
        onSelect?(items[tableView.selectedRow])
    }
}

private final class OutlineCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var depth = 0

    var isCurrent = false {
        didSet { applyStyle() }
    }

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
        self.depth = depth
        leading.constant = 4 + CGFloat(min(depth, 4)) * 12
        toolTip = title
        applyStyle()
    }

    /// 줄이 선택되어 배경이 강조색으로 칠해지면 `.emphasized`가 됩니다. 그때 글자를 강조색으로 두면 배경에 묻힙니다.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    private func applyStyle() {
        if backgroundStyle == .emphasized {
            label.font = .systemFont(ofSize: 13, weight: isCurrent ? .semibold : (depth == 0 ? .medium : .regular))
            label.textColor = .alternateSelectedControlTextColor
        } else if isCurrent {
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .controlAccentColor
        } else {
            label.font = .systemFont(ofSize: 13, weight: depth == 0 ? .medium : .regular)
            label.textColor = depth <= 1 ? .labelColor : .secondaryLabelColor
        }
    }
}
