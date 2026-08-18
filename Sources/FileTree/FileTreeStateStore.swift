import Foundation
import OSLog

/// File tree node (class guarantees NSOutlineView available object identity === tracking item)
final class FileTreeItem: Identifiable, Hashable {
    let id: String   // Absolute path
    var name: String
    var isDirectory: Bool
    var isExpanded: Bool = false
    var children: [FileTreeItem]?
    var gitStatus: GitFileStatus = .unmodified

    init(id: String, name: String, isDirectory: Bool, isExpanded: Bool = false,
         children: [FileTreeItem]? = nil, gitStatus: GitFileStatus = .unmodified) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.children = children
        self.gitStatus = gitStatus
    }

    static func == (lhs: FileTreeItem, rhs: FileTreeItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Git file status
enum GitFileStatus {
    case unmodified, modified, added, deleted, renamed, untracked
}

/// File tree state storage (independent instance per FileTree node)
@Observable
final class FileTreeStateStore {
    private let logger = Logger.make(category: "FileTreeStateStore")

    var rootPath: String
    var viewMode: FileTreeViewMode = .list
    var items: [FileTreeItem] = []
    var expandedPaths: Set<String> = []
    var gitStatus: [String: GitFileStatus] = [:]

    private var watcher: DirectoryWatcher?
    /// reload work item for anti-shake
    private var pendingReloadWork: DispatchWorkItem?
    /// Last reload timestamp to avoid too frequent
    private var lastReloadTime: CFAbsoluteTime = 0
    /// git status result cache (TTL 60s, avoid executing git status every time reload)
    private var _cachedGitStatus: [String: GitFileStatus] = [:]
    private var _lastGitStatusTime: CFAbsoluteTime = 0
    private static let _gitStatusCacheTTL: CFAbsoluteTime = 60.0

    init(rootPath: String) {
        self.rootPath = rootPath
        startWatching()
    }

    deinit { watcher?.stop() }

    private func startWatching() {
        let w = DirectoryWatcher(path: rootPath)
        w.onChange = { [weak self] in
            self?.scheduleReload()
        }
        w.start()
        watcher = w
    }

    /// Anti-shake reload: merge multiple file system events within 500ms
    private func scheduleReload() {
        pendingReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                await self?.reload()
            }
        }
        pendingReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Load file tree

    func reload() async {
        // Current limiting: skip if it is less than 300ms from the last reload
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReloadTime > 0.3 else { return }
        lastReloadTime = now

        let root = rootPath
        guard FileManager.default.fileExists(atPath: root) else {
            await MainActor.run {
                items = [FileTreeItem(
                    id: root,
                    name: String(format: "filetree.error.directory_not_found".localized, URL(fileURLWithPath: root).lastPathComponent),
                    isDirectory: false,
                    children: nil
                )]
            }
            return
        }

        // Parallel loading of file trees (only 1 level loaded, subdirectories expanded on demand) and git status
        // git status has a 60s TTL cache to avoid re-running git status every time you expand a folder.
        let gitStatusNeedsRefresh = now - _lastGitStatusTime > Self._gitStatusCacheTTL
        let cachedStatus = _cachedGitStatus
        async let filesTask = Task.detached(priority: .userInitiated) {
            return Self.loadDirectory(path: root, depth: 0, maxDepth: 1)
        }.value
        async let gitTask: [String: GitFileStatus] = gitStatusNeedsRefresh
            ? Task.detached(priority: .utility) { Self.loadGitStatus(workingDirectory: root) }.value
            : cachedStatus

        let (loaded, statusMap) = await (filesTask, gitTask)
        // Only update cache timestamp when git status is queried again
        if gitStatusNeedsRefresh {
            _lastGitStatusTime = CFAbsoluteTimeGetCurrent()
            _cachedGitStatus = statusMap
        }
        // Mark git status to file node
        let annotated = Self.applyGitStatus(to: loaded, statusMap: statusMap, root: root)
        await MainActor.run {
            items = annotated
            gitStatus = statusMap
        }
    }

    private static func loadGitStatus(workingDirectory: String) -> [String: GitFileStatus] {
        let provider = GitStatusProvider(workingDirectory: workingDirectory)
        guard provider.isGitRepository else { return [:] }
        let statuses = (try? provider.status()) ?? []
        var map: [String: GitFileStatus] = [:]
        for (path, status) in statuses {
            let fullPath = (workingDirectory as NSString).appendingPathComponent(path)
            map[fullPath] = status
        }
        return map
    }

    private static func applyGitStatus(
        to items: [FileTreeItem],
        statusMap: [String: GitFileStatus],
        root: String
    ) -> [FileTreeItem] {
        for item in items {
            if let status = statusMap[item.id] {
                item.gitStatus = status
            }
            if let children = item.children {
                _ = applyGitStatus(to: children, statusMap: statusMap, root: root)
            }
        }
        return items
    }

    private static func loadDirectory(path: String, depth: Int, maxDepth: Int) -> [FileTreeItem] {
        guard depth < maxDepth else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path)
            .filter({ !$0.hasPrefix(".") })
            .sorted() else { return [] }

        let items = entries.compactMap { name -> FileTreeItem? in
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            return FileTreeItem(
                id: fullPath,
                name: name,
                isDirectory: isDir.boolValue,
                children: nil   // nil triggers NSOutlineView placeholder expansion logic; loads asynchronously during expansion
            )
        }
        // Sort: folders first, files last (consistent with Maestri / Finder)
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }


    // MARK: - Expand/Collapse

    func toggle(path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
            Task { await loadChildren(for: path) }
        }
    }

    /// Load the subdirectory of the specified path and update it to the items tree
    func loadChildren(for path: String) async {
        let children = await Task.detached(priority: .userInitiated) {
            return Self.loadDirectory(path: path, depth: 0, maxDepth: 1)
        }.value
        // Apply git status to loaded child nodes
        let annotated = Self.applyGitStatus(to: children, statusMap: gitStatus, root: rootPath)
        await MainActor.run {
            updateChildren(annotated, for: path, in: items)
        }
    }

    private func updateChildren(_ children: [FileTreeItem], for path: String, in items: [FileTreeItem]) {
        for item in items {
            if item.id == path {
                item.children = children
                return
            }
            if let existingChildren = item.children {
                updateChildren(children, for: path, in: existingChildren)
            }
        }
    }
}

enum FileTreeViewMode {
    case list, grid
}
