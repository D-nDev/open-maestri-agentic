import Foundation
import OSLog

/// Connection type
enum ConnectionType {
    case terminalToTerminal
    case terminalToNote
    case terminalToPortal
    case portalToPortal
    case noteToNote
}

/// Connection status
enum ConnectionStatus {
    case idle           // Gray dashed line
    case communicating  // green glow
    case disconnected   // Red dashed line
    case error          // Error
}

/// Runtime connection record (in memory, serialized version in WorkspacePayload)
struct ActiveConnection {
    let id: UUID
    let nodeIdA: UUID
    let nodeIdB: UUID
    let type: ConnectionType
    var status: ConnectionStatus = .idle
}

/// Connection life cycle manager (@MainActor, canvas state modification must be in the main thread)
@MainActor
final class ConnectionManager {
    static let shared = ConnectionManager()
    private let logger = Logger.make(category: "ConnectionManager")

    private(set) var connections: [UUID: ActiveConnection] = [:]

    private init() {}

    // MARK: - Establish connection

    /// Establish Terminal↔Terminal connection and automatically inject Skill
    func connectTerminals(
        idA: UUID, idB: UUID,
        serverPort: UInt16,
        ropePoints: [[Double]] = []
    ) -> TerminalConnection {
        let conn = TerminalConnection(
            id: UUID(),
            terminalIdA: idA,
            terminalIdB: idB,
            ropePoints: ropePoints.isEmpty
                ? buildDefaultRopePoints() : ropePoints
        )
        let active = ActiveConnection(id: conn.id, nodeIdA: idA, nodeIdB: idB, type: .terminalToTerminal)
        connections[conn.id] = active

        // Inject Skill into both ends (FR29)
        let host = "\(Constants.interAgentServerHost):\(serverPort)"
        SkillInjector.shared.inject(to: idA, host: host)
        SkillInjector.shared.inject(to: idB, host: host)

        logger.info("Terminal connection established: \(idA.uuidString.prefix(8)) ↔ \(idB.uuidString.prefix(8))")
        return conn
    }

    /// Establish Terminal↔Terminal connection (while persisting to workspace)
    func connectTerminals(
        idA: UUID, idB: UUID,
        serverPort: UInt16,
        ropePoints: [[Double]] = [],
        workspace: WorkspaceManager?
    ) -> TerminalConnection {
        let conn = connectTerminals(idA: idA, idB: idB, serverPort: serverPort, ropePoints: ropePoints)
        workspace?.addConnection(conn)
        return conn
    }

    /// Establish Terminal↔Note connection (while persisting to workspace)
    func connectTerminalToNote(
        terminalId: UUID, noteNodeId: UUID,
        ropePoints: [[Double]] = [],
        workspace: WorkspaceManager?
    ) -> NoteConnection {
        let conn = connectTerminalToNote(terminalId: terminalId, noteNodeId: noteNodeId, ropePoints: ropePoints)
        workspace?.addNoteConnection(conn)
        return conn
    }

    /// Establish Terminal↔Portal connection (while persisting to workspace)
    func connectTerminalToPortal(
        terminalId: UUID, portalNodeId: UUID,
        ropePoints: [[Double]] = [],
        workspace: WorkspaceManager?
    ) -> PortalConnection {
        let conn = connectTerminalToPortal(terminalId: terminalId, portalNodeId: portalNodeId, ropePoints: ropePoints)
        workspace?.addPortalConnection(conn)
        return conn
    }

    /// Establish Terminal↔Note connection
    func connectTerminalToNote(terminalId: UUID, noteNodeId: UUID, ropePoints: [[Double]] = []) -> NoteConnection {
        let conn = NoteConnection(
            id: UUID(), terminalId: terminalId, noteNodeId: noteNodeId,
            ropePoints: ropePoints.isEmpty ? buildDefaultRopePoints() : ropePoints
        )
        let active = ActiveConnection(id: conn.id, nodeIdA: terminalId, nodeIdB: noteNodeId, type: .terminalToNote)
        connections[conn.id] = active
        logger.info("Terminal↔Note connection: \(terminalId.uuidString.prefix(8)) → \(noteNodeId.uuidString.prefix(8))")
        return conn
    }

    /// Establish Terminal↔Portal connection
    func connectTerminalToPortal(terminalId: UUID, portalNodeId: UUID, ropePoints: [[Double]] = []) -> PortalConnection {
        let conn = PortalConnection(
            id: UUID(), terminalId: terminalId, portalNodeId: portalNodeId,
            ropePoints: ropePoints.isEmpty ? buildDefaultRopePoints() : ropePoints
        )
        let active = ActiveConnection(id: conn.id, nodeIdA: terminalId, nodeIdB: portalNodeId, type: .terminalToPortal)
        connections[conn.id] = active
        return conn
    }

    /// Establish Note↔Note connection (Note Chaining)
    func connectNoteToNote(noteNodeIdA: UUID, noteNodeIdB: UUID, ropePoints: [[Double]] = []) -> NoteToNoteConnection {
        let conn = NoteToNoteConnection(
            noteNodeIdA: noteNodeIdA, noteNodeIdB: noteNodeIdB,
            ropePoints: ropePoints.isEmpty ? buildDefaultRopePoints() : ropePoints
        )
        let active = ActiveConnection(id: conn.id, nodeIdA: noteNodeIdA, nodeIdB: noteNodeIdB, type: .noteToNote)
        connections[conn.id] = active
        logger.info("Note↔Note connection: \(noteNodeIdA.uuidString.prefix(8)) ↔ \(noteNodeIdB.uuidString.prefix(8))")
        return conn
    }

    /// Establish Portal↔Portal connection (shared session)
    func connectPortalToPortal(portalIdA: UUID, portalIdB: UUID, ropePoints: [[Double]] = []) -> PortalToPortalConnection {
        let conn = PortalToPortalConnection(
            portalIdA: portalIdA, portalIdB: portalIdB,
            ropePoints: ropePoints.isEmpty ? buildDefaultRopePoints() : ropePoints
        )
        let active = ActiveConnection(id: conn.id, nodeIdA: portalIdA, nodeIdB: portalIdB, type: .portalToPortal)
        connections[conn.id] = active
        logger.info("Portal↔Portal connection: \(portalIdA.uuidString.prefix(8)) ↔ \(portalIdB.uuidString.prefix(8))")
        return conn
    }

    // MARK: - Disconnect

    /// Removes an active connection by ID and posts `connectionStatusChanged`.
    func disconnect(id: UUID) {
        connections.removeValue(forKey: id)
        logger.debug("Connection \(id.uuidString.prefix(8)) removed")
    }

    /// Removes all connections that involve the given node (called on node deletion).
    func disconnectAll(involvedNode nodeId: UUID) {
        let toRemove = connections.values.filter { $0.nodeIdA == nodeId || $0.nodeIdB == nodeId }
        toRemove.forEach { connections.removeValue(forKey: $0.id) }
    }

    // MARK: - Status update

    func updateStatus(_ status: ConnectionStatus, for connectionId: UUID) {
        connections[connectionId]?.status = status
    }

    func markCommunicating(_ connectionId: UUID) {
        updateStatus(.communicating, for: connectionId)
        // Restore idle after 150ms (FR: Gradient back to gray after communication ends)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if connections[connectionId]?.status == .communicating {
                updateStatus(.idle, for: connectionId)
            }
        }
    }

    // MARK: - Query

    func connections(for nodeId: UUID) -> [ActiveConnection] {
        connections.values.filter { $0.nodeIdA == nodeId || $0.nodeIdB == nodeId }
    }

    func connectedNodeIds(for nodeId: UUID) -> [UUID] {
        connections(for: nodeId).map { $0.nodeIdA == nodeId ? $0.nodeIdB : $0.nodeIdA }
    }

    // MARK: - Workspace recovery

    /// Rebuild all runtime connections from persisted workspace data (called on app startup/workspace switch)
    /// Do not regenerate the connection ID, directly reuse the persistent UUID to ensure stable CLI query results
    func restoreConnections(from workspace: WorkspaceManager, serverPort: UInt16) {
        let host = "\(Constants.interAgentServerHost):\(serverPort)"

        // Delete old connections related to this workspace node (to avoid multi-workspace pollution)
        let wsNodeIds = Set(workspace.nodes.map { $0.id })
        let toRemove = connections.values.filter {
            wsNodeIds.contains($0.nodeIdA) || wsNodeIds.contains($0.nodeIdB)
        }
        toRemove.forEach { connections.removeValue(forKey: $0.id) }

        for conn in workspace.connections {
            guard connections[conn.id] == nil else { continue }
            let active = ActiveConnection(
                id: conn.id,
                nodeIdA: conn.terminalIdA,
                nodeIdB: conn.terminalIdB,
                type: .terminalToTerminal
            )
            connections[conn.id] = active
            SkillInjector.shared.inject(to: conn.terminalIdA, host: host)
            SkillInjector.shared.inject(to: conn.terminalIdB, host: host)
            logger.info("Restored T↔T: \(conn.terminalIdA.uuidString.prefix(8)) ↔ \(conn.terminalIdB.uuidString.prefix(8))")
        }

        for conn in workspace.noteConnections {
            guard connections[conn.id] == nil else { continue }
            let active = ActiveConnection(
                id: conn.id,
                nodeIdA: conn.terminalId,
                nodeIdB: conn.noteNodeId,
                type: .terminalToNote
            )
            connections[conn.id] = active
            SkillInjector.shared.inject(to: conn.terminalId, host: host)
            logger.info("Restored T↔Note: \(conn.terminalId.uuidString.prefix(8)) → \(conn.noteNodeId.uuidString.prefix(8))")
        }

        for conn in workspace.portalConnections {
            guard connections[conn.id] == nil else { continue }
            let active = ActiveConnection(
                id: conn.id,
                nodeIdA: conn.terminalId,
                nodeIdB: conn.portalNodeId,
                type: .terminalToPortal
            )
            connections[conn.id] = active
            SkillInjector.shared.inject(to: conn.terminalId, host: host)
            logger.info("Restored T↔Portal: \(conn.terminalId.uuidString.prefix(8)) → \(conn.portalNodeId.uuidString.prefix(8))")
        }

        for conn in workspace.noteToNoteConnections {
            guard connections[conn.id] == nil else { continue }
            let active = ActiveConnection(
                id: conn.id,
                nodeIdA: conn.noteNodeIdA,
                nodeIdB: conn.noteNodeIdB,
                type: .noteToNote
            )
            connections[conn.id] = active
        }

        for conn in workspace.portalToPortalConnections {
            guard connections[conn.id] == nil else { continue }
            let active = ActiveConnection(
                id: conn.id,
                nodeIdA: conn.portalIdA,
                nodeIdB: conn.portalIdB,
                type: .portalToPortal
            )
            connections[conn.id] = active
        }
    }

    // MARK: - Tools

    private func buildDefaultRopePoints() -> [[Double]] {
        Array(repeating: [0.0, 0.0], count: Constants.ropeControlPointCount)
    }
}
