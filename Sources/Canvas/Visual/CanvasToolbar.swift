import SwiftUI
import AppKit

/// Canvas top toolbar
/// Support new Terminal/Note/Portal/FileTree nodes (drag and drop drawing mode), and connection tools
struct CanvasToolbar: View {
    let workspace: WorkspaceManager
    @Binding var isConnecting: Bool
    /// Currently selected drawing tool (nil = selection mode, not drawing)
    @Binding var activeDrawingTool: String?
    /// The currently selected drawing sub-tool (shape secondary tool)
    @Binding var activeShapeSubtool: String
    @Environment(AppState.self) private var appState

    @State private var showTerminalSheet = false
    @State private var showNoteCreated = false
    @State private var showPortalSheet = false
    @State private var showFileTreeSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Centered floating toolbar (refer to Maestri product design)
            HStack(spacing: 0) {
                Spacer()

                HStack(spacing: 2) {
                    // 1. Selection tool (mouse pointer)
                    FloatingToolButton(
                        icon: "cursorarrow",
                        tooltip: "canvas.toolbar.select".localized,
                        isActive: activeDrawingTool == nil && !isConnecting
                    ) {
                        activeDrawingTool = nil
                        isConnecting = false
                    }

                    // 2. Terminal tool
                    FloatingToolButton(
                        icon: "apple.terminal",
                        tooltip: "canvas.toolbar.terminal".localized,
                        isActive: activeDrawingTool == "terminal"
                    ) {
                        toggleDrawingTool("terminal")
                    }

                    // 3. Note tool
                    FloatingToolButton(
                        icon: "text.document",
                        tooltip: "canvas.toolbar.note".localized,
                        isActive: activeDrawingTool == "stickyNote"
                    ) {
                        toggleDrawingTool("stickyNote")
                    }

                    // 4. Link file (placeholder, not yet implemented)
                    FloatingToolButton(
                        icon: "paperclip",
                        tooltip: "canvas.toolbar.text".localized,
                        isActive: activeDrawingTool == "linkedFile"
                    ) {
                        toggleDrawingTool("linkedFile")
                    }

                    // 5. FileTree tool
                    FloatingToolButton(
                        icon: "folder",
                        tooltip: "canvas.toolbar.filetree".localized,
                        isActive: activeDrawingTool == "fileTree"
                    ) {
                        toggleDrawingTool("fileTree")
                    }

                    // 6. Portal tools
                    FloatingToolButton(
                        icon: "globe",
                        tooltip: "canvas.toolbar.portal".localized,
                        isActive: activeDrawingTool == "portal"
                    ) {
                        toggleDrawingTool("portal")
                    }

                    // TODO: Text Label Tool - Temporarily hidden until subsequent iterations implement complete interaction and styling of text label nodes
                    // FloatingToolButton(
                    //     icon: "textformat",
                    //     tooltip: "canvas.toolbar.format".localized,
                    //     isActive: activeDrawingTool == "text"
                    // ) {
                    //     toggleDrawingTool("text")
                    // }

                    // 8. Graphic Tools (Rectangle)
                    FloatingToolButton(
                        icon: "pencil.and.scribble",
                        tooltip: "canvas.toolbar.shape".localized,
                        isActive: activeDrawingTool == "shape"
                    ) {
                        toggleDrawingTool("shape")
                    }
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

                Spacer()
            }

            if activeDrawingTool == "shape" {
                HStack(spacing: 0) {
                    Spacer()
                    ShapeSubtoolbar { subtool in
                        activeShapeSubtool = subtool
                    }
                    Spacer()
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.15), value: activeDrawingTool)
            }
        }
        .sheet(isPresented: $showTerminalSheet) {
            NewTerminalSheet(
                initialPresets: appState.preferences.agentPresets.filter { $0.isActive },
                initialRoles: appState.preferences.rolePresets,
                defaultWorkingDirectory: workspace.workingDirectory
            ) { preset, role, isManager, workDir in
                createTerminal(preset: preset, role: role, isManager: isManager, workingDirectory: workDir)
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(isPresented: $showPortalSheet) {
            NewPortalSheet { name, url in
                createPortal(name: name, url: url)
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(isPresented: $showFileTreeSheet) {
            NewFileTreeSheet(defaultPath: workspace.workingDirectory) { path in
                createFileTree(rootPath: path)
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
    }

    private func toggleDrawingTool(_ tool: String) {
        if activeDrawingTool == tool {
            activeDrawingTool = nil
        } else {
            activeDrawingTool = tool
            isConnecting = false
        }
    }

    // MARK: - Create node

    private func createTerminal(preset: AgentPreset, role: RolePreset?, isManager: Bool = false, workingDirectory: String? = nil) {
        let dir = workingDirectory ?? workspace.workingDirectory
        var tc = TerminalContent(
            name: nextTerminalName(baseName: preset.name),
            agentType: preset.agentType,
            command: preset.command,
            workingDirectory: dir
        )
        tc.isManager = isManager
        let origin = nextNodeOrigin(width: 600, height: 400)
        // Use tc.id as CanvasNode.id, ensuring node.id == tc.id (avoids desynchronization when removingNode)
        let node = CanvasNode(
            id: tc.id,
            frame: CGRect(origin: origin, size: CGSize(width: 600, height: 400)),
            content: .terminal(tc)
        )
        addNode(node)
        let wsId = workspace.id
        let startDir: String
        if let role {
            startDir = RoleInjector.shared.prepareRoleDirectory(
                roleId: role.id, rolePrompt: role.prompt, workingDirectory: dir
            )
        } else {
            startDir = dir
        }
        Task { @MainActor in
            _ = TerminalManager.shared.createTerminal(
                id: tc.id,
                command: preset.command,
                workingDirectory: startDir,
                workspaceId: wsId,
                roleName: role?.name,
                displayName: tc.name,
                agentType: preset.agentType
            )
        }
    }

    private func createNote() {
        let name = nextNodeName(for: "stickyNote")
        let fileName = "\(name).md"
        let nc = StickyNoteContent(name: name)
        var mutableNC = nc
        mutableNC.fileName = fileName
        let origin = nextNodeOrigin(width: 260, height: 200)
        let node = CanvasNode(
            frame: CGRect(origin: origin, size: CGSize(width: 260, height: 200)),
            content: .stickyNote(mutableNC)
        )
        // Create file
        let filePath = PersistenceManager.shared.notesDirURL(workspaceId: workspace.id)
            .appendingPathComponent(fileName).path
        try? FileManager.default.createDirectory(
            atPath: PersistenceManager.shared.notesDirURL(workspaceId: workspace.id).path,
            withIntermediateDirectories: true
        )
        try? "".write(toFile: filePath, atomically: true, encoding: .utf8)
        NoteRegistry.shared.register(name: name, filePath: filePath, nodeId: node.id)
        addNode(node)
    }

    private func createPortal(name: String, url: String) {
        let portalName = name.isEmpty ? nextNodeName(for: "portal") : name
        let pc = PortalContent(name: portalName, url: url)
        let origin = nextNodeOrigin(width: 800, height: 600)
        let node = CanvasNode(
            frame: CGRect(origin: origin, size: CGSize(width: 800, height: 600)),
            content: .portal(pc)
        )
        addNode(node)
    }

    private func createFileTree(rootPath: String? = nil) {
        let path = rootPath ?? workspace.workingDirectory
        let fc = FileTreeContent(name: URL(fileURLWithPath: path).lastPathComponent, rootPath: path)
        let origin = nextNodeOrigin(width: 300, height: 500)
        let node = CanvasNode(
            frame: CGRect(origin: origin, size: CGSize(width: 300, height: 500)),
            content: .fileTree(fc)
        )
        addNode(node)
    }

    private func addNode(_ node: CanvasNode) {
        workspace.addNode(node)
        // Save immediately (without autosave delay)
        Task { try? await workspace.save() }
        // Spotlight update
        SpotlightIndexer.shared.indexWorkspaceNodes(
            workspaceId: workspace.id,
            nodes: [node],
            workingDirectory: workspace.workingDirectory
        )
    }

    private func nextNodeOrigin(width: CGFloat, height: CGFloat) -> CGPoint {
        // Offset based on existing node count to avoid complete overlap
        let count = CGFloat(workspace.nodes.count)
        let col = Int(count) % 4
        let row = Int(count) / 4
        let baseX = Constants.canvasInitialOrigin.x + 100
        let baseY = Constants.canvasInitialOrigin.y + 100
        let stepX = width + 30
        let stepY = height + 60
        return CGPoint(x: baseX + CGFloat(col) * stepX, y: baseY + CGFloat(row) * stepY)
    }

    /// Generate a unique terminal name based on baseName, always with a serial number, such as "Claude Code #1"
    private func nextTerminalName(baseName: String) -> String {
        let existingNames = Set(workspace.nodes.compactMap { node -> String? in
            guard case .terminal(let tc) = node.content else { return nil }
            return tc.name
        })
        var index = 1
        while true {
            let candidate = "\(baseName) #\(index)"
            if !existingNames.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// Check for duplication based on existing node names and generate non-conflicting incremental number names (no duplication will occur after deleting nodes)
    private func nextNodeName(for nodeType: String) -> String {
        let prefix: String
        switch nodeType {
        case "portal": prefix = "Portal"
        case "stickyNote": prefix = "Note"
        case "fileTree": prefix = "File Tree"
        case "text": prefix = "Text"
        case "shape": prefix = "Shape"
        default: prefix = "Node"
        }

        let existingNames: Set<String> = Set(workspace.nodes.compactMap { node in
            switch (nodeType, node.content) {
            case ("portal", .portal(let pc)): return pc.name
            case ("stickyNote", .stickyNote(let nc)):
                return nc.fileName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            case ("fileTree", .fileTree(let fc)): return fc.name
            default: return nil
            }
        })

        var index = 1
        while true {
            let candidate = "\(prefix) #\(index)"
            if !existingNames.contains(candidate) { return candidate }
            index += 1
        }
    }
}

// MARK: - Floating toolbar button

private struct FloatingToolButton: View {
    let icon: String
    var tooltip: String = ""
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var showTooltip = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color(white: 0.2))
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.1) : (isHovered ? Color.black.opacity(0.06) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .background(
            HoverTrackingView { hovering in
                if hovering {
                    if !isHovered {
                        isHovered = true
                        hoverTask = Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            guard !Task.isCancelled else { return }
                            showTooltip = true
                        }
                    }
                } else {
                    isHovered = false
                    hoverTask?.cancel()
                    hoverTask = nil
                    showTooltip = false
                }
            }
        )
        .overlay(alignment: .bottom) {
            if showTooltip && !tooltip.isEmpty {
                Text(tooltip)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.15))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(white: 0.88), lineWidth: 0.5)
                    )
                    .fixedSize()
                    .offset(y: 34)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                    .zIndex(1000)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showTooltip)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
}
