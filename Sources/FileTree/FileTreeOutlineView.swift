import AppKit

/// Global registry: nodeId → FileTreeOutlineView (for canvas routing scroll events)
final class FileTreeViewRegistry {
    static let shared = FileTreeViewRegistry()
    private var views: [UUID: FileTreeOutlineView] = [:]
    private let lock = NSLock()
    private init() {}

    func register(nodeId: UUID, view: FileTreeOutlineView) {
        lock.lock(); defer { lock.unlock() }
        views[nodeId] = view
    }

    func unregister(nodeId: UUID) {
        lock.lock(); defer { lock.unlock() }
        views.removeValue(forKey: nodeId)
    }

    func view(for nodeId: UUID) -> FileTreeOutlineView? {
        lock.lock(); defer { lock.unlock() }
        return views[nodeId]
    }
}

/// Global registry: nodeId → FileTreeIconGridView (used by canvas routing mouse events)
final class FileTreeGridViewRegistry {
    static let shared = FileTreeGridViewRegistry()
    private var views: [UUID: FileTreeIconGridView] = [:]
    private let lock = NSLock()
    private init() {}

    func register(nodeId: UUID, view: FileTreeIconGridView) {
        lock.lock(); defer { lock.unlock() }
        views[nodeId] = view
    }

    func unregister(nodeId: UUID) {
        lock.lock(); defer { lock.unlock() }
        views.removeValue(forKey: nodeId)
    }

    func view(for nodeId: UUID) -> FileTreeIconGridView? {
        lock.lock(); defer { lock.unlock() }
        return views[nodeId]
    }
}

/// Lightweight Adapter: Wrap FileTreeOutlineNSView as NSView (for CanvasNodeRenderer to embed node contentView)
final class FileTreeOutlineView: NSView {
    private var outlineNSView: FileTreeOutlineNSView?
    private(set) var store: FileTreeStateStore

    /// Internal NSScrollView (for use by external routed scroll events)
    var innerScrollView: NSScrollView? { outlineNSView?.scrollViewRef }

    /// The SwiftUI layer knows that the user has double-clicked to enter a directory through this callback, and updates navState
    var onNavigateTo: ((String) -> Void)?
    /// Callback after Git branch loading is completed
    var onBranchLoaded: ((String) -> Void)?
    /// Notify Canvas that this node is selected when any click is made
    var onTapped: (() -> Void)? {
        get { outlineNSView?.onTapped }
        set { outlineNSView?.onTapped = newValue }
    }
    /// Back navigation callback (called by CanvasNodesView when the back button is hit in the navBar area)
    var onGoBack: (() -> Void)?
    /// Forward navigation callback
    var onGoForward: (() -> Void)?
    /// Additional SwiftUI area height at the bottom of the node (such as when git panel is expanded) for fileTreeHitKind to recognize
    var extraBottomSwiftUIHeight: CGFloat = 0

    /// Whether to display hidden files (starting with .)
    var showHiddenFiles: Bool {
        get { outlineNSView?.showHiddenFiles ?? false }
        set {
            outlineNSView?.showHiddenFiles = newValue
            outlineNSView?.reloadData()
        }
    }

    /// Current root path (for comparison by FileTreeRepresentable.updateNSView)
    var currentRootPath: String { store.rootPath }

    init(rootPath: String) {
        self.store = FileTreeStateStore(rootPath: rootPath)
        super.init(frame: .zero)

        let outline = FileTreeOutlineNSView(store: store)
        outline.frame = bounds
        outline.autoresizingMask = [.width, .height]

        // Double-click directory → notify navState navigation
        outline.onNavigateTo = { [weak self] path in
            self?.onNavigateTo?(path)
        }
        // Double-click the file → the default application opens
        outline.onFileOpened = { path in
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        // Branch information loading completed
        outline.onBranchLoaded = { [weak self] branch in
            self?.onBranchLoaded?(branch)
        }

        addSubview(outline)
        outlineNSView = outline
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        outlineNSView?.frame = bounds
    }

    /// Change root directory (switch to new path and refresh list)
    func changeRoot(to newPath: String) {
        store = FileTreeStateStore(rootPath: newPath)
        outlineNSView?.updateStore(store)
        Task { @MainActor [weak self] in
            await self?.store.reload()
            self?.outlineNSView?.reloadData()
            // Refresh branch information
            self?.outlineNSView?.reloadBranch()
        }
    }

    /// Refresh file list
    func refresh() {
        Task { @MainActor [weak self] in
            await self?.store.reload()
            self?.outlineNSView?.reloadData()
        }
    }

    /// Apply search filters
    func applyFilter(_ query: String) {
        guard outlineNSView?.filterQuery != query else { return }
        outlineNSView?.filterQuery = query
        // Restore tree view when clearing search (didSet has cleared searchResults, here reloadData triggers restoreExpandedPaths)
        if query.isEmpty {
            outlineNSView?.reloadData()
        }
        // Search mode: driven asynchronously by didSet → scheduleSearch, no need to manually reloadData
    }

    /// Collapse all expanded folders
    func collapseAll() {
        outlineNSView?.collapseAll()
    }

    /// Process click events programmatically (without relying on NSEvent forwarding)
    /// - Parameters:
    ///   - localPoint: coordinates relative to the upper left corner of FileTreeOutlineView
    ///   - clickCount: 1=click, 2=double click
    func handleClickAtLocalPoint(_ localPoint: NSPoint, clickCount: Int) {
        outlineNSView?.handleClickAtLocalPoint(localPoint, clickCount: clickCount)
    }
}
