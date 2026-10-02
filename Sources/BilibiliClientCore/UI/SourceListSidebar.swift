#if os(macOS)
import AppKit
import SwiftUI

/// 原生侧边栏列表（macOS）。
///
/// 内部就是 AppKit 的 source list：`NSTableView` 开 `style = .sourceList`，
/// 选中态交给系统按 source list 的模糊材质绘制——聚焦时是强调色玻璃，
/// 未聚焦时是中性半透明覆盖层。这里固定用未聚焦的那一种（App Store 的观感），
/// 见 `SidebarRowView`。实现方法参考 coolapk for mac 的同名组件。
///
/// 行高、字号、图标尺寸、文本缩进都不自己定：`rowSizeStyle` 用系统默认值，
/// 由 `NSTableCellView` 按标准度量摆放它的 `textField` / `imageView`，
/// 系统怎么显示侧边栏，这里就怎么显示。
///
/// 表格背景必须保持 source list 的背景色：AppKit 只在背景没被改过时才用
/// 模糊材质画选中态，改成 `.clear` 之类会退化成普通实心高亮。
///
/// 之所以不用 SwiftUI 的 `List(selection:)`：它把选中态和焦点绑定，画出来是
/// 强调色实心高亮；source list 的观感（访达 / App Store）官方一律走 AppKit。
/// （与上游的差异：没有数字徽标——本 App 暂无角标场景，需要时再补。）
struct SourceListSidebar<Value: Hashable>: NSViewRepresentable {
    struct Row: Identifiable, Equatable {
        init(id: String, value: Value, title: String, systemImage: String) {
            self.id = id
            self.value = value
            self.title = title
            self.systemImage = systemImage
        }

        let id: String
        let value: Value
        let title: String
        let systemImage: String
    }

    /// 分组标题行的复用标识。
    static var headerIdentifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("sidebar.header") }

    struct Section: Identifiable, Equatable {
        init(id: String, title: String, rows: [Row]) {
            self.id = id
            self.title = title
            self.rows = rows
        }

        let id: String
        /// 空字符串表示这一组不渲染分组标题（对应原生 List 里不带 header 的 Section）。
        let title: String
        let rows: [Row]
    }

    init(sections: [Section], selection: Value?, onSelect: @escaping (Value) -> Void) {
        self.sections = sections
        self.selection = selection
        self.onSelect = onSelect
    }

    var sections: [Section]
    var selection: Value?
    var onSelect: (Value) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.gridStyleMask = []
        // 行高交给系统：rowSizeStyle 用默认值，表格会按 source list 的标准度量设置行高。
        tableView.rowSizeStyle = .default
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsColumnSelection = false
        tableView.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 8, right: 0)
        tableView.autoresizingMask = [.width]
        tableView.frame = scrollView.bounds
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }
        context.coordinator.parent = self
        context.coordinator.apply(to: tableView)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum RowEntry {
            case header(String)
            case item(Row)
        }

        var parent: SourceListSidebar
        weak var tableView: NSTableView?
        private var entries: [RowEntry] = []
        private var signature = ""
        private var isSyncingSelection = false

        init(_ parent: SourceListSidebar) {
            self.parent = parent
        }

        func apply(to tableView: NSTableView) {
            let next = signature(of: parent.sections)
            if next != signature || entries.isEmpty {
                signature = next
                entries = parent.sections.flatMap { section -> [RowEntry] in
                    (section.title.isEmpty ? [] : [RowEntry.header(section.title)])
                        + section.rows.map(RowEntry.item)
                }
                tableView.reloadData()
            }
            syncSelection(tableView)
        }

        private func signature(of sections: [Section]) -> String {
            sections.map { section in
                section.title + "|" + section.rows.map { "\($0.id)~\($0.title)~\($0.systemImage)" }.joined(separator: ";")
            }.joined(separator: "/")
        }

        private func syncSelection(_ tableView: NSTableView) {
            let target = entries.firstIndex { entry in
                if case let .item(row) = entry { return row.value == parent.selection }
                return false
            }
            let desired = target ?? -1
            guard tableView.selectedRow != desired else { return }
            isSyncingSelection = true
            if let target {
                tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                tableView.scrollRowToVisible(target)
            } else {
                tableView.deselectAll(nil)
            }
            isSyncingSelection = false
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        // MARK: Delegate

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .header = entries[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            if case .header = entries[row] { return false }
            return true
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            SidebarRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch entries[row] {
            case let .header(title):
                // 分组标题：给一个只带 stringValue 的 NSTextField，系统会自动套用
                // group row 的字体、颜色与缩进。
                let field = tableView.makeView(withIdentifier: SourceListSidebar.headerIdentifier, owner: nil) as? NSTextField
                    ?? NSTextField(labelWithString: "")
                field.identifier = SourceListSidebar.headerIdentifier
                field.stringValue = title
                return field
            case let .item(entry):
                let cell = tableView.makeView(withIdentifier: SidebarItemCell.identifier, owner: nil) as? SidebarItemCell ?? SidebarItemCell()
                cell.identifier = SidebarItemCell.identifier
                cell.configure(title: entry.title, systemImage: entry.systemImage)
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let tableView = notification.object as? NSTableView,
                  tableView.selectedRow >= 0,
                  tableView.selectedRow < entries.count,
                  case let .item(row) = entries[tableView.selectedRow]
            else { return }
            // 点侧栏等于「离开输入」：把 first responder 从搜索框收回列表。
            // 否则搜索框一直握着焦点，再次点它不会产生焦点变化，界面像没反应。
            if let window = tableView.window, window.firstResponder !== tableView {
                window.makeFirstResponder(tableView)
            }
            parent.onSelect(row.value)
        }
    }
}

// MARK: - Rows

/// 行视图：选中背景仍由系统的 source list 模糊材质绘制，只是不再随焦点切换成强调色。
///
/// `emphasized` 的语义是「相关视图持有 first responder」，系统据此在强调色与中性色之间
/// 二选一。App Store 的侧边栏常年是中性那一种，这里照做：不自己配色，
/// 只是把系统那套中性材质固定下来。
private final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

// MARK: - Cells

/// 侧边栏条目：图标 + 标题。
///
/// `textField` / `imageView` 两个出口交给 `NSTableCellView`，它按当前 `rowSizeStyle`
/// 用系统标准度量摆放并设置字体，所以这里不写任何尺寸常量。
private final class SidebarItemCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("sidebar.item")

    private let sidebarImageView = NSImageView()
    private let sidebarTextField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        // 图标位由系统摆好，符号用系统给的原始尺寸绘制。
        sidebarImageView.imageScaling = .scaleProportionallyDown
        sidebarImageView.contentTintColor = .controlAccentColor

        sidebarTextField.lineBreakMode = .byTruncatingTail

        addSubview(sidebarImageView)
        addSubview(sidebarTextField)

        imageView = sidebarImageView
        textField = sidebarTextField
    }

    func configure(title: String, systemImage: String) {
        sidebarTextField.stringValue = title
        sidebarImageView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)
    }
}
#endif
