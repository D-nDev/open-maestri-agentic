import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Expand expand button hot area

/// Hide the native disclosure triangle (use the manually rendered chevron icon in the cell instead)
private final class LargeDisclosureOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // Return to zero area, hide the native disclosure triangle
        // Expand/collapse is handled programmatically by handleClickAtLocalPoint + chevron icon in cell indicates status
        return .zero
    }
}

/// File Tree List View (NSOutlineView wrapper)
///
/// Interactive mode (compared to Maestri File Tree):
/// - Click on any item: Highlight selected (all items can be selected)
/// - Double-click the folder: navigate through the onNavigateTo callback (Finder style, not expanded in the view)
/// - Double-click the file: Open it externally with the system default application through the onFileOpened callback
/// - Right click: Pop up context menu (Create/Rename/Delete)
final class FileTreeOutlineNSView: NSView, NSOutlineViewDelegate, NSOutlineViewDataSource {

    // MARK: - Sub-views

    private let scrollView = NSScrollView()
    private let outlineView = LargeDisclosureOutlineView()
    private(set) var store: FileTreeStateStore

    /// Expose scrollView reference for FileTreeOutlineView to forward scroll events
    var scrollViewRef: NSScrollView { scrollView }

    /// Prevent frequent refresh during reload
    private var pendingReloadWorkItem: DispatchWorkItem?

    /// Search filter words (empty string means no filtering)
    var filterQuery: String = "" {
        didSet {
            guard filterQuery != oldValue else { return }
            if filterQuery.isEmpty {
                searchResults = []
                pendingSearchTask?.cancel()
                pendingSearchTask = nil
            } else {
                scheduleSearch(query: filterQuery)
            }
        }
    }

    /// Whether to display hidden files (files/directories starting with .)
    var showHiddenFiles: Bool = false

    /// Search results (only used in search mode, background FileManager enumeration and filling)
    private var searchResults: [FileTreeItem] = []

    /// Search Task in progress (used to cancel the last unfinished search)
    private var pendingSearchTask: Task<Void, Never>?

    /// Current data source: use searchResults for search mode, otherwise use normal tree root node
    private var displayItems: [FileTreeItem] {
        if !filterQuery.isEmpty {
            return searchResults
        }
        var items = store.items
        if !showHiddenFiles {
            items = items.filter { !$0.name.hasPrefix(".") }
        }
        return items
    }

    /// Start anti-shake search: only execute the latest one within 300ms
    private func scheduleSearch(query: String) {
        pendingSearchTask?.cancel()
        pendingSearchTask = Task { [weak self] in
            guard let self else { return }
            // 300ms anti-shake
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let root = self.store.rootPath
            let hidden = self.showHiddenFiles
            let results = await Task.detached(priority: .userInitiated) {
                return FileTreeOutlineNSView.searchFiles(root: root, query: query, showHidden: hidden)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.filterQuery == query else { return }
                self.searchResults = results
                self.outlineView.reloadData()
            }
        }
    }

    /// Use FileManager.enumerator to search recursively in the background, returning a flat match list
    private nonisolated static func searchFiles(root: String, query: String, showHidden: Bool) -> [FileTreeItem] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        var results: [FileTreeItem] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.localizedCaseInsensitiveContains(query) else { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            results.append(FileTreeItem(
                id: url.path,
                name: name,
                isDirectory: isDir.boolValue,
                children: nil
            ))
            if results.count >= 200 { break }  // Prevent result explosion
        }
        return results
    }

    // MARK: - Callbacks

    /// Callback for navigation when double-clicking/clicking a folder (pass in the absolute path to the directory)
    var onNavigateTo: ((String) -> Void)?
    /// Callback that opens when a file is double-clicked
    var onFileOpened: ((String) -> Void)?
    /// Git branch loading completion callback
    var onBranchLoaded: ((String) -> Void)?
    /// Notify Canvas that this node is selected when any click is made
    var onTapped: (() -> Void)?

    // MARK: - Init

    init(store: FileTreeStateStore) {
        self.store = store
        super.init(frame: .zero)
        setupViews()
        reloadBranch()
        Task { @MainActor [weak self] in
            await store.reload()
            self?.outlineView.reloadData()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupViews() {
        // ── OutlineView configuration ──
        let col = NSTableColumn(identifier: .init("name"))
        col.title = ""
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.headerView = nil
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.rowHeight = 32
        outlineView.indentationPerLevel = 20
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .plain
        outlineView.focusRingType = .none
        outlineView.target = self
        outlineView.action = #selector(handleSingleClick)
        outlineView.doubleAction = #selector(handleDoubleClick)

        // Allow dragging (files to Terminal/Canvas)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        // Right-click menu
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        // ── ScrollView configuration ──
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    // MARK: - External refresh

    func reloadData() {
        scheduleReload()
    }

    func updateStore(_ newStore: FileTreeStateStore) {
        store = newStore
        scheduleReload()
        reloadBranch()
    }

    func reloadBranch() {
        let path = store.rootPath
        let callback = onBranchLoaded  // Capture value type snapshots to avoid SendableClosureCaptures warnings
        Task.detached(priority: .utility) {
            let provider = GitStatusProvider(workingDirectory: path)
            guard provider.isGitRepository,
                  let branch = try? provider.currentBranch() else {
                await MainActor.run { callback?("") }
                return
            }
            await MainActor.run { callback?(branch) }
        }
    }

    /// Anti-shake reload: merge multiple calls within 100ms; restore the expanded state after reload in non-search mode
    private func scheduleReload() {
        pendingReloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.outlineView.reloadData()
            // Search mode does not need to restore expanded state (flattened list)
            guard self.filterQuery.isEmpty else { return }
            self.restoreExpandedPaths()
        }
        pendingReloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Re-expand the paths recorded in store.expandedPaths in NSOutlineView
    private func restoreExpandedPaths() {
        guard !store.expandedPaths.isEmpty else { return }
        // Expand in ascending order of path depth, ensuring that parent nodes are expanded before child nodes
        let sorted = store.expandedPaths.sorted { $0.count < $1.count }
        for path in sorted {
            if let item = findItem(path: path, in: store.items) {
                outlineView.expandItem(item)
            }
        }
    }

    /// Find FileTreeItem by path in items tree
    private func findItem(path: String, in items: [FileTreeItem]) -> FileTreeItem? {
        for item in items {
            if item.id == path { return item }
            if let children = item.children, let found = findItem(path: path, in: children) {
                return found
            }
        }
        return nil
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return displayItems.count }
        // Search mode: flat list, no sublevels displayed
        guard filterQuery.isEmpty else { return 0 }
        guard let fi = item as? FileTreeItem, fi.isDirectory else { return 0 }
        if let children = fi.children {
            let visible = showHiddenFiles ? children : children.filter { !$0.name.hasPrefix(".") }
            return visible.count
        }
        // Child not loaded yet: return 1 (placeholder) to allow NSOutlineView to expand,
        // After expansion, outlineViewItemDidExpand will be loaded asynchronously and reloadItem will be replaced with the real number
        return 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil, index < displayItems.count { return displayItems[index] }
        guard let fi = item as? FileTreeItem else { return NSNull() }
        // children loaded
        if let children = fi.children {
            let visible = showHiddenFiles ? children : children.filter { !$0.name.hasPrefix(".") }
            if index < visible.count { return visible[index] }
            return NSNull()
        }
        // Placeholder line: return fi itself as a temporary placeholder (will be replaced after reloadItem)
        // You can also return NSNull here. NSOutlineView will get nil in viewFor and skip it.
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard filterQuery.isEmpty else { return false }
        guard let fi = item as? FileTreeItem else { return false }
        return fi.isDirectory
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fi = item as? FileTreeItem else { return nil }
        return makeCell(for: fi, in: outlineView)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return true   // All items can be selected
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        // Use custom row view to force emphasized state,
        // Ensure that even if outlineView does not get first responder (embedded canvas scene),
        // Selected rows are also always drawn with the system standard blue background (instead of the gray inactive state)
        let rowId = NSUserInterfaceItemIdentifier("FileTreeRow")
        if let existing = outlineView.makeView(withIdentifier: rowId, owner: self) as? EmphasizedRowView {
            return existing
        }
        let rowView = EmphasizedRowView()
        rowView.identifier = rowId
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return filterQuery.isEmpty ? 32 : 46
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let fi = notification.userInfo?["NSObject"] as? FileTreeItem else { return }
        store.expandedPaths.insert(fi.id)
        // Update chevron direction
        updateChevron(for: fi, expanded: true)
        // If the sub-item has not been loaded yet, refresh after loading asynchronously
        guard fi.children == nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.loadChildren(for: fi.id)
            // After loading, completely refresh the outline and re-expand the item
            // Note: reloadItem(_:reloadChildren:) does not requery numberOfChildren in some cases,
            // So use reloadData() instead to ensure the data source is fully synchronized
            self.outlineView.reloadData()
            self.outlineView.expandItem(fi)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let fi = notification.userInfo?["NSObject"] as? FileTreeItem else { return }
        store.expandedPaths.remove(fi.id)
        // Update chevron direction
        updateChevron(for: fi, expanded: false)
    }

    /// Update the chevron icon direction of the row corresponding to the specified item
    private func updateChevron(for item: FileTreeItem, expanded: Bool) {
        let row = outlineView.row(forItem: item)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView else { return }
        if let chevron = cell.viewWithTag(Self.chevronTag) as? NSImageView {
            let symbolName = expanded ? "chevron.down" : "chevron.right"
            chevron.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        // Notify Canvas that this fileTree node is selected (when AppKit hit-test routes directly to NSOutlineView
        // CanvasNodesView.mouseDown will not be called, you need to actively trigger the selection here)
        onTapped?()
        super.mouseDown(with: event)
    }

    // MARK: - Single click/double click processing

    /// Click: Only the highlighted row is selected, no navigation is triggered
    @objc private func handleSingleClick() {
        // NSOutlineView will automatically handle selection highlighting without additional logic
        _ = outlineView.clickedRow
    }

    /// Double-click processing:
    ///  - Folder → Finder-style navigation into subdirectories (via onNavigateTo callback)
    ///  - File → Open with default app via callback
    @objc private func handleDoubleClick() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? FileTreeItem else { return }

        if item.isDirectory {
            onNavigateTo?(item.id)
        } else {
            onFileOpened?(item.id)
        }
    }

    /// Collapse all expanded items
    func collapseAll() {
        outlineView.collapseItem(nil, collapseChildren: true)
        store.expandedPaths.removeAll()
    }

    // MARK: - Programmatic click handling (called by CanvasNodesView)

    /// Perform click operations based on local coordinates (single click to select/expand collapse, double click to navigate/open)
    /// - Parameters:
    ///   - localPoint: Coordinates relative to the upper left corner of outlineView (y downward)
    ///   - clickCount: 1=click, 2=double click
    func handleClickAtLocalPoint(_ localPoint: NSPoint, clickCount: Int) {
        // Calculate row number: localPoint.y / rowHeight (consider scrollView's contentOffset)
        let scrollOffset = scrollView.contentView.bounds.origin
        let adjustedPoint = NSPoint(x: localPoint.x + scrollOffset.x, y: localPoint.y + scrollOffset.y)
        let row = outlineView.row(at: adjustedPoint)

        guard row >= 0, let item = outlineView.item(atRow: row) as? FileTreeItem else {
            // Click on an empty area: Uncheck
            outlineView.deselectAll(nil)
            return
        }

        // Calculate disclosure (chevron) hot zone
        // Cell layout: [indent level*20] + [chevron 16pt] + [gap 2pt] + [icon 20pt] + [gap 6pt] + [text]
        let rowRect = outlineView.rect(ofRow: row)
        let level = outlineView.level(forRow: row)
        // Indent + chevron(16) + gap(2) + icon(20) = indent + 38, covering the right edge of the icon
        let disclosureMaxX = CGFloat(level) * outlineView.indentationPerLevel + 38
        let isInDisclosureZone = item.isDirectory && (adjustedPoint.x - rowRect.minX) < disclosureMaxX

        if clickCount >= 2 {
            if isInDisclosureZone {
                // Double-click in the disclosure area: only expand/collapse, not trigger navigation (to avoid conflict with the expand operation)
                if outlineView.isItemExpanded(item) {
                    outlineView.collapseItem(item)
                } else {
                    outlineView.expandItem(item)
                }
            } else {
                // Double-click in non-disclosure area: directory navigation/file opening
                if item.isDirectory {
                    onNavigateTo?(item.id)
                } else {
                    onFileOpened?(item.id)
                }
            }
            return
        }

        // Click: disclosure area switch expand/collapse
        if isInDisclosureZone {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        }

        // Select row
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        onTapped?()
    }

    // MARK: - Drag and drop support

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let fi = item as? FileTreeItem else { return nil }
        return URL(fileURLWithPath: fi.id) as NSURL
    }

    // MARK: - Cell construction

    private func makeCell(for fi: FileTreeItem, in outlineView: NSOutlineView) -> NSView {
        let cellId = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView

        if let existing = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = buildCellTemplate()
        }

        configureCellContents(cell, with: fi, in: outlineView)
        return cell
    }

    /// tag used for chevron identification
    private static let chevronTag = 9999
    /// tag of subtitle path tag (relative path displayed in search mode)
    private static let subtitleTag = 9998

    private func buildCellTemplate() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("FileCell")

        let chevron = NSImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.imageScaling = .scaleProportionallyDown
        chevron.tag = Self.chevronTag
        cell.addSubview(chevron)

        let imgView = NSImageView()
        imgView.translatesAutoresizingMaskIntoConstraints = false
        imgView.imageScaling = .scaleProportionallyDown
        cell.addSubview(imgView)
        cell.imageView = imgView

        // File name main title
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(textField)
        cell.textField = textField

        // Subtitle: Show relative path below search results
        let subtitle = NSTextField(labelWithString: "")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.tag = Self.subtitleTag
        cell.addSubview(subtitle)

        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),

            imgView.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 2),
            imgView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imgView.widthAnchor.constraint(equalToConstant: 20),
            imgView.heightAnchor.constraint(equalToConstant: 20),

            textField.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),

            subtitle.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            subtitle.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 1),
        ])

        return cell
    }

    private func configureCellContents(_ cell: NSTableCellView, with fi: FileTreeItem, in outlineView: NSOutlineView) {
        let isSearching = !filterQuery.isEmpty

        // Subtitle: Show paths relative to rootPath in search mode, hide otherwise
        if let subtitle = cell.viewWithTag(Self.subtitleTag) as? NSTextField {
            if isSearching {
                let root = store.rootPath
                let relative = fi.id.hasPrefix(root)
                    ? String(fi.id.dropFirst(root.count + 1))
                    : fi.id
                subtitle.stringValue = relative
                subtitle.isHidden = false
            } else {
                subtitle.stringValue = ""
                subtitle.isHidden = true
            }
        }

        cell.textField?.stringValue = fi.name
        cell.imageView?.image = fileIcon(for: fi)

        if let chevron = cell.viewWithTag(Self.chevronTag) as? NSImageView {
            // Flat list in search mode, no expansion indicator displayed
            if !isSearching && fi.isDirectory {
                chevron.isHidden = false
                let symbolName = outlineView.isItemExpanded(fi) ? "chevron.down" : "chevron.right"
                chevron.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                chevron.contentTintColor = .secondaryLabelColor
            } else {
                chevron.isHidden = true
                chevron.image = nil
            }
        }

        switch fi.gitStatus {
        case .modified:   cell.textField?.textColor = .systemOrange
        case .added, .untracked: cell.textField?.textColor = .systemGreen
        case .deleted:    cell.textField?.textColor = .systemRed
        default:          cell.textField?.textColor = .labelColor
        }
    }

    private func fileIcon(for item: FileTreeItem) -> NSImage {
        if item.isDirectory {
            return NSWorkspace.shared.icon(for: UTType.folder)
        }
        return NSWorkspace.shared.icon(forFile: item.id)
    }
}

// MARK: - Right-click menu (NSMenuDelegate)

extension FileTreeOutlineNSView: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let row = outlineView.clickedRow
        guard row >= 0 else {
            // Clicking on an empty area: Only create options are available
            menu.addItem(makeMenuItem(
                title: "filetree.menu.new_file".localized,
                icon: "doc.badge.plus",
                action: #selector(newFile)
            ))
            menu.addItem(makeMenuItem(
                title: "filetree.menu.new_folder".localized,
                icon: "folder.badge.plus",
                action: #selector(newFolder)
            ))
            return
        }

        // Select the clicked row
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let item = outlineView.item(atRow: row) as? FileTreeItem else { return }

        if item.isDirectory {
            menu.addItem(makeMenuItem(
                title: "filetree.menu.open_folder".localized,
                icon: "arrow.forward",
                action: #selector(openInFinder),
                representedObject: item.id
            ))
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(
                title: "filetree.menu.new_file".localized,
                icon: "doc.badge.plus",
                action: #selector(newFile),
                representedObject: item.id
            ))
            menu.addItem(makeMenuItem(
                title: "filetree.menu.new_folder".localized,
                icon: "folder.badge.plus",
                action: #selector(newFolder),
                representedObject: item.id
            ))
        } else {
            menu.addItem(makeMenuItem(
                title: "filetree.menu.open".localized,
                icon: "arrow.up.right",
                action: #selector(openFile),
                representedObject: item.id
            ))
            menu.addItem(makeMenuItem(
                title: "filetree.menu.reveal_in_finder".localized,
                icon: "magnifyingglass",
                action: #selector(openInFinder),
                representedObject: item.id
            ))
        }

        menu.addItem(.separator())
        menu.addItem(makeMenuItem(
            title: "filetree.menu.rename".localized,
            icon: "pencil",
            action: #selector(renameItem),
            representedObject: item.id
        ))
        menu.addItem(.separator())

        let deleteItem = makeMenuItem(
            title: "filetree.menu.delete".localized,
            icon: "trash",
            action: #selector(deleteItem),
            representedObject: item.id
        )
        deleteItem.attributedTitle = NSAttributedString(
            string: "filetree.menu.delete".localized,
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(deleteItem)
    }

    private func makeMenuItem(
        title: String,
        icon: String,
        action: Selector,
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        item.target = self
        item.representedObject = representedObject
        return item
    }

    // MARK: - Menu Actions

    @objc private func openFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        // Folder → Navigate to enter; File → Finder highlight
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func newFile(_ sender: NSMenuItem) {
        let parentPath: String
        if let p = sender.representedObject as? String {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            parentPath = isDir.boolValue ? p : (p as NSString).deletingLastPathComponent
        } else {
            parentPath = store.rootPath
        }
        presentInlineRename(parentPath: parentPath, isFolder: false)
    }

    @objc private func newFolder(_ sender: NSMenuItem) {
        let parentPath: String
        if let p = sender.representedObject as? String {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            parentPath = isDir.boolValue ? p : (p as NSString).deletingLastPathComponent
        } else {
            parentPath = store.rootPath
        }
        presentInlineRename(parentPath: parentPath, isFolder: true)
    }

    @objc private func renameItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        presentRenameAlert(currentName: name, parent: parent, oldPath: path)
    }

    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(format: "filetree.delete.confirm_title".localized, name)
        alert.informativeText = "filetree.delete.confirm_message".localized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "filetree.menu.delete".localized)
        alert.addButton(withTitle: "button.cancel".localized)
        alert.buttons.first?.hasDestructiveAction = true

        if let window = self.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                try? FileManager.default.removeItem(atPath: path)
                self?.refresh()
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                try? FileManager.default.removeItem(atPath: path)
                refresh()
            }
        }
    }

    // MARK: - New/Rename Alert

    private func presentInlineRename(parentPath: String, isFolder: Bool) {
        let alert = NSAlert()
        alert.messageText = isFolder
            ? "filetree.new_folder.title".localized
            : "filetree.new_file.title".localized
        alert.alertStyle = .informational
        alert.addButton(withTitle: "button.create".localized)
        alert.addButton(withTitle: "button.cancel".localized)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = isFolder
            ? "filetree.new_folder.placeholder".localized
            : "filetree.new_file.placeholder".localized
        input.stringValue = isFolder ? "New Folder" : "Untitled.txt"
        alert.accessoryView = input

        if let window = self.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let name = input.stringValue.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let fullPath = (parentPath as NSString).appendingPathComponent(name)
                if isFolder {
                    try? FileManager.default.createDirectory(
                        atPath: fullPath, withIntermediateDirectories: true
                    )
                } else {
                    FileManager.default.createFile(atPath: fullPath, contents: nil)
                }
                self?.refresh()
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                let name = input.stringValue.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let fullPath = (parentPath as NSString).appendingPathComponent(name)
                if isFolder {
                    try? FileManager.default.createDirectory(
                        atPath: fullPath, withIntermediateDirectories: true
                    )
                } else {
                    FileManager.default.createFile(atPath: fullPath, contents: nil)
                }
                refresh()
            }
        }
    }

    private func presentRenameAlert(currentName: String, parent: String, oldPath: String) {
        let alert = NSAlert()
        alert.messageText = "filetree.rename.title".localized
        alert.alertStyle = .informational
        alert.addButton(withTitle: "filetree.menu.rename".localized)
        alert.addButton(withTitle: "button.cancel".localized)

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = currentName
        alert.accessoryView = input

        if let window = self.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                let newName = input.stringValue.trimmingCharacters(in: .whitespaces)
                guard !newName.isEmpty, newName != currentName else { return }
                let newPath = (parent as NSString).appendingPathComponent(newName)
                try? FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                self?.refresh()
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                let newName = input.stringValue.trimmingCharacters(in: .whitespaces)
                guard !newName.isEmpty, newName != currentName else { return }
                let newPath = (parent as NSString).appendingPathComponent(newName)
                try? FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                refresh()
            }
        }
    }

    private func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.store.reload()
            self.outlineView.reloadData()
        }
    }
}

// MARK: - EmphasizedRowView

/// Always return row views with `isEmphasized = true`,
/// Make selected rows highlighted blue (instead of gray) when the NSOutlineView does not have focus.
final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set { /* Ignore system settings and always remain in emphasized state */ }
    }
}
