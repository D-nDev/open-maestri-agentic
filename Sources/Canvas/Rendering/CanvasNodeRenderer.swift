import AppKit
import SwiftUI
import SwiftTerm
import OSLog

/// Canvas node rendering engine
/// Rendering all nodes using a single CanvasNodesView (NSHostingView), no per-node NSView management
@MainActor
final class CanvasNodeRenderer {
    let logger = Logger.make(category: "CanvasNodeRenderer")
    weak var canvas: CanvasViewportView?
    /// Current workspace (for use by node callbacks)
    weak var currentWorkspace: WorkspaceManager?
    var notificationObservers: [NSObjectProtocol] = []
    /// List of currently available roles (injected externally before sync)
    var rolePresets: [RolePreset] = []

    /// Node SwiftUI container (single HostingView)
    var nodesHostingView: CanvasNodesView?

    // Wiring layer
    private(set) var overlayView: ConnectionOverlayView?

    /// Reused catenary calculator (avoids allocating new instances of each connection every frame)
    let ropeSimulation = RopeSimulation()

    // MARK: - Wired physics state (managed by CanvasNodeRenderer+Physics.swift)

    /// Connection metadata (used to find status when rendering)
    struct ConnectionMeta {
        let id: UUID
        let nodeIdA: UUID
        let nodeIdB: UUID
    }

    /// List of currently active connection metadata (built in syncConnections)
    var activeConnections: [ConnectionMeta] = []

    /// Connection state cache (avoids O(n) lookups per connection per frame)
    var connectionStatusCache: [UUID: ConnectionStatus] = [:]

    init(canvas: CanvasViewportView) {
        self.canvas = canvas
        setupNodesHostingView(canvas: canvas)
        setupOverlay(canvas: canvas)
        setupDrawingOverlay(canvas: canvas)
        setupNodeDragCallback(canvas: canvas)
        setupActivationObserver()
        setupSelectionObserver()
        setupDropTargetObserver()
        setupNodeStateObservers()
        setupPhysicsCallbacks()
        // Directly refresh the screen coordinates of the connection when the canvas pan/zoom changes (bypassing SwiftUI timing issues)
        canvas.onViewportPanned = { [weak self] in
            self?.rerenderConnections()
            self?.canvas?.syncTemporaryConnectionToOverlay()
        }
    }

    private func setupNodesHostingView(canvas: CanvasViewportView) {
        let rootView = CanvasNodesSwiftUIView(
            nodes: [],
            canvasOrigin: canvas.canvasOrigin,
            zoom: canvas.zoom,
            selectedNodeIds: [],
            lockedNodeIds: [],
            workspace: nil
        )
        let hostingView = CanvasNodesView(rootView: rootView)
        // Disable NSHostingView from propagating safe area insets to SwiftUI,
        // Ensure GeometryReader dimensions are exactly the same as NSHostingView frame (fix hitTest coordinate offset)
        hostingView.safeAreaRegions = []
        hostingView.frame = canvas.bounds
        hostingView.autoresizingMask = [.width, .height]
        // Inject canvas reference for use by mouseDown routing in fileTree NavBar area
        hostingView.canvas = canvas
        canvas.addSubview(hostingView)
        nodesHostingView = hostingView
        canvas.nodesHostingView = hostingView
    }

    private func setupNodeDragCallback(canvas: CanvasViewportView) {
        // Frame-level callback during dragging: Update physics engine endpoint in real time
        canvas.onNodeFramesDuringDrag = { [weak self] draggedIds in
            guard let self, let ws = self.currentWorkspace else { return }
            // Only update the connecting rope endpoints involving the dragged node
            self.updatePhysicsAnchorsForNodes(draggedIds, workspace: ws)
        }

        canvas.onNodeDragEnded = { [weak self] nodeId, canvasFrame in
            guard let self else { return }
            self.currentWorkspace?.updateNodeFrame(id: nodeId, frame: canvasFrame)
            self.saveWorkspace()
        }
        canvas.onBatchNodeDragEnded = { [weak self] finalFrames in
            guard let self else { return }
            for (nodeId, frame) in finalFrames {
                self.currentWorkspace?.updateNodeFrame(id: nodeId, frame: frame)
            }
            self.saveWorkspace()
        }
        // End of Resize: Persisting new frame
        canvas.onNodeResizeEnded = { [weak self] nodeId, canvasFrame in
            guard let self else { return }
            self.currentWorkspace?.updateNodeFrame(id: nodeId, frame: canvasFrame)
            self.saveWorkspace()
        }
        canvas.onDuplicateNode = { [weak self] id in
            self?.handleDuplicate(id: id)
        }
        // Right-click menu callback
        canvas.onContextMenuClose = { [weak self] id in
            self?.removeNode(id: id, from: self?.currentWorkspace)
        }
        canvas.onContextMenuRename = { [weak self] id in
            // Let the UI layer pop up the rename input box through notifications
            NotificationCenter.default.post(
                name: .editTerminalRequested,
                object: nil,
                userInfo: ["nodeId": id]
            )
        }
        canvas.onContextMenuLockToggle = { [weak self] id in
            guard let ws = self?.currentWorkspace,
                  let idx = ws.nodes.firstIndex(where: { $0.id == id }) else { return }
            let newLocked = !ws.nodes[idx].isLocked
            self?.handleLockToggle(id: id, locked: newLocked)
        }
        // Right-click menu: Edit terminal (send notification with TerminalContent data)
        canvas.onContextMenuEditTerminal = { [weak self] id in
            guard let ws = self?.currentWorkspace,
                  let node = ws.nodes.first(where: { $0.id == id }),
                  case .terminal(let tc) = node.content else { return }
            NotificationCenter.default.post(
                name: .editTerminalRequested,
                object: nil,
                userInfo: ["nodeId": id, "terminalContent": tc]
            )
        }
        // Right-click menu: Start connection (set the starting point directly in the NSView layer to avoid SwiftUI round-trip delay)
        canvas.onContextMenuConnect = { [weak canvas] id in
            canvas?.selectedNodeIds = [id]
            canvas?.connectingFromNodeId = id
            NotificationCenter.default.post(
                name: .contextMenuConnect,
                object: nil,
                userInfo: ["nodeId": id]
            )
        }
        // Right-click menu: Assign role (Terminal exclusive)
        canvas.onContextMenuAssignRole = { id in
            NotificationCenter.default.post(
                name: .contextMenuAssignRole,
                object: nil,
                userInfo: ["nodeId": id]
            )
        }
        // Right-click menu: Switch Maestro mode (Terminal exclusive)
        canvas.onContextMenuToggleMaestro = { id in
            NotificationCenter.default.post(
                name: .contextMenuToggleMaestro,
                object: nil,
                userInfo: ["nodeId": id]
            )
        }
        // Right-click menu: Clear buffer (Terminal exclusive)
        canvas.onContextMenuClearBuffer = { [weak self] id in
            self?.handleClearBuffer(terminalId: id)
        }
        // Right-click menu: Reload terminal (Terminal exclusive)
        canvas.onContextMenuReloadTerminal = { [weak self] id in
            self?.handleReloadTerminal(terminalId: id)
        }
        // Right-click menu: Copy terminal content (Terminal exclusive)
        canvas.onContextMenuCopyTerminal = { [weak self] id in
            self?.handleCopyTerminal(terminalId: id)
        }
        // Right-click menu: Switch monitoring activities (Terminal exclusive)
        canvas.onContextMenuToggleMonitor = { [weak self] id in
            self?.handleToggleMonitor(terminalId: id)
        }
        // Node level changes: synchronized to workspace persistence (canvas.currentNodes has been updated by bringNodesToFront)
        canvas.onNodeZIndexChanged = { [weak self] nodeId, newZIndex in
            guard let ws = self?.currentWorkspace,
                  let idx = ws.nodes.firstIndex(where: { $0.id == nodeId }) else { return }
            ws.nodes[idx].zIndex = newZIndex
        }
    }

    func saveWorkspace() {
        guard let ws = currentWorkspace else { return }
        Task {
            do {
                try await ws.save()
            } catch {
                logger.error("Failed to save workspace: \(error.localizedDescription)")
            }
        }
    }

    private func setupDrawingOverlay(canvas: CanvasViewportView) {
        let overlay = DrawingOverlayView(frame: canvas.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.canvasOrigin = canvas.canvasOrigin
        overlay.zoom = canvas.zoom
        canvas.addSubview(overlay)
        canvas.drawingOverlayView = overlay
    }

    private func setupOverlay(canvas: CanvasViewportView) {
        let overlay = ConnectionOverlayView(frame: canvas.bounds)
        overlay.autoresizingMask = [.width, .height]
        // The connection line layer is inserted below the node layer. When nodes overlap, the nodes are always displayed above the connection line.
        if let nodesView = canvas.nodesHostingView {
            canvas.addSubview(overlay, positioned: .below, relativeTo: nodesView)
        } else {
            canvas.addSubview(overlay)
        }
        overlayView = overlay
        // Register overlay reference to canvas (for temporary connection synchronization)
        canvas.connectionOverlayView = overlay

        // Delete callback when right-clicking on a connection
        overlay.onDeleteConnection = { [weak self] connectionId in
            guard let self, let ws = self.currentWorkspace else { return }
            // Find and remove from all connection types
            ws.connections.removeAll { $0.id == connectionId }
            ws.noteConnections.removeAll { $0.id == connectionId }
            ws.portalConnections.removeAll { $0.id == connectionId }
            ws.portalToPortalConnections.removeAll { $0.id == connectionId }
            ws.noteToNoteConnections.removeAll { $0.id == connectionId }
            ConnectionManager.shared.disconnect(id: connectionId)
            overlay.removeConnection(id: connectionId)
            self.saveWorkspace()
            self.logger.info("Connection \(connectionId.uuidString.prefix(8)) deleted via context menu")
        }
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - sync node list

    /// Use a single HostingView to fully replace node rendering
    func sync(nodes: [CanvasNode], workspace: WorkspaceManager) {
        guard let canvas else { return }
        currentWorkspace = workspace

        let lockedIds = Set(nodes.filter { $0.isLocked }.map { $0.id })

        // Update currentNodes first (trigger sorting cache update), then use the sorted array to build the SwiftUI view
        // Rebuild nodeCanvasFrames: Clean up old entries of deleted nodes to avoid old UUID residues interfering with hitTest and drag
        let activeIds = Set(nodes.map { $0.id })
        canvas.nodeCanvasFrames = canvas.nodeCanvasFrames.filter { activeIds.contains($0.key) }
        for node in nodes {
            canvas.nodeCanvasFrames[node.id] = node.frame
        }
        canvas.currentNodes = nodes

        // Viewport clipping: Pass only visible nodes into SwiftUI render layer
        // At the same time, the viewport cache is forced to invalidate: sync() writes directly to rootView, bypassing the cache update path of layout().
        // If not dirty, the drag branch will use the old _cachedViewportNodes for filtering whitelist.
        // Causes nodes to disappear when dragging a new node immediately after sync().
        canvas.invalidateViewportCache()
        let visibleNodes = canvas.viewportCulledNodes()

        nodesHostingView?.rootView = CanvasNodesSwiftUIView(
            nodes: visibleNodes,
            canvasOrigin: canvas.canvasOrigin,
            zoom: canvas.zoom,
            selectedNodeIds: canvas.selectedNodeIds,
            lockedNodeIds: lockedIds,
            workspace: workspace,
            onActivated: { [weak canvas] id in
                guard let canvas else { return }
                if let provider = TerminalManager.shared.providers[id],
                   let tv = provider.terminalView {
                    tv.window?.makeFirstResponder(tv)
                }
                // bringNodesToFront will update zIndex and trigger canvasSelectionChanged notification (rebuild rootView to display the selected box)
                canvas.bringNodesToFront([id])
                canvas.selectedNodeIds = [id]
            },
            onClose: { [weak self] id in
                self?.removeNode(id: id, from: self?.currentWorkspace)
            },
            onRename: { [weak self] id, newName in
                self?.handleRename(id: id, newName: newName)
            },
            onDuplicate: { [weak self] id in
                self?.handleDuplicate(id: id)
            },
            onLockToggle: { [weak self] id, locked in
                self?.handleLockToggle(id: id, locked: locked)
            }
        )

        // Ensure that the connection line layer is always below the node layer (nodes obscure the connection line when nodes overlap)
        if let overlay = overlayView, let nodesView = nodesHostingView {
            canvas.addSubview(overlay, positioned: .below, relativeTo: nodesView)
        } else if let overlay = overlayView {
            canvas.addSubview(overlay)
        }

        // drawingOverlayView above node layer (for drawing selected border)
        if let drawingOverlay = canvas.drawingOverlayView {
            canvas.addSubview(drawingOverlay)
        }

        // Ensure snapGuideView is always at the top level
        if let snapView = canvas.snapGuideView {
            canvas.addSubview(snapView)
        }
    }

    // MARK: - Node deleted

    func removeNode(id: UUID, from workspace: WorkspaceManager?) {
        guard workspace?.isExternallyManagedNode(id: id) != true else { return }
        // Note The disk .md file is also deleted when a node is deleted (official behavior: docs/05-notes.md)
        if let (nc, wsId) = noteInfo(nodeId: id, workspace: workspace) {
            switch nc.storageMode {
            case .managed:
                if let fn = nc.fileName, let ws = workspace {
                    let path = PersistenceManager.shared.notesDirURL(workspaceId: ws.id)
                        .appendingPathComponent(fn).path
                    do {
                        try FileManager.default.removeItem(atPath: path)
                    } catch {
                        logger.error("Failed to delete note file at \(path): \(error.localizedDescription)")
                    }
                }
            case .custom(let customPath):
                // custom paths are managed by users and are not automatically deleted (consistent with official behavior)
                logger.debug("Custom note at \(customPath) not deleted (user-managed)")
            }
            _ = wsId
        }

        NoteRegistry.shared.unregisterByNodeId(id)
        ConnectionManager.shared.disconnectAll(involvedNode: id)
        workspace?.removeNode(id: id)
    }

    private func noteInfo(nodeId: UUID, workspace: WorkspaceManager?) -> (StickyNoteContent, UUID)? {
        guard let ws = workspace,
              let node = ws.nodes.first(where: { $0.id == nodeId }),
              case .stickyNote(let nc) = node.content else { return nil }
        return (nc, ws.id)
    }

    // MARK: - Node operation callback

    private func handleRename(id: UUID, newName: String) {
        guard let ws = currentWorkspace,
              let idx = ws.nodes.firstIndex(where: { $0.id == id }) else { return }
        let newContent: NodeContent?
        switch ws.nodes[idx].content {
        case .terminal(var tc):
            tc.name = newName
            newContent = .terminal(tc)
        case .stickyNote(var nc):
            nc.hasCustomName = true
            nc.fileName = newName.hasSuffix(".md") ? newName : "\(newName).md"
            newContent = .stickyNote(nc)
        case .portal(var pc):
            pc.name = newName
            newContent = .portal(pc)
        case .fileTree(var fc):
            fc.name = newName
            newContent = .fileTree(fc)
        default:
            newContent = nil
        }
        if let content = newContent {
            ws.nodes[idx].content = content
            // canvasNodeContentChanged observer unified processing: updateNodeContentInPlace + displayName + rootView refresh
            NotificationCenter.default.post(
                name: .canvasNodeContentChanged,
                object: nil,
                userInfo: ["nodeId": id, "content": content]
            )
        }
        saveWorkspace()
    }

    private func handleDuplicate(id: UUID) {
        guard let ws = currentWorkspace,
              let original = ws.nodes.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.frame = copy.frame.offsetBy(dx: 30, dy: 30)
        copy.zIndex = (ws.nodes.map { $0.zIndex }.max() ?? 0) + 1
        // Generate new IDs for Terminal content
        if case .terminal(var tc) = copy.content {
            tc.id = UUID()
            copy.content = .terminal(tc)
        }
        ws.addNode(copy)
        saveWorkspace()
    }

    private func handleLockToggle(id: UUID, locked: Bool) {
        guard let ws = currentWorkspace,
              let idx = ws.nodes.firstIndex(where: { $0.id == id }) else { return }
        ws.nodes[idx].isLocked = locked
        canvas?.updateNodeLockedInPlace(id: id, isLocked: locked)
        saveWorkspace()
    }

}
