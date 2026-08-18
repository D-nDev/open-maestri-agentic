import Foundation
import Observation
import OSLog

/// State management for a single workspace (Story 1.4 + 1.5)
/// - Runtime status of nodes/connections
/// - workspace.json read and write (atomic writes via PersistenceManager)
@Observable
final class WorkspaceManager: Identifiable {
    let id: UUID
    var name: String
    var workingDirectory: String

    // Runtime status (synchronized with WorkspacePayload)
    var nodes: [CanvasNode] = []
    var connections: [TerminalConnection] = []
    var noteConnections: [NoteConnection] = []
    var portalConnections: [PortalConnection] = []
    var portalToPortalConnections: [PortalToPortalConnection] = []
    var noteToNoteConnections: [NoteToNoteConnection] = []
    var crossFloorConnections: [CrossFloorConnection] = []
    var floors: [FloorEntry] = []
    var drawings: [Drawing] = []
    var canvasOrigin: CGPoint = Constants.canvasInitialOrigin
    var canvasZoom: CGFloat = 1.0

    /// The number of unread "task completion" notifications in this workspace (accumulated when the terminal switches from active→idle, cleared when the user switches back)
    var unreadActivityCount: Int = 0

    /// Dirty mark: true when there are unpersisted modifications (only the dirty workspace is saved during autosave)
    var isDirty: Bool = false

    /// Number of Terminal nodes (used for sidebar badges to avoid doing O(n) filter in View body)
    var terminalCount: Int {
        nodes.count(where: { if case .terminal = $0.content { true } else { false } })
    }

    private let logger = Logger.make(category: "WorkspaceManager")
    private let pm = PersistenceManager.shared

    /// Portal URL silently updates cache (does not trigger @Observable → does not trigger canvas re-rendering)
    /// key: portalId, value: latest landing URL; the payload will be patched during save()
    private var _pendingPortalURLs: [UUID: String] = [:]

    init(entry: WorkspaceEntry) {
        self.id = entry.id
        self.name = entry.name
        self.workingDirectory = entry.workingDirectory
    }

    init(id: UUID = UUID(), name: String, workingDirectory: String) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
    }

    // MARK: - Loading (Story 1.3 AC: Restore layout after reboot < 0.5s, NFR2)

    func load() throws {
        let doc = try pm.loadWorkspace(id: id)
        let payload = doc.payload
        nodes = payload.nodes
        connections = payload.connections
        noteConnections = payload.noteConnections
        portalConnections = payload.portalConnections
        portalToPortalConnections = payload.portalToPortalConnections
        noteToNoteConnections = payload.noteToNoteConnections
        crossFloorConnections = payload.crossFloorConnections
        floors = payload.floors
        drawings = payload.drawings
        canvasOrigin = payload.canvasOrigin
        canvasZoom = payload.canvasZoom
        logger.debug("Workspace \(self.id) loaded: \(self.nodes.count) nodes")
    }

    // MARK: - Save (Story 1.5 AC: autosave background execution)

    func save() async throws {
        // buildPayload() reads all @Observable properties and must be called on MainActor,
        // Otherwise, calling in the background thread will cause a data race condition with the main thread writing.
        let payload = await MainActor.run { buildPayload() }
        let doc = WorkspaceDocument(payload: payload)
        try await pm.saveWorkspace(doc)
        // isDirty is an @Observable property, writing back also needs to be returned to MainActor
        await MainActor.run { isDirty = false }
        logger.debug("Workspace \(self.id) saved")
    }

    func saveSync() throws {
        let payload = buildPayload()
        let doc = WorkspaceDocument(payload: payload)
        let url = pm.workspaceURL(id: id)
        try pm.saveSync(doc, to: url)
    }

    // MARK: - Node Management

    func isExternallyManagedNode(id nodeId: UUID) -> Bool {
        guard let node = nodes.first(where: { $0.id == nodeId }),
              case .terminal(let content) = node.content else { return false }
        return content.agentType == "orca_external"
    }

    func addNode(_ node: CanvasNode) {
        nodes.append(node)
        isDirty = true
    }

    func removeNode(id nodeId: UUID) {
        guard !isExternallyManagedNode(id: nodeId) else { return }
        guard let node = nodes.first(where: { $0.id == nodeId }) else { return }

        // Stop the Terminal PTY process (to avoid memory leaks)
        if case .terminal = node.content {
            Task { @MainActor in
                TerminalManager.shared.removeTerminal(id: nodeId)
            }
        }

        // Release the Portal WKWebView instance and all its proxy objects (to avoid memory leaks)
        if case .portal = node.content {
            Task { @MainActor in
                PortalWebViewStore.shared.removeWebView(for: nodeId)
            }
            portalToPortalConnections.removeAll { $0.portalIdA == nodeId || $0.portalIdB == nodeId }
        }

        nodes.removeAll { $0.id == nodeId }
        isDirty = true
        connections.removeAll { $0.terminalIdA == nodeId || $0.terminalIdB == nodeId }
        noteConnections.removeAll { $0.terminalId == nodeId || $0.noteNodeId == nodeId }
        portalConnections.removeAll { $0.terminalId == nodeId || $0.portalNodeId == nodeId }
    }

    /// Removes an Orca proxy only when the authoritative registry reconciles it.
    func removeExternallyManagedNodeFromAuthority(id nodeId: UUID) {
        guard isExternallyManagedNode(id: nodeId) else { return }
        nodes.removeAll { $0.id == nodeId }
        connections.removeAll { $0.terminalIdA == nodeId || $0.terminalIdB == nodeId }
        noteConnections.removeAll { $0.terminalId == nodeId || $0.noteNodeId == nodeId }
        portalConnections.removeAll { $0.terminalId == nodeId || $0.portalNodeId == nodeId }
        isDirty = true
    }

    func updateNodeFrame(id nodeId: UUID, frame: CGRect) {
        if let idx = nodes.firstIndex(where: { $0.id == nodeId }) {
            nodes[idx].frame = frame
            nodes[idx].lastModifiedAt = Date()
            isDirty = true
        }
    }

    // MARK: - Connection persistence

    func addConnection(_ conn: TerminalConnection) {
        connections.removeAll { $0.id == conn.id }
        connections.append(conn)
        isDirty = true
    }

    func addNoteConnection(_ conn: NoteConnection) {
        noteConnections.removeAll { $0.id == conn.id }
        noteConnections.append(conn)
        isDirty = true
    }

    func addPortalConnection(_ conn: PortalConnection) {
        portalConnections.removeAll { $0.id == conn.id }
        portalConnections.append(conn)
        isDirty = true
    }

    func addPortalToPortalConnection(_ conn: PortalToPortalConnection) {
        portalToPortalConnections.removeAll { $0.id == conn.id }
        portalToPortalConnections.append(conn)
    }

    func removeConnection(id connId: UUID) {
        connections.removeAll { $0.id == connId }
        noteConnections.removeAll { $0.id == connId }
        portalConnections.removeAll { $0.id == connId }
        portalToPortalConnections.removeAll { $0.id == connId }
        isDirty = true
    }

    // MARK: - Portal URL updates silently (does not trigger canvas re-rendering)

    /// Update the current URL of the Portal node, only modify the persistence cache, do not trigger @Observable → do not refresh the canvas
    /// For use by handlePortalURLDidChange; the URL will be written to disk on the next save()
    func updatePortalURLSilently(portalId: UUID, url: String) {
        _pendingPortalURLs[portalId] = url
        isDirty = true
    }

    // MARK: - Private Auxiliary

    /// Snapshot the current state into a pure value type that can be safely passed to background threads
    func snapshotPayload() -> WorkspacePayload { buildPayload() }

    private func buildPayload() -> WorkspacePayload {
        var payload = WorkspacePayload(id: id, name: name, workingDirectory: workingDirectory)
        payload.nodes = nodes
        // Patch the silently cached Portal URL into the payload (does not affect nodes in memory)
        if !_pendingPortalURLs.isEmpty {
            for i in payload.nodes.indices {
                let id = payload.nodes[i].id
                if let url = _pendingPortalURLs[id],
                   case .portal(var pc) = payload.nodes[i].content {
                    pc.currentURL = url
                    payload.nodes[i].content = .portal(pc)
                }
            }
        }
        payload.connections = connections
        payload.noteConnections = noteConnections
        payload.portalConnections = portalConnections
        payload.portalToPortalConnections = portalToPortalConnections
        payload.noteToNoteConnections = noteToNoteConnections
        payload.crossFloorConnections = crossFloorConnections
        payload.floors = floors
        payload.drawings = drawings
        payload.canvasOrigin = canvasOrigin
        payload.canvasZoom = canvasZoom
        payload.lastModifiedAt = Date()
        return payload
    }
}
