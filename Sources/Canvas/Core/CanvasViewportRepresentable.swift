import SwiftUI
import AppKit

/// Wrap CanvasViewportView as SwiftUI view while driving the node rendering engine
struct CanvasViewportRepresentable: NSViewRepresentable {
    @Binding var canvasOrigin: CGPoint
    @Binding var zoom: CGFloat
    var backgroundMode: String = "dotGrid"
    var workspace: WorkspaceManager?
    var isConnecting: Bool = false
    /// Node drawing mode (select the tool on the toolbar and then drag and drop to draw)
    var isDrawingMode: Bool = false
    var drawingNodeType: String = "terminal"
    var onViewportChanged: ((CGPoint, CGFloat) -> Void)?
    var onDeleteSelectedNodes: (() -> Void)?
    var onNodeJumpNumbersRequested: ((Bool) -> Void)?
    var onConnectionCreated: ((UUID, UUID) -> Void)?
    /// Drag and drop drawing completion callback (pass in node type and canvas coordinates CGRect)
    var onNodeDrawn: ((String, CGRect) -> Void)?
    /// freehand drawing completion callback (nodeType, normalized point sequence, bounding rectangle canvas coordinates)
    var onFreehandDrawn: ((String, [CGPoint], CGRect) -> Void)?
    /// Node selection change callback (selection IDs + screen frame of the first selected node)
    var onSelectionChanged: ((Set<UUID>, CGRect?) -> Void)?
    /// Finder file drag callback (file path array + canvas coordinate drop point)
    var onFilesDropped: (([String], CGPoint) -> Void)?
    /// File dragging node callback (file path array + target node ID)
    var onFilesDroppedOnNode: (([String], UUID) -> Void)?
    /// Available role presets (for TerminalNodeView context menu Assign Role submenu)
    var rolePresets: [RolePreset] = []
    /// Agent preset list (for use by the Terminal submenu of the right-click menu in the blank area of the canvas)
    var agentPresets: [AgentPreset] = []
    /// Right-click menu of blank area of canvas: Create node (nodeType, canvasPoint)
    var onCanvasContextCreateNode: ((String, CGPoint) -> Void)?
    /// Right-click menu of blank area of canvas: Create terminal (presetIndex, canvasPoint)
    var onCanvasContextCreateTerminal: ((Int, CGPoint) -> Void)?
    /// Right-click menu of blank area of canvas: Paste (canvasPoint)
    var onCanvasContextPaste: ((CGPoint) -> Void)?

    final class Coordinator {
        var renderer: CanvasNodeRenderer?
        var lastSyncKey: String = ""  // Full sync triggered on node/connection change
        var lastViewportKey: String = ""  // Trigger connection recalculation when zoom+origin changes
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    func makeNSView(context: Context) -> CanvasViewportView {
        let view = CanvasViewportView()
        view.canvasOrigin = canvasOrigin
        view.zoom = zoom
        view.backgroundMode = backgroundMode
        view.onViewportChanged = onViewportChanged
        view.onDeleteSelectedNodes = onDeleteSelectedNodes
        view.onNodeJumpNumbersRequested = onNodeJumpNumbersRequested
        view.onConnectionCreated = onConnectionCreated
        view.onSelectionChanged = onSelectionChanged
        view.onFilesDropped = onFilesDropped
        view.onFilesDroppedOnNode = onFilesDroppedOnNode
        view.agentPresets = agentPresets
        view.onCanvasContextCreateNode = onCanvasContextCreateNode
        view.onCanvasContextCreateTerminal = onCanvasContextCreateTerminal
        view.onCanvasContextPaste = onCanvasContextPaste

        let renderer = CanvasNodeRenderer(canvas: view)
        context.coordinator.renderer = renderer

        if let ws = workspace {
            renderer.sync(nodes: ws.nodes, workspace: ws)
            renderer.syncConnections(workspace: ws)
        }

        return view
    }

    @MainActor
    func updateNSView(_ nsView: CanvasViewportView, context: Context) {
        let originChanged = nsView.canvasOrigin != canvasOrigin
        let zoomChanged = nsView.zoom != zoom

        if originChanged { nsView.canvasOrigin = canvasOrigin }
        if zoomChanged { nsView.zoom = zoom }
        if nsView.backgroundMode != backgroundMode {
            nsView.backgroundMode = backgroundMode
            nsView.needsDisplay = true
        }

        // Synchronous connection tool mode
        if nsView.isInConnectingMode != isConnecting {
            nsView.isInConnectingMode = isConnecting
        }

        // Synchronous node drawing mode
        nsView.isInDrawingMode = isDrawingMode
        nsView.drawingNodeType = drawingNodeType
        nsView.onNodeDrawn = onNodeDrawn
        nsView.onFreehandDrawn = onFreehandDrawn
        nsView.onFilesDropped = onFilesDropped
        nsView.onFilesDroppedOnNode = onFilesDroppedOnNode
        nsView.agentPresets = agentPresets
        nsView.onCanvasContextCreateNode = onCanvasContextCreateNode
        nsView.onCanvasContextCreateTerminal = onCanvasContextCreateTerminal
        nsView.onCanvasContextPaste = onCanvasContextPaste

        guard let ws = workspace, let renderer = context.coordinator.renderer else { return }

        // Synchronize character presets to renderer (for use by TerminalNodeView right-click menu)
        renderer.rolePresets = rolePresets

        // Construct syncKey using number of nodes +
        let nodeHash = ws.nodes.reduce(0) { $0 ^ $1.id.hashValue }
        let nodeIds = "\(ws.nodes.count)-\(nodeHash)"
        let connCount = ws.connections.count + ws.noteConnections.count + ws.portalConnections.count
            + ws.portalToPortalConnections.count + ws.noteToNoteConnections.count
        let currentSyncKey = "\(nodeIds)|\(connCount)"
        let viewportKey = "\(canvasOrigin.x.rounded())_\(canvasOrigin.y.rounded())_\(zoom)"

        if currentSyncKey != context.coordinator.lastSyncKey {
            // Node set or number of connections changed: full sync
            renderer.sync(nodes: ws.nodes, workspace: ws)
            renderer.syncConnections(workspace: ws)
            context.coordinator.lastSyncKey = currentSyncKey
            context.coordinator.lastViewportKey = viewportKey
        } else if originChanged || zoomChanged {
            // viewport pan/zoom changes: lightweight re-rendering (only screen coordinate mapping is recalculated, not anchor points)
            renderer.rerenderConnections()
            context.coordinator.lastViewportKey = viewportKey
        }
    }
}
