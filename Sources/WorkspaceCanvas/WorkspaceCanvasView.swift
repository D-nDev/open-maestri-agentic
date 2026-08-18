import SwiftUI

// MARK: - Workspace canvas view

struct WorkspaceCanvasView: View {
    @Environment(AppState.self) private var appState
    @Bindable var workspace: WorkspaceManager
    var backgroundMode: String
    @State private var canvasOrigin: CGPoint = Constants.canvasInitialOrigin
    @State private var zoom: CGFloat = 1.0
    @State private var isConnecting = false
    @State private var activeDrawingTool: String? = nil
    @AppStorage("lastSelectedDrawingSubtool") private var activeShapeSubtool: String = "rect"
    @State private var textNodeEditingId: UUID? = nil
    @State private var showFloorOverview = false
    @State private var terminalToEdit: (nodeId: UUID, content: TerminalContent)? = nil
    @State private var selectedNodeIds: Set<UUID> = []
    @State private var selectedNodeScreenFrame: CGRect? = nil
    @State private var showMinimap = false
    @State private var showAssignRoleSheet = false
    @State private var assignRoleNodeId: UUID? = nil
    @State private var orcaRegistry = OrcaTerminalRegistry.shared
    @State private var orcaSendTarget: OrcaSendTarget?


    var body: some View {
        ZStack(alignment: .top) {
            canvasBody

            // Top floating toolbar area
            toolbarOverlay
        }
        .onReceive(NotificationCenter.default.publisher(for: .strokeNodeDrawn)) { notif in
            guard let nodeType = notif.userInfo?["nodeType"] as? String,
                  let startPoint = notif.userInfo?["startPoint"] as? CGPoint,
                  let endPoint = notif.userInfo?["endPoint"] as? CGPoint,
                  let frame = notif.userInfo?["frame"] as? CGRect else { return }
            let strokeType: StrokeType = nodeType == "stroke_arrow" ? .arrow : .line
            createStrokeAtFrame(frame, strokeType: strokeType,
                                startCanvas: startPoint, endCanvas: endPoint)
            activeDrawingTool = nil
        }
    }

    /// Whether the current full screen
    private var isFullScreen: Bool { WindowStateObserver.shared.isFullScreen }

    /// Top toolbar overlay
    @ViewBuilder
    private var toolbarOverlay: some View {
        VStack(spacing: 0) {
            // Floating toolbar (8px from top of window)
            CanvasToolbar(workspace: workspace, isConnecting: $isConnecting, activeDrawingTool: $activeDrawingTool, activeShapeSubtool: $activeShapeSubtool)
                .padding(.top, 8)

            // Secondary operation toolbar (displayed when a node is selected)
            // Increase the distance between the first-level toolbar and the first-level toolbar
            Spacer().frame(height: 12)

            // Hide node toolbar when drawing tool is active (only instance of secondary toolbar)
            if activeDrawingTool == nil && !selectedNodeIds.isEmpty && selectedNodeIds.contains(where: { id in
                workspace.nodes.contains { $0.id == id }
            }) {
                if let selectedId = selectedNodeIds.first,
                   selectedNodeIds.count == 1,
                   orcaRegistry.isExternalNode(selectedId) {
                    OrcaTerminalContextToolbar(
                        onConnect: { startConnectionFromSelected() },
                        onRefresh: { Task { await orcaRegistry.refresh(nodeId: selectedId) } },
                        onSendQueued: { orcaSendTarget = OrcaSendTarget(id: selectedId, mode: .queue) },
                        onInterrupt: { orcaSendTarget = OrcaSendTarget(id: selectedId, mode: .interrupt) },
                        connections: selectedNodeConnections,
                        onDeleteConnection: { deleteConnection(id: $0) }
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                } else if selectedNodeContentType == "fileTree" {
                    FileTreeContextToolbar(
                        onRevealInFinder: { revealFileTreeInFinder() },
                        onChangeRoot: { changeFileTreeRoot() },
                        onDelete: { deleteSelectedNodes() }
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.15), value: selectedNodeIds)
                } else if selectedNodeContentType == "stickyNote",
                          let noteId = selectedNodeIds.first {
                    NoteContextToolbar(
                        nodeId: noteId,
                        isFormatted: noteIsPreviewing(nodeId: noteId),
                        fontSize: noteFontSize(nodeId: noteId),
                        currentColor: noteCurrentColor(nodeId: noteId),
                        onBgColor: { color in setNoteColor(nodeId: noteId, color: color) },
                        onFontSize: { size in setNoteFontSize(nodeId: noteId, size: size) },
                        onConnect: { startConnectionFromSelected() },
                        onToggleFormatted: { toggleNoteFormatted(nodeId: noteId) },
                        onDelete: { deleteSelectedNodes() },
                        onSaveAs: { saveNoteAs(nodeId: noteId) },
                        connections: selectedNodeConnections,
                        onDeleteConnection: { deleteConnection(id: $0) }
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.15), value: selectedNodeIds)
                } else if selectedNodeContentType == "text",
                          let textId = selectedNodeIds.first {
                    TextContextToolbar(
                        nodeId: textId,
                        fontSize: textFontSize(nodeId: textId),
                        fontWeight: textFontWeight(nodeId: textId),
                        fontFamily: textFontFamily(nodeId: textId),
                        currentColor: textCurrentColor(nodeId: textId),
                        onFontSize: { size in setTextFontSize(nodeId: textId, size: size) },
                        onFontWeight: { weight in setTextFontWeight(nodeId: textId, weight: weight) },
                        onFontFamily: { family in setTextFontFamily(nodeId: textId, family: family) },
                        onColor: { color in setTextColor(nodeId: textId, color: color) },
                        onDelete: { deleteSelectedNodes() }
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.15), value: selectedNodeIds)
                } else if selectedNodeContentType == "shape",
                          let shapeId = selectedNodeIds.first,
                          let sc = shapeContent(nodeId: shapeId) {
                    ShapeContextToolbar(
                        nodeId: shapeId,
                        content: sc,
                        onContentChange: { newContent in setShapeContent(nodeId: shapeId, content: newContent) },
                        onDelete: { deleteSelectedNodes() }
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.15), value: selectedNodeIds)
                } else if selectedNodeContentType == "stroke",
                          let strokeId = selectedNodeIds.first,
                          let sc = strokeContent(nodeId: strokeId) {
                    StrokeContextToolbar(
                        nodeId: strokeId,
                        content: sc,
                        onContentChange: { newContent in setStrokeContent(nodeId: strokeId, content: newContent) },
                        onDelete: { deleteSelectedNodes() }
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.15), value: selectedNodeIds)
                } else if selectedNodeContentType == "freehand",
                          let freehandId = selectedNodeIds.first,
                          let fc = freehandContent(nodeId: freehandId) {
                    FreehandContextToolbar(
                        nodeId: freehandId,
                        content: fc,
                        onContentChange: { newContent in setFreehandContent(nodeId: freehandId, content: newContent) },
                        onDelete: { deleteSelectedNodes() }
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.15), value: selectedNodeIds)
                } else if selectedNodeIds.count > 1 {
                    HStack(spacing: 2) {
                        ContextToolbarButton(
                            icon: "trash",
                            tooltip: "tooltip.node.delete".localized,
                            action: { deleteSelectedNodes() }
                        )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(white: 0.9), lineWidth: 0.5)
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.15), value: selectedNodeIds)
                } else {
                    NodeContextToolbar(
                        onEdit: { editSelectedNode() },
                        onConnect: { startConnectionFromSelected() },
                        onRefresh: { /* Reserve refresh operation */ },
                        onDelete: { deleteSelectedNodes() },
                        connections: selectedNodeConnections,
                        onDeleteConnection: { deleteConnection(id: $0) }
                    )
                    .fixedSize()
                    .padding(.bottom, 36)
                    .contentShape(Rectangle())
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.15), value: selectedNodeIds)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Non-full screen mode: ignore top safe area and let toolbar extend into title bar area
        // Full screen mode: safe area is not ignored, toolbar is displayed normally below NavigationSplitView toolbar
        .modifier(ConditionalIgnoreSafeAreaTop(ignore: !isFullScreen))
        .zIndex(100)
    }

    /// Building CanvasViewportRepresentable (extracted separately to help compiler infer types)
    private var canvasViewportRepresentable: CanvasViewportRepresentable {
        CanvasViewportRepresentable(
            canvasOrigin: $canvasOrigin,
            zoom: $zoom,
            backgroundMode: backgroundMode,
            workspace: workspace,
            isConnecting: isConnecting,
            isDrawingMode: activeDrawingTool != nil,
            drawingNodeType: activeDrawingTool == "shape" ? activeShapeSubtool : (activeDrawingTool ?? "terminal"),
            onViewportChanged: { origin, z in
                canvasOrigin = origin
                zoom = z
                workspace.canvasOrigin = origin
                workspace.canvasZoom = z
            },
            onDeleteSelectedNodes: {
                // CanvasNodeRenderer handles node deletion through onClose callback
            },
            onNodeJumpNumbersRequested: { _ in
                // Digital badges are managed by TerminalNodeView itself
            },
            onConnectionCreated: handleConnectionCreated(idA:idB:),
            onNodeDrawn: { nodeType, canvasRect in
                handleNodeDrawn(nodeType: nodeType, frame: canvasRect)
            },
            onFreehandDrawn: { (nodeType: String, normalizedPoints: [CGPoint], boundingFrame: CGRect) in
                handleFreehandDrawn(nodeType: nodeType, points: normalizedPoints, frame: boundingFrame)
            },
            onSelectionChanged: { ids, frame in
                selectedNodeIds = ids
                selectedNodeScreenFrame = frame
                if let editingId = textNodeEditingId, !ids.contains(editingId) {
                    textNodeEditingId = nil
                }
            },
            onFilesDropped: { paths, canvasPoint in
                handleFilesDropped(paths: paths, at: canvasPoint)
            },
            onFilesDroppedOnNode: { paths, nodeId in
                handleFilesDroppedOnNode(paths: paths, nodeId: nodeId)
            },
            rolePresets: appState.preferences.rolePresets,
            agentPresets: appState.preferences.agentPresets.filter { $0.isActive },
            onCanvasContextCreateNode: { nodeType, canvasPoint in
                handleCanvasContextCreateNode(nodeType: nodeType, at: canvasPoint)
            },
            onCanvasContextCreateTerminal: { presetIndex, canvasPoint in
                handleCanvasContextCreateTerminal(presetIndex: presetIndex, at: canvasPoint)
            },
            onCanvasContextPaste: { canvasPoint in
                handleCanvasContextPaste(at: canvasPoint)
            }
        )
    }

    @ViewBuilder
    private var canvasBody: some View {
        GeometryReader { geometry in
            canvasBody(viewportSize: geometry.size)
        }
    }

    @ViewBuilder
    private func canvasBody(viewportSize: CGSize) -> some View {
        ZStack {
            canvasViewportRepresentable
            .ignoresSafeArea()

            // Bottom right corner control group
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()

                    // Bottom right control group
                    HStack(spacing: 8) {
                        // Floor button
                        Button {
                            showFloorOverview = true
                        } label: {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 14))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                        .clipShape(Circle())
                        .help("floor.overview".localized)

                        // Thumbnail button
                        Button {
                            showMinimap.toggle()
                        } label: {
                            Image(systemName: "map")
                                .font(.system(size: 14))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                        .clipShape(Circle())
                        .help("tooltip.minimap".localized)
                        .popover(isPresented: $showMinimap, arrowEdge: .top) {
                            CanvasMinimapPopover(
                                nodes: workspace.nodes,
                                canvasOrigin: canvasOrigin,
                                zoom: zoom,
                                viewportSize: viewportSize,
                                onJumpTo: { targetPoint in
                                    // Trigger CanvasViewportView smooth animation jump through Notification
                                    NotificationCenter.default.post(
                                        name: .canvasJumpToOrigin,
                                        object: nil,
                                        userInfo: ["origin": targetPoint]
                                    )
                                    showMinimap = false
                                }
                            )
                            .environment(\.locale, LocalizationManager.shared.locale)
                        }

                        // Zoom Control
                        HStack(spacing: 0) {
                            Button {
                                NotificationCenter.default.post(name: .canvasZoomOut, object: nil)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Text("\(Int(zoom * 100))%")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .frame(minWidth: 40)

                            Button {
                                NotificationCenter.default.post(name: .canvasZoomIn, object: nil)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(12)
                }
            }
        }
        .onAppear {
            canvasOrigin = workspace.canvasOrigin
            zoom = workspace.canvasZoom
            orcaRegistry.start(workspace: workspace)
            preInitializeAllTerminals()
            ConnectionManager.shared.restoreConnections(
                from: workspace,
                serverPort: InterAgentServer.shared.port
            )
        }
        .onDisappear {
            orcaRegistry.stop(workspaceId: workspace.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFloorOverview)) { _ in
            showFloorOverview = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .maestroRecruited)) { notif in
            handleMaestroRecruited(notif: notif)
        }
        .onReceive(NotificationCenter.default.publisher(for: .portalCreatedViaCLI)) { notif in
            handlePortalCreatedViaCLI(notif: notif)
        }
        .onReceive(NotificationCenter.default.publisher(for: .portalOpenedNewWindow)) { notif in
            handlePortalOpenedNewWindow(notif: notif)
        }
        .onReceive(NotificationCenter.default.publisher(for: .portalURLDidChange)) { notif in
            handlePortalURLDidChange(notif: notif)
        }
        .onReceive(NotificationCenter.default.publisher(for: .editTerminalRequested)) { notif in
            if let nodeId = notif.userInfo?["nodeId"] as? UUID,
               let tc = notif.userInfo?["terminalContent"] as? TerminalContent {
                terminalToEdit = (nodeId: nodeId, content: tc)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextMenuConnect)) { notif in
            if let nodeId = notif.userInfo?["nodeId"] as? UUID {
                selectedNodeIds = [nodeId]
                isConnecting = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextMenuAssignRole)) { notif in
            if let nodeId = notif.userInfo?["nodeId"] as? UUID {
                assignRoleNodeId = nodeId
                showAssignRoleSheet = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .contextMenuToggleMaestro)) { notif in
            if let nodeId = notif.userInfo?["nodeId"] as? UUID {
                toggleMaestroMode(nodeId: nodeId)
            }
        }
        .sheet(isPresented: $showAssignRoleSheet) {
            AssignRoleSheet(
                roles: appState.preferences.rolePresets,
                currentRoleId: currentAssignedRoleId,
                onAssign: { role in
                    applyRole(role, toNodeId: assignRoleNodeId)
                    showAssignRoleSheet = false
                },
                onUnassign: {
                    unassignRole(fromNodeId: assignRoleNodeId)
                    showAssignRoleSheet = false
                },
                onDismiss: { showAssignRoleSheet = false }
            )
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(item: $orcaSendTarget) { target in
            OrcaSendSheet(target: target)
        }
        .sheet(item: Binding(
            get: { terminalToEdit.map { EditTerminalItem(id: $0.nodeId, content: $0.content) } },
            set: { if $0 == nil { terminalToEdit = nil } }
        )) { item in
            EditTerminalSheet(nodeId: item.id, content: item.content, workspace: workspace) {
                guard let savedNode = workspace.nodes.first(where: { $0.id == item.id }) else {
                    terminalToEdit = nil
                    return
                }
                handleRoleChangeIfNeeded(
                    nodeId: item.id,
                    oldContent: .terminal(item.content),
                    newContent: savedNode.content
                )
                terminalToEdit = nil
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(isPresented: $showFloorOverview) {
            FloorOverviewView(workspace: workspace)
                .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(isPresented: $showTerminalSheetForDrawing, onDismiss: { activeDrawingTool = nil }) {
            NewTerminalSheet(
                initialPresets: appState.preferences.agentPresets.filter { $0.isActive },
                initialRoles: appState.preferences.rolePresets,
                defaultWorkingDirectory: workspace.workingDirectory
            ) { preset, role, isManager, workDir in
                createTerminalAtFrame(showTerminalDrawnFrame, preset: preset, role: role, isManager: isManager, workingDirectory: workDir)
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(isPresented: $showPortalSheetForDrawing, onDismiss: { activeDrawingTool = nil }) {
            NewPortalSheet { name, url in
                createPortalAtFrame(showPortalDrawnFrame, name: name, url: url)
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .onReceive(NotificationCenter.default.publisher(for: .textNodeDidChange)) { notif in
            guard let nodeId = notif.userInfo?["nodeId"] as? UUID,
                  let text   = notif.userInfo?["text"] as? String,
                  let idx    = workspace.nodes.firstIndex(where: { $0.id == nodeId }),
                  case .text(var tc) = workspace.nodes[idx].content else { return }
            tc.text = text
            workspace.nodes[idx].content = .text(tc)
            let newSize = measuredTextNodeSize(tc)
            let newFrame = CGRect(origin: workspace.nodes[idx].frame.origin, size: newSize)
            workspace.updateNodeFrame(id: nodeId, frame: newFrame)
            NotificationCenter.default.post(
                name: .canvasNodeContentChanged,
                object: nil,
                userInfo: ["nodeId": nodeId, "content": workspace.nodes[idx].content, "frame": newFrame]
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .textNodeDidEndEditing)) { notif in
            guard let nodeId = notif.userInfo?["nodeId"] as? UUID,
                  let text   = notif.userInfo?["text"] as? String else { return }
            if let idx = workspace.nodes.firstIndex(where: { $0.id == nodeId }),
               case .text(var tc) = workspace.nodes[idx].content {
                tc.text = text
                workspace.nodes[idx].content = .text(tc)
                if !text.isEmpty {
                    let newSize = measuredTextNodeSize(tc)
                    let newFrame = CGRect(origin: workspace.nodes[idx].frame.origin, size: newSize)
                    workspace.updateNodeFrame(id: nodeId, frame: newFrame)
                    NotificationCenter.default.post(
                        name: .canvasNodeContentChanged,
                        object: nil,
                        userInfo: ["nodeId": nodeId, "content": workspace.nodes[idx].content, "frame": newFrame]
                    )
                } else {
                    NotificationCenter.default.post(
                        name: .canvasNodeContentChanged,
                        object: nil,
                        userInfo: ["nodeId": nodeId, "content": workspace.nodes[idx].content]
                    )
                }
                Task { try? await workspace.save() }
            }
            textNodeEditingId = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .textNodeShouldBeginEditing)) { notif in
            guard let nodeId = notif.userInfo?["nodeId"] as? UUID else { return }
            selectedNodeIds = [nodeId]
            textNodeEditingId = nodeId
        }
        .onReceive(NotificationCenter.default.publisher(for: .shapeNodeTextDidEndEditing)) { notif in
            guard let id = notif.userInfo?["nodeId"] as? UUID,
                  let text = notif.userInfo?["text"] as? String,
                  var sc = shapeContent(nodeId: id) else { return }
            sc.text = text
            setShapeContent(nodeId: id, content: sc)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shapeNodeRotationChanged)) { notif in
            guard let id = notif.userInfo?["nodeId"] as? UUID,
                  let rotation = notif.userInfo?["rotation"] as? CGFloat,
                  let idx = workspace.nodes.firstIndex(where: { $0.id == id }),
                  case .shape(var sc) = workspace.nodes[idx].content else { return }
            sc.rotation = rotation
            let newContent = NodeContent.shape(sc)
            workspace.nodes[idx].content = newContent
            NotificationCenter.default.post(
                name: .canvasNodeContentChanged,
                object: nil,
                userInfo: ["nodeId": id, "content": newContent]
            )
            // Save deferred to rotation end
        }
        .onReceive(NotificationCenter.default.publisher(for: .shapeNodeRotationDidEnd)) { notif in
            guard let _ = notif.userInfo?["nodeId"] as? UUID else { return }
            Task { try? await workspace.save() }
        }
        .strokePointDragHandler(workspace: workspace)
        .autosave(workspace: workspace)
        .environment(\.textNodeEditingId, textNodeEditingId)
    }

    // MARK: - Drag and draw to create nodes

    private func handleNodeDrawn(nodeType: String, frame: CGRect) {
        switch nodeType {
        case "terminal":
            showTerminalDrawnFrame = frame
            showTerminalSheetForDrawing = true
        case "stickyNote":
            createNoteAtFrame(frame)
            activeDrawingTool = nil
        case "portal":
            showPortalDrawnFrame = frame
            showPortalSheetForDrawing = true
        case "fileTree":
            createFileTreeAtFrame(frame)
            activeDrawingTool = nil
        case "text":
            createTextAtFrame(frame)
            activeDrawingTool = nil
        case "rect":
            createShapeAtFrame(frame, shapeType: .rect)
            activeDrawingTool = nil
        case "ellipse":
            createShapeAtFrame(frame, shapeType: .ellipse)
            activeDrawingTool = nil
        case "diamond":
            createShapeAtFrame(frame, shapeType: .diamond)
            activeDrawingTool = nil
        case "shape":
            createShapeAtFrame(frame, shapeType: .rect)
            activeDrawingTool = nil
        default:
            break
        }
    }

    private func handleConnectionCreated(idA: UUID, idB: UUID) {
        // Prevent repeated connections of the same pair of nodes
        let alreadyConnected = workspace.connections.contains {
            ($0.terminalIdA == idA && $0.terminalIdB == idB) ||
            ($0.terminalIdA == idB && $0.terminalIdB == idA)
        } || workspace.noteConnections.contains {
            ($0.terminalId == idA && $0.noteNodeId == idB) ||
            ($0.terminalId == idB && $0.noteNodeId == idA)
        } || workspace.portalConnections.contains {
            ($0.terminalId == idA && $0.portalNodeId == idB) ||
            ($0.terminalId == idB && $0.portalNodeId == idA)
        } || workspace.noteToNoteConnections.contains {
            ($0.noteNodeIdA == idA && $0.noteNodeIdB == idB) ||
            ($0.noteNodeIdA == idB && $0.noteNodeIdB == idA)
        } || workspace.portalToPortalConnections.contains {
            ($0.portalIdA == idA && $0.portalIdB == idB) ||
            ($0.portalIdA == idB && $0.portalIdB == idA)
        }
        guard !alreadyConnected else {
            isConnecting = false
            return
        }

        // Select the correct connection type based on node content type
        let typeA = workspace.nodes.first { $0.id == idA }.map { contentTypeName($0.content) }
        let typeB = workspace.nodes.first { $0.id == idB }.map { contentTypeName($0.content) }
        let cm = ConnectionManager.shared

        switch (typeA, typeB) {
        case ("terminal", "terminal"):
            let conn = cm.connectTerminals(idA: idA, idB: idB, serverPort: InterAgentServer.shared.port)
            workspace.addConnection(conn)
        case ("terminal", "stickyNote"), ("stickyNote", "terminal"):
            let termId = typeA == "terminal" ? idA : idB
            let noteId = typeA == "stickyNote" ? idA : idB
            let conn = cm.connectTerminalToNote(terminalId: termId, noteNodeId: noteId)
            workspace.addNoteConnection(conn)
        case ("terminal", "portal"), ("portal", "terminal"):
            let termId = typeA == "terminal" ? idA : idB
            let portId = typeA == "portal" ? idA : idB
            let conn = cm.connectTerminalToPortal(terminalId: termId, portalNodeId: portId)
            workspace.addPortalConnection(conn)
        case ("stickyNote", "stickyNote"):
            let conn = cm.connectNoteToNote(noteNodeIdA: idA, noteNodeIdB: idB)
            workspace.noteToNoteConnections.append(conn)
        case ("portal", "portal"):
            let conn = cm.connectPortalToPortal(portalIdA: idA, portalIdB: idB)
            workspace.addPortalToPortalConnection(conn)
            PortalWebViewStore.shared.shareSession(portalIdA: idA, portalIdB: idB)
        default:
            break
        }
        Task { try? await workspace.save() }
        isConnecting = false
    }

    private func handleFreehandDrawn(nodeType: String, points: [CGPoint], frame: CGRect) {
        let freehandType: FreehandType = nodeType == "freehand_highlighter" ? .highlighter : .pen
        createFreehandFromPoints(points, boundingFrame: frame, freehandType: freehandType)
        activeDrawingTool = nil
    }

    // MARK: - Canvas Blank Area Context Menu Handlers

    /// Right-click menu of blank area of canvas: Create nodes of specified type
    private func handleCanvasContextCreateNode(nodeType: String, at canvasPoint: CGPoint) {
        let size = defaultNodeSize(for: nodeType)
        let frame = CGRect(
            x: canvasPoint.x - size.width / 2,
            y: canvasPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        switch nodeType {
        case "stickyNote":
            createNoteAtFrame(frame)
        case "fileTree":
            createFileTreeAtFrame(frame)
        case "portal":
            // Portal needs to pop up sheet and enter URL
            showPortalDrawnFrame = frame
            showPortalSheetForDrawing = true
        case "text":
            createTextAtFrame(frame)
        case "linkedFile":
            // Linked files: Pop up file selection panel
            createLinkedFileAtFrame(frame)
        default:
            break
        }
    }

    /// Right-click menu of blank area of canvas: Create terminal node based on preset index
    private func handleCanvasContextCreateTerminal(presetIndex: Int, at canvasPoint: CGPoint) {
        let activePresets = appState.preferences.agentPresets.filter { $0.isActive }
        guard presetIndex >= 0, presetIndex < activePresets.count else { return }
        let preset = activePresets[presetIndex]
        let size = defaultNodeSize(for: "terminal")
        let frame = CGRect(
            x: canvasPoint.x - size.width / 2,
            y: canvasPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        createTerminalAtFrame(frame, preset: preset, role: nil, isManager: false)
    }

    /// Right-click menu of blank area of canvas: Paste
    private func handleCanvasContextPaste(at canvasPoint: CGPoint) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        // Paste text content as Note node
        let name = "Pasted-\(UUID().uuidString.prefix(6))"
        let fileName = "\(name).md"
        var nc = StickyNoteContent(name: name)
        nc.fileName = fileName
        let size = defaultNodeSize(for: "stickyNote")
        let frame = CGRect(
            x: canvasPoint.x - size.width / 2,
            y: canvasPoint.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        let node = CanvasNode(frame: frame, content: .stickyNote(nc))
        let filePath = PersistenceManager.shared.notesDirURL(workspaceId: workspace.id)
            .appendingPathComponent(fileName).path
        try? FileManager.default.createDirectory(
            atPath: PersistenceManager.shared.notesDirURL(workspaceId: workspace.id).path,
            withIntermediateDirectories: true
        )
        try? text.write(toFile: filePath, atomically: true, encoding: .utf8)
        NoteRegistry.shared.register(name: name, filePath: filePath, nodeId: node.id)
        workspace.addNode(node)
        Task { try? await workspace.save() }
    }

    /// Link File: Pops up the file selector and creates a node at the specified location
    private func createLinkedFileAtFrame(_ frame: CGRect) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let name = url.lastPathComponent
                var nc = StickyNoteContent(name: name)
                nc.fileName = url.lastPathComponent
                nc.storageMode = .custom(path: url.path)
                let node = CanvasNode(frame: frame, content: .stickyNote(nc))
                NoteRegistry.shared.register(name: name, filePath: url.path, nodeId: node.id)
                workspace.addNode(node)
                Task { try? await workspace.save() }
            }
        }
    }

    /// Default size corresponding to node type (reusing the definition of CanvasViewportView)
    @State private var showTerminalDrawnFrame: CGRect = .zero
    @State private var showTerminalSheetForDrawing = false
    @State private var showPortalDrawnFrame: CGRect = .zero
    @State private var showPortalSheetForDrawing = false
    // MARK: - Maestro Recruit processing
    // MARK: - terminal pre-initialization

    /// Initialize all terminals in parallel immediately upon entering the workspace (PTY forks simultaneously)
    /// Benchmarking Maestri: All terminals start in parallel and are ready within 5 seconds
    @MainActor
    private func preInitializeAllTerminals() {
        let nodes = workspace.nodes
        let wsId = workspace.id
        let wsDir = workspace.workingDirectory
        let rolePresets = appState.preferences.rolePresets

        // Filter out terminal nodes that need to be initialized
        let pending = nodes.filter { node -> Bool in
            guard case .terminal(let tc) = node.content else { return false }
            guard tc.agentType != "orca_external" else { return false }
            return TerminalManager.shared.terminals[tc.id] == nil
        }
        guard !pending.isEmpty else { return }

        // Start all terminals in parallel (PTY fork itself is lightweight and does not block the UI thread)
        for node in pending {
            guard case .terminal(let tc) = node.content else { continue }
            guard TerminalManager.shared.terminals[tc.id] == nil else { continue }
            guard TerminalManager.shared.providers[tc.id] == nil else { continue }

            let role: RolePreset? = tc.assignedRoleId.flatMap { roleId in
                rolePresets.first { $0.id == roleId }
            }
            let baseDir = tc.workingDirectory.isEmpty ? wsDir : tc.workingDirectory
            // When there is a role, start it in the role subdirectory. Make sure CLAUDE.md/role.json exists before starting it.
            let startDir: String
            if let role {
                RoleInjector.shared.prepareRoleDirectory(roleId: role.id, rolePreset: role, workingDirectory: baseDir)
                startDir = RoleInjector.shared.roleDirPath(roleId: role.id, workingDirectory: baseDir)
            } else {
                startDir = baseDir
            }
            _ = TerminalManager.shared.createTerminal(
                id: tc.id,
                command: tc.command,
                workingDirectory: startDir,
                workspaceId: wsId,
                roleName: role?.name,
                displayName: tc.name,
                agentType: tc.agentType
            )
        }
    }

    // MARK: - Floating toolbar operation

    // MARK: Note toolbar auxiliary method
    private func duplicateSelectedNodes() {
        for id in selectedNodeIds {
            guard let original = workspace.nodes.first(where: { $0.id == id }) else { continue }
            var copy = original
            copy.id = UUID()
            copy.frame = copy.frame.offsetBy(dx: 30, dy: 30)
            copy.zIndex = (workspace.nodes.map { $0.zIndex }.max() ?? 0) + 1
            if case .terminal(var tc) = copy.content {
                tc.id = UUID()
                copy.content = .terminal(tc)
            }
            workspace.addNode(copy)
        }
        Task { try? await workspace.save() }
    }

    private func deleteSelectedNodes() {
        let removableIds = selectedNodeIds.filter { !workspace.isExternallyManagedNode(id: $0) }
        for id in removableIds {
            workspace.removeNode(id: id)
        }
        selectedNodeIds.subtract(removableIds)
        if selectedNodeIds.isEmpty {
            selectedNodeScreenFrame = nil
        }
        Task { try? await workspace.save() }
    }

    private func lockSelectedNodes() {
        for id in selectedNodeIds {
            if let idx = workspace.nodes.firstIndex(where: { $0.id == id }) {
                let newLocked = !workspace.nodes[idx].isLocked
                workspace.nodes[idx].isLocked = newLocked
                NotificationCenter.default.post(
                    name: .canvasNodeLockChanged,
                    object: nil,
                    userInfo: ["nodeId": id, "isLocked": newLocked]
                )
            }
        }
        Task { try? await workspace.save() }
    }

    /// Edit the selected node (pop up the editing sheet in Terminal)
    private func editSelectedNode() {
        guard let firstId = selectedNodeIds.first,
              let node = workspace.nodes.first(where: { $0.id == firstId }),
              case .terminal(let tc) = node.content else { return }
        terminalToEdit = (nodeId: firstId, content: tc)
    }

    /// Create a connection starting from the selected node
    private func startConnectionFromSelected() {
        guard !selectedNodeIds.isEmpty else { return }
        isConnecting = true
    }

    /// All connections to currently selected node (used for toolbar badges)
    private var selectedNodeConnections: [ToolbarConnectionItem] {
        guard let nodeId = selectedNodeIds.first else { return [] }
        var items: [ToolbarConnectionItem] = []

        func peerName(_ peerId: UUID) -> String {
            guard let node = workspace.nodes.first(where: { $0.id == peerId }) else { return "Node" }
            switch node.content {
            case .terminal(let tc): return tc.name
            case .stickyNote(let nc):
                return nc.fileName.map { $0.hasSuffix(".md") ? String($0.dropLast(3)) : $0 } ?? "node.default_name.note".localized
            case .portal(let pc): return pc.name
            default: return "Node"
            }
        }

        func peerIcon(_ peerId: UUID) -> String {
            guard let node = workspace.nodes.first(where: { $0.id == peerId }) else { return "circle" }
            switch node.content {
            case .terminal: return "terminal"
            case .stickyNote: return "note.text"
            case .portal: return "globe"
            default: return "circle"
            }
        }

        for c in workspace.connections where c.terminalIdA == nodeId || c.terminalIdB == nodeId {
            let peerId = c.terminalIdA == nodeId ? c.terminalIdB : c.terminalIdA
            items.append(ToolbarConnectionItem(id: c.id, peerName: peerName(peerId), peerIcon: peerIcon(peerId)))
        }
        for c in workspace.noteConnections where c.terminalId == nodeId || c.noteNodeId == nodeId {
            let peerId = c.terminalId == nodeId ? c.noteNodeId : c.terminalId
            items.append(ToolbarConnectionItem(id: c.id, peerName: peerName(peerId), peerIcon: peerIcon(peerId)))
        }
        for c in workspace.portalConnections where c.terminalId == nodeId || c.portalNodeId == nodeId {
            let peerId = c.terminalId == nodeId ? c.portalNodeId : c.terminalId
            items.append(ToolbarConnectionItem(id: c.id, peerName: peerName(peerId), peerIcon: peerIcon(peerId)))
        }
        for c in workspace.portalToPortalConnections where c.portalIdA == nodeId || c.portalIdB == nodeId {
            let peerId = c.portalIdA == nodeId ? c.portalIdB : c.portalIdA
            items.append(ToolbarConnectionItem(id: c.id, peerName: peerName(peerId), peerIcon: peerIcon(peerId)))
        }
        for c in workspace.noteToNoteConnections where c.noteNodeIdA == nodeId || c.noteNodeIdB == nodeId {
            let peerId = c.noteNodeIdA == nodeId ? c.noteNodeIdB : c.noteNodeIdA
            items.append(ToolbarConnectionItem(id: c.id, peerName: peerName(peerId), peerIcon: peerIcon(peerId)))
        }
        return items
    }

    /// Delete a single connection
    private func deleteConnection(id connId: UUID) {
        workspace.connections.removeAll { $0.id == connId }
        workspace.noteConnections.removeAll { $0.id == connId }
        workspace.portalConnections.removeAll { $0.id == connId }
        workspace.portalToPortalConnections.removeAll { $0.id == connId }
        workspace.noteToNoteConnections.removeAll { $0.id == connId }
        ConnectionManager.shared.disconnect(id: connId)
        Task { try? await workspace.save() }
    }

    /// Toggle Maestro mode for endpoints
    private func toggleMaestroMode(nodeId: UUID?) {
        guard let nodeId,
              let idx = workspace.nodes.firstIndex(where: { $0.id == nodeId }),
              case .terminal(var tc) = workspace.nodes[idx].content else { return }
        tc.isManager = !tc.isManager
        let newContent = NodeContent.terminal(tc)
        workspace.nodes[idx].content = newContent
        NotificationCenter.default.post(
            name: .canvasNodeContentChanged,
            object: nil,
            userInfo: ["nodeId": nodeId, "content": newContent]
        )
        Task { try? await workspace.save() }
    }

    /// The existing role ID of the node where the role is currently to be assigned
    private var currentAssignedRoleId: UUID? {
        guard let nodeId = assignRoleNodeId,
              let node = workspace.nodes.first(where: { $0.id == nodeId }),
              case .terminal(let tc) = node.content else { return nil }
        return tc.assignedRoleId
    }

    /// Check whether assignedRoleId changes when EditTerminalSheet dismisses. If it changes, restart the terminal.
    private func handleRoleChangeIfNeeded(nodeId: UUID, oldContent: NodeContent, newContent: NodeContent) {
        guard case .terminal(let oldTc) = oldContent,
              case .terminal(let newTc) = newContent else { return }
        guard oldTc.assignedRoleId != newTc.assignedRoleId else { return }

        if let newRoleId = newTc.assignedRoleId,
           let role = appState.preferences.rolePresets.first(where: { $0.id == newRoleId }) {
            let workDir = newTc.workingDirectory.isEmpty ? workspace.workingDirectory : newTc.workingDirectory
            RoleInjector.shared.prepareRoleDirectory(roleId: role.id, rolePreset: role, workingDirectory: workDir)
            let roleDir = RoleInjector.shared.roleDirPath(roleId: role.id, workingDirectory: workDir)
            restartTerminalWithRole(terminalId: newTc.id, role: role, workingDirectory: roleDir)
        } else {
            // assignedRoleId == nil or role no longer exists (orphan id), restart back to the original directory
            let dir = newTc.workingDirectory.isEmpty ? workspace.workingDirectory : newTc.workingDirectory
            restartTerminalInOriginalDir(terminalId: newTc.id, workingDirectory: dir)
        }
    }

    /// Assign roles to endpoints and call RoleInjector to write files
    private func applyRole(_ role: RolePreset, toNodeId nodeId: UUID?) {
        guard let nodeId,
              let idx = workspace.nodes.firstIndex(where: { $0.id == nodeId }),
              case .terminal(var tc) = workspace.nodes[idx].content else { return }
        tc.assignedRoleId = role.id
        tc.color = role.color
        tc.icon = role.icon
        let newContent = NodeContent.terminal(tc)
        workspace.nodes[idx].content = newContent
        NotificationCenter.default.post(
            name: .canvasNodeContentChanged,
            object: nil,
            userInfo: ["nodeId": nodeId, "content": newContent]
        )

        // Write CLAUDE.md/AGENTS.md to roles directory
        let workDir = tc.workingDirectory.isEmpty ? workspace.workingDirectory : tc.workingDirectory
        RoleInjector.shared.prepareRoleDirectory(
            roleId: role.id,
            rolePreset: role,
            workingDirectory: workDir
        )

        // Restart the terminal and start it in the role directory (the agent learns the real workspace after reading CLAUDE.md)
        let roleDir = RoleInjector.shared.roleDirPath(roleId: role.id, workingDirectory: workDir)
        restartTerminalWithRole(terminalId: tc.id, role: role, workingDirectory: roleDir)

        Task { try? await workspace.save() }
    }

    /// Cancel role assignment of endpoint
    private func unassignRole(fromNodeId nodeId: UUID?) {
        guard let nodeId,
              let idx = workspace.nodes.firstIndex(where: { $0.id == nodeId }),
              case .terminal(var tc) = workspace.nodes[idx].content else { return }
        let oldRoleId = tc.assignedRoleId
        tc.assignedRoleId = nil
        // Restore default colors and icons
        tc.color = "#007AFF"
        tc.icon = "terminal"
        let unassignedContent = NodeContent.terminal(tc)
        workspace.nodes[idx].content = unassignedContent
        NotificationCenter.default.post(
            name: .canvasNodeContentChanged,
            object: nil,
            userInfo: ["nodeId": nodeId, "content": unassignedContent]
        )

        // Clean role directory (if no other terminal uses the role)
        if let roleId = oldRoleId {
            let stillUsed = workspace.nodes.contains { node in
                if case .terminal(let otherTc) = node.content, otherTc.assignedRoleId == roleId, node.id != nodeId {
                    return true
                }
                return false
            }
            if !stillUsed {
                // Do not delete role directory because other workspaces may use
            }
        }

        // Restart the terminal in the original working directory
        let dir = tc.workingDirectory.isEmpty ? workspace.workingDirectory : tc.workingDirectory
        restartTerminalInOriginalDir(terminalId: tc.id, workingDirectory: dir)

        Task { try? await workspace.save() }
    }

    /// Restart terminal and apply role
    private func restartTerminalWithRole(terminalId: UUID, role: RolePreset, workingDirectory: String) {
        // Remove the old terminal first
        TerminalManager.shared.removeTerminal(id: terminalId)

        // Find the corresponding TerminalContent
        guard let node = workspace.nodes.first(where: {
            if case .terminal(let tc) = $0.content { return tc.id == terminalId }
            return false
        }), case .terminal(let tc) = node.content else { return }

        // Recreate terminal (RoleInjector has written file on caller)
        _ = TerminalManager.shared.createTerminal(
            id: terminalId,
            command: tc.command,
            workingDirectory: workingDirectory,
            workspaceId: workspace.id,
            roleName: role.name,
            displayName: tc.name,
            agentType: tc.agentType
        )
    }

    /// Restart the terminal in the original working directory (after canceling the role)
    private func restartTerminalInOriginalDir(terminalId: UUID, workingDirectory: String) {
        TerminalManager.shared.removeTerminal(id: terminalId)

        guard let node = workspace.nodes.first(where: {
            if case .terminal(let tc) = $0.content { return tc.id == terminalId }
            return false
        }), case .terminal(let tc) = node.content else { return }

        let dir = workingDirectory.isEmpty ? workspace.workingDirectory : workingDirectory

        _ = TerminalManager.shared.createTerminal(
            id: terminalId,
            command: tc.command,
            workingDirectory: dir,
            workspaceId: workspace.id,
            roleName: nil,
            displayName: tc.name,
            agentType: tc.agentType
        )
    }

    /// Get the content type of the currently selected node (when single selection)
    private var selectedNodeContentType: String? {
        guard selectedNodeIds.count == 1,
              let firstId = selectedNodeIds.first,
              let node = workspace.nodes.first(where: { $0.id == firstId }) else { return nil }
        return contentTypeName(node.content)
    }

    /// FileTree node: shown in Finder
    private func revealFileTreeInFinder() {
        guard let firstId = selectedNodeIds.first,
              let node = workspace.nodes.first(where: { $0.id == firstId }),
              case .fileTree(let fc) = node.content else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: fc.rootPath)
    }

    /// FileTree node: change root directory
    private func changeFileTreeRoot() {
        guard let firstId = selectedNodeIds.first,
              let idx = workspace.nodes.firstIndex(where: { $0.id == firstId }),
              case .fileTree(let fc) = workspace.nodes[idx].content else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: fc.rootPath)
        panel.prompt = "panel.select_directory".localized
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let newPath = url.path

        // Update data model
        var content = fc
        content.rootPath = newPath
        content.name = url.lastPathComponent
        let newContent = NodeContent.fileTree(content)
        workspace.nodes[idx].content = newContent
        NotificationCenter.default.post(
            name: .canvasNodeContentChanged,
            object: nil,
            userInfo: ["nodeId": firstId, "content": newContent]
        )

        // Notify CanvasNodeRenderer to refresh view (via save + reload)
        Task { try? await workspace.save() }

        // Send notification to let renderer update file tree view
        NotificationCenter.default.post(
            name: .fileTreeRootChanged,
            object: nil,
            userInfo: ["nodeId": firstId, "newPath": newPath]
        )
    }
}

// MARK: - Node type assist

private func contentTypeName(_ content: NodeContent) -> String {
    switch content {
    case .terminal:  return "terminal"
    case .stickyNote: return "stickyNote"
    case .portal:    return "portal"
    case .fileTree:  return "fileTree"
    case .text:      return "text"
    case .shape:     return "shape"
    case .stroke:    return "stroke"
    case .freehand:  return "freehand"
    }
}

// MARK: - Empty canvas placeholder

struct EmptyCanvasPlaceholder: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.dashed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("onboarding.from_here")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("workspace.sidebar.create_hint")
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Autosave Modifier

/// Autosave modifier: scheduled save every 30 seconds + save immediately when view disappears (NFR5 compliant)
private struct AutosaveModifier: ViewModifier {
    let workspace: WorkspaceManager
    /// 30 second timer
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    func body(content: Content) -> some View {
        content
            .onReceive(timer) { _ in
                Task { try? await workspace.save() }
            }
            .onDisappear {
                Task { try? await workspace.save() }
            }
    }
}

private extension View {
    func autosave(workspace: WorkspaceManager) -> some View {
        modifier(AutosaveModifier(workspace: workspace))
    }
}

// MARK: - Stroke Point Drag Modifier

/// Handle workspace persistence at the end of stroke control point dragging.
/// Independently extracted as ViewModifier to avoid Swift compiler type inference timeout caused by too long body chain.
private struct StrokePointDragModifier: ViewModifier {
    @Bindable var workspace: WorkspaceManager

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .strokePointDragDidEnd)) { notif in
                guard let id = notif.userInfo?["nodeId"] as? UUID,
                      let nodeContent = notif.userInfo?["content"] as? NodeContent,
                      let idx = workspace.nodes.firstIndex(where: { $0.id == id }) else { return }
                workspace.nodes[idx].content = nodeContent
                if let newFrame = notif.userInfo?["frame"] as? CGRect {
                    workspace.nodes[idx].frame = newFrame
                }
                Task { try? await workspace.save() }
            }
    }
}

private extension View {
    func strokePointDragHandler(workspace: WorkspaceManager) -> some View {
        modifier(StrokePointDragModifier(workspace: workspace))
    }
}

// MARK: - Conditional Safe Area

/// Determine whether to ignore the top safe area based on conditions.
/// Ignored when not full screen (the toolbar extends to the title bar); not ignored when full screen (the toolbar is displayed normally within the visible area).
private struct ConditionalIgnoreSafeAreaTop: ViewModifier {
    let ignore: Bool

    func body(content: Content) -> some View {
        if ignore {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
    }
}
