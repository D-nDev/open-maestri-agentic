import Foundation

// MARK: - Notification Names

extension Notification.Name {
    static let showCreateWorkspace = Notification.Name("OpenMaestri.showCreateWorkspace")
    static let toggleCanvasZoom    = Notification.Name("OpenMaestri.toggleCanvasZoom")
    static let showFloorOverview   = Notification.Name("OpenMaestri.showFloorOverview")
    static let showCanvasFilter    = Notification.Name("OpenMaestri.showCanvasFilter")
    static let openInEditor        = Notification.Name("OpenMaestri.openInEditor")
    static let nextWorkspace       = Notification.Name("OpenMaestri.nextWorkspace")
    static let prevWorkspace       = Notification.Name("OpenMaestri.prevWorkspace")
    static let nextTerminal        = Notification.Name("OpenMaestri.nextTerminal")
    static let prevTerminal        = Notification.Name("OpenMaestri.prevTerminal")
    static let canvasZoomIn        = Notification.Name("OpenMaestri.canvasZoomIn")
    static let canvasZoomOut       = Notification.Name("OpenMaestri.canvasZoomOut")
    static let canvasZoomReset     = Notification.Name("OpenMaestri.canvasZoomReset")
    /// Minimap click to jump: userInfo contains "origin" CGPoint (canvas coordinates)
    static let canvasJumpToOrigin  = Notification.Name("OpenMaestri.canvasJumpToOrigin")
    /// Maestro recruit completion notification
    static let maestroRecruited        = Notification.Name("OpenMaestri.maestroRecruited")
    /// Edit terminal request: userInfo contains nodeId/terminalContent
    static let editTerminalRequested   = Notification.Name("OpenMaestri.editTerminalRequested")
    /// Right-click menu: Start connection (userInfo contains "nodeId" UUID)
    static let contextMenuConnect      = Notification.Name("OpenMaestri.contextMenuConnect")
    /// Right-click menu: Assign role (userInfo contains "nodeId" UUID)
    static let contextMenuAssignRole   = Notification.Name("OpenMaestri.contextMenuAssignRole")
    /// Right-click menu: switch Maestro mode (userInfo contains "nodeId" UUID)
    static let contextMenuToggleMaestro = Notification.Name("OpenMaestri.contextMenuToggleMaestro")
    /// Portal WebView rebuild notification (update view after shareSession)
    static let portalWebViewReplaced   = Notification.Name("OpenMaestri.portalWebViewReplaced")
    /// FileTree root directory change notification: userInfo contains nodeId/newPath
    static let fileTreeRootChanged     = Notification.Name("OpenMaestri.fileTreeRootChanged")
    /// Terminal from active→idle (task completed): userInfo contains "terminalId" UUID, "workspaceId" UUID?
    static let terminalBecameIdle      = Notification.Name("OpenMaestri.terminalBecameIdle")
    /// New workspace creation completed: userInfo contains "workspaceId" UUID
    static let workspaceCreated        = Notification.Name("OpenMaestri.workspaceCreated")
    /// Canvas node activated (focus passed to terminal): userInfo contains "nodeId" UUID
    static let canvasNodeActivated     = Notification.Name("OpenMaestri.canvasNodeActivated")
    /// Canvas selected node changes: userInfo contains "selectedIds" Set<UUID>
    static let canvasSelectionChanged  = Notification.Name("OpenMaestri.canvasSelectionChanged")
    /// ⌘ Hold to jump to number assignment: userInfo with "mapping" [UUID: Int] (empty mapping = clear)
    static let canvasJumpNumbersAssigned = Notification.Name("OpenMaestri.canvasJumpNumbersAssigned")
    /// File drop target node changes: userInfo contains optional "dropTargetNodeId" UUID (nil = clear highlight)
    static let canvasDropTargetChanged   = Notification.Name("OpenMaestri.canvasDropTargetChanged")
    /// Terminal attention status change: userInfo contains "terminalId" UUID, "needsAttention" Bool
    static let terminalAttentionChanged  = Notification.Name("OpenMaestri.terminalAttentionChanged")
    /// Connection status change (ask communication starts/ends): Trigger the canvas to rebuild the status cache and re-render
    static let connectionStatusChanged   = Notification.Name("OpenMaestri.connectionStatusChanged")
    /// Terminal theme/font changes (immediately applied to all open terminals)
    static let terminalAppearanceChanged = Notification.Name("OpenMaestri.terminalAppearanceChanged")
    /// The current working directory of the terminal changes: userInfo contains "terminalId" UUID, "directory" String
    static let terminalDirectoryChanged  = Notification.Name("OpenMaestri.terminalDirectoryChanged")
    /// Node isLocked status change: userInfo contains "nodeId" UUID, "isLocked" Bool
    static let canvasNodeLockChanged     = Notification.Name("OpenMaestri.canvasNodeLockChanged")
    /// Node content change: userInfo contains "nodeId" UUID, "content" NodeContent
    static let canvasNodeContentChanged  = Notification.Name("OpenMaestri.canvasNodeContentChanged")
    /// TerminalManager provider has been created and MaestroTerminalView can be attached
    static let terminalProviderReady     = Notification.Name("OpenMaestri.terminalProviderReady")
    /// Shell initialization is completed, MaestroTerminalView can load scrollback
    static let terminalShellReady        = Notification.Name("OpenMaestri.terminalShellReady")
    /// Portal created via CLI: userInfo contains "portalNode" CanvasNode, "terminalId" UUID?
    static let portalCreatedViaCLI       = Notification.Name("OpenMaestri.portalCreatedViaCLI")
    /// The _blank link in the Portal triggers a new Portal: userInfo contains "url" String, "openerPortalId" UUID
    static let portalOpenedNewWindow     = Notification.Name("OpenMaestri.portalOpenedNewWindow")
    /// Portal navigation completed, URL changed: userInfo contains "portalId" UUID, "url" String
    static let portalURLDidChange        = Notification.Name("OpenMaestri.portalURLDidChange")
    /// Note Format mode switching: userInfo contains "nodeId" UUID, "isPreviewing" Bool
    static let noteFormattedToggled      = Notification.Name("OpenMaestri.noteFormattedToggled")
    /// Note File content is written externally (CLI): userInfo contains "filePath" String, "content" String
    static let noteFileDidChange         = Notification.Name("OpenMaestri.noteFileDidChange")
    /// Text node content changes (real-time): userInfo contains "nodeId" UUID, "text" String, "textField" NSTextField
    static let textNodeDidChange         = Notification.Name("OpenMaestri.textNodeDidChange")
    /// Text node editing ends: userInfo contains "nodeId" UUID, "text" String
    static let textNodeDidEndEditing     = Notification.Name("OpenMaestri.textNodeDidEndEditing")
    /// Request text node to enter editing state: userInfo contains "nodeId" UUID
    static let textNodeShouldBeginEditing = Notification.Name("OpenMaestri.textNodeShouldBeginEditing")
    /// Request shape node to enter text editing state: userInfo contains "nodeId" UUID
    static let shapeNodeShouldBeginEditing = Notification.Name("OpenMaestri.shapeNodeShouldBeginEditing")
    /// End of shape node text editing: userInfo contains "nodeId" UUID, "text" String
    static let shapeNodeTextDidEndEditing = Notification.Name("OpenMaestri.shapeNodeTextDidEndEditing")
    /// Shape node rotation angle changes (real-time during dragging): userInfo contains "nodeId" UUID, "rotation" CGFloat
    static let shapeNodeRotationChanged = Notification.Name("OpenMaestri.shapeNodeRotationChanged")
    /// shape node rotation ends (mouseUp): userInfo contains "nodeId" UUID
    static let shapeNodeRotationDidEnd = Notification.Name("OpenMaestri.shapeNodeRotationDidEnd")
    /// Stroke node drawing is completed: userInfo contains "nodeType" String, "startPoint" CGPoint, "endPoint" CGPoint, "frame" CGRect
    static let strokeNodeDrawn = Notification.Name("OpenMaestri.strokeNodeDrawn")
    /// End of stroke control point dragging (mouseUp): userInfo contains "nodeId" UUID
    static let strokePointDragDidEnd = Notification.Name("OpenMaestri.strokePointDragDidEnd")
    /// Open Settings → Agents panel
    static let openSettingsAgents    = Notification.Name("OpenMaestri.openSettingsAgents")
}
