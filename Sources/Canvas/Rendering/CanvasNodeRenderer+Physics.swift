import AppKit
import CoreGraphics

// MARK: - Connection Physics & Rendering

extension CanvasNodeRenderer {

    /// Initialize physics simulation callback (called once after setupOverlay)
    func setupPhysicsCallbacks() {
        ropeSimulation.onTick = { [weak self] allPoints in
            self?.renderConnectionsFromPhysics(allPoints)
        }
        ropeSimulation.onSleep = { [weak self] allPoints in
            self?.renderConnectionsFromPhysics(allPoints)
        }
    }

    /// Shared physical callback rendering method: convert canvas coordinate control points to screen coordinates and push them to overlay
    func renderConnectionsFromPhysics(_ allPoints: [UUID: [CGPoint]]) {
        guard let overlay = overlayView, let canvas else { return }
        var renderables: [RenderableConnection] = []
        for meta in activeConnections {
            guard let canvasPoints = allPoints[meta.id] else { continue }
            let screenPoints = canvasPoints.map { canvas.canvasToScreen($0) }
            let status = connectionStatusCache[meta.id] ?? .idle
            renderables.append(RenderableConnection(id: meta.id, screenPoints: screenPoints, status: status))
        }
        overlay.connections = renderables
    }

    /// Lightweight re-rendering: only re-convert existing physical control points to screen coordinates
    /// Used when viewport pan/zoom changes (node canvas coordinates remain unchanged, only screen mapping changes)
    func rerenderConnections() {
        renderConnectionsFromPhysics(ropeSimulation.allPoints())
    }

    /// Synchronize connection list + update physical endpoints
    /// Calling timing: changes in the number of nodes/connections, changes in zoom/pan, and node dragging
    func syncConnections(workspace: WorkspaceManager) {
        guard let overlay = overlayView, let canvas else { return }

        var metas: [ConnectionMeta] = []
        var activeIds: Set<UUID> = []
        var anchorUpdates: [(id: UUID, anchorA: CGPoint, anchorB: CGPoint)] = []

        // Collect all connected endpoints (compute edge anchor points, not center points)
        for conn in workspace.connections {
            guard let frameA = liveNodeFrame(id: conn.terminalIdA, in: workspace),
                  let frameB = liveNodeFrame(id: conn.terminalIdB, in: workspace) else { continue }
            let centerB = CGPoint(x: frameB.midX, y: frameB.midY)
            let centerA = CGPoint(x: frameA.midX, y: frameA.midY)
            let anchorA = edgeAnchor(of: frameA, toward: centerB)
            let anchorB = edgeAnchor(of: frameB, toward: centerA)
            activeIds.insert(conn.id)
            metas.append(ConnectionMeta(id: conn.id, nodeIdA: conn.terminalIdA, nodeIdB: conn.terminalIdB))
            anchorUpdates.append((id: conn.id, anchorA: anchorA, anchorB: anchorB))
        }

        for conn in workspace.noteConnections {
            guard let frameA = liveNodeFrame(id: conn.terminalId, in: workspace),
                  let frameB = liveNodeFrame(id: conn.noteNodeId, in: workspace) else { continue }
            let centerB = CGPoint(x: frameB.midX, y: frameB.midY)
            let centerA = CGPoint(x: frameA.midX, y: frameA.midY)
            let anchorA = edgeAnchor(of: frameA, toward: centerB)
            let anchorB = edgeAnchor(of: frameB, toward: centerA)
            activeIds.insert(conn.id)
            metas.append(ConnectionMeta(id: conn.id, nodeIdA: conn.terminalId, nodeIdB: conn.noteNodeId))
            anchorUpdates.append((id: conn.id, anchorA: anchorA, anchorB: anchorB))
        }

        for conn in workspace.portalConnections {
            guard let frameA = liveNodeFrame(id: conn.terminalId, in: workspace),
                  let frameB = liveNodeFrame(id: conn.portalNodeId, in: workspace) else { continue }
            let centerB = CGPoint(x: frameB.midX, y: frameB.midY)
            let centerA = CGPoint(x: frameA.midX, y: frameA.midY)
            let anchorA = edgeAnchor(of: frameA, toward: centerB)
            let anchorB = edgeAnchor(of: frameB, toward: centerA)
            activeIds.insert(conn.id)
            metas.append(ConnectionMeta(id: conn.id, nodeIdA: conn.terminalId, nodeIdB: conn.portalNodeId))
            anchorUpdates.append((id: conn.id, anchorA: anchorA, anchorB: anchorB))
        }

        for conn in workspace.noteToNoteConnections {
            guard let frameA = liveNodeFrame(id: conn.noteNodeIdA, in: workspace),
                  let frameB = liveNodeFrame(id: conn.noteNodeIdB, in: workspace) else { continue }
            let centerB = CGPoint(x: frameB.midX, y: frameB.midY)
            let centerA = CGPoint(x: frameA.midX, y: frameA.midY)
            let anchorA = edgeAnchor(of: frameA, toward: centerB)
            let anchorB = edgeAnchor(of: frameB, toward: centerA)
            activeIds.insert(conn.id)
            metas.append(ConnectionMeta(id: conn.id, nodeIdA: conn.noteNodeIdA, nodeIdB: conn.noteNodeIdB))
            anchorUpdates.append((id: conn.id, anchorA: anchorA, anchorB: anchorB))
        }

        for conn in workspace.portalToPortalConnections {
            guard let frameA = liveNodeFrame(id: conn.portalIdA, in: workspace),
                  let frameB = liveNodeFrame(id: conn.portalIdB, in: workspace) else { continue }
            let centerB = CGPoint(x: frameB.midX, y: frameB.midY)
            let centerA = CGPoint(x: frameA.midX, y: frameA.midY)
            let anchorA = edgeAnchor(of: frameA, toward: centerB)
            let anchorB = edgeAnchor(of: frameB, toward: centerA)
            activeIds.insert(conn.id)
            metas.append(ConnectionMeta(id: conn.id, nodeIdA: conn.portalIdA, nodeIdB: conn.portalIdB))
            anchorUpdates.append((id: conn.id, anchorA: anchorA, anchorB: anchorB))
        }

        // Update active connection metadata
        activeConnections = metas

        // Clean up deleted ropes
        let existingIds = Set(ropeSimulation.ropes.keys)
        for deadId in existingIds.subtracting(activeIds) {
            ropeSimulation.removeRope(id: deadId)
        }

        // Add new rope/update endpoint of existing rope
        for update in anchorUpdates {
            if ropeSimulation.ropes[update.id] != nil {
                ropeSimulation.updateAnchors(id: update.id, anchorA: update.anchorA, anchorB: update.anchorB)
            } else {
                ropeSimulation.addRope(id: update.id, anchorA: update.anchorA, anchorB: update.anchorB)
            }
        }

        // Build connection status cache (O(n) once, subsequent physical callback O(1) query)
        rebuildConnectionStatusCache()

        // Render current frame immediately (make sure wires are visible, regardless of whether physics is running)
        var renderables: [RenderableConnection] = []
        for meta in metas {
            guard let canvasPoints = ropeSimulation.points(for: meta.id) else { continue }
            let screenPoints = canvasPoints.map { canvas.canvasToScreen($0) }
            let status = connectionStatusCache[meta.id] ?? .idle
            renderables.append(RenderableConnection(id: meta.id, screenPoints: screenPoints, status: status))
        }
        overlay.connections = renderables
    }

    /// Get the real-time frame of the node (preferably use the drag real-time value in the canvas, otherwise get it from the workspace)
    func liveNodeFrame(id: UUID, in workspace: WorkspaceManager) -> CGRect? {
        if let liveFrame = canvas?.nodeCanvasFrames[id] {
            return liveFrame
        }
        return workspace.nodes.first { $0.id == id }?.frame
    }

    // MARK: - Edge anchor point calculation

    /// Calculate the anchor point of the connecting line: starting from the center of the node frame and moving towards the intersection point with the border in the direction of the target center
    func edgeAnchor(of frame: CGRect, toward target: CGPoint) -> CGPoint {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = target.x - center.x
        let dy = target.y - center.y

        guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return center }

        let halfW = frame.width / 2.0
        let halfH = frame.height / 2.0

        var t: CGFloat = .greatestFiniteMagnitude

        if abs(dx) > 0.001 {
            let tx = halfW / abs(dx)
            if tx < t { t = tx }
        }
        if abs(dy) > 0.001 {
            let ty = halfH / abs(dy)
            if ty < t { t = ty }
        }

        return CGPoint(x: center.x + dx * t, y: center.y + dy * t)
    }

    /// Rebuild connection status cache (build [connectionId: status] dictionary from Active Connections in ConnectionManager)
    func rebuildConnectionStatusCache() {
        var cache: [UUID: ConnectionStatus] = [:]
        for meta in activeConnections {
            if let active = ConnectionManager.shared.connections[meta.id] {
                cache[meta.id] = active.status
            } else {
                let matched = ConnectionManager.shared.connections.values
                    .first { $0.nodeIdA == meta.nodeIdA && $0.nodeIdB == meta.nodeIdB }
                cache[meta.id] = matched?.status ?? .idle
            }
        }
        connectionStatusCache = cache
    }

    /// Incremental update during dragging: only update the rope endpoints involving the dragged node
    func updatePhysicsAnchorsForNodes(_ movedNodeIds: Set<UUID>, workspace: WorkspaceManager) {
        var updates: [(id: UUID, anchorA: CGPoint, anchorB: CGPoint)] = []

        for meta in activeConnections {
            guard movedNodeIds.contains(meta.nodeIdA) || movedNodeIds.contains(meta.nodeIdB) else { continue }
            guard let frameA = liveNodeFrame(id: meta.nodeIdA, in: workspace),
                  let frameB = liveNodeFrame(id: meta.nodeIdB, in: workspace) else { continue }
            let centerA = CGPoint(x: frameA.midX, y: frameA.midY)
            let centerB = CGPoint(x: frameB.midX, y: frameB.midY)
            let anchorA = edgeAnchor(of: frameA, toward: centerB)
            let anchorB = edgeAnchor(of: frameB, toward: centerA)
            updates.append((id: meta.id, anchorA: anchorA, anchorB: anchorB))
        }

        if !updates.isEmpty {
            ropeSimulation.updateAnchors(updates: updates)
            renderConnectionsFromPhysics(ropeSimulation.allPoints())
        }
    }
}
