import AppKit
import SwiftUI

// MARK: - Node canvas constant (replaces static constant in BaseNodeView)
enum CanvasNodeConstants {
    static let headerHeight: CGFloat = 32
    static let footerHeight: CGFloat = 26
    static let minNodeWidth: CGFloat = 160
    static let minNodeHeight: CGFloat = 80
    static let resizeHandleSize: CGFloat = 12
    static let cornerRadius: CGFloat = 10
    static let selectionOutset: CGFloat = 3
}

// MARK: - Drag and drop target Environment Key

private struct DropTargetNodeIdKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var dropTargetNodeId: UUID? {
        get { self[DropTargetNodeIdKey.self] }
        set { self[DropTargetNodeIdKey.self] = newValue }
    }
}

// MARK: - CanvasNodesView
/// NSHostingView subclass that serves as a SwiftUI container for all nodes.
/// hitTest returns self by default (does not penetrate the inner SwiftUI view to the AppKit layer),
/// Naturally implement Maestri's SwiftUIGestureBlocker effect.
/// All mouse/wheel events are transparently transmitted to the parent view CanvasViewportView for unified processing.
/// Exception: FileTree node's NavBar area (List/Grid toggle, forward/back, etc. buttons) allows SwiftUI to be responsive.
final class CanvasNodesView: NSHostingView<CanvasNodesSwiftUIView> {

    /// Inject canvas reference for coordinate judgment of fileTree NavBar area
    weak var canvas: CanvasViewportView?

    // MARK: - Responder

    /// NSHostingView default acceptsFirstResponder = false,
    /// As a result, self is not in the responder chain. NSMenu thinks that the target cannot respond to the action and grays out all menu items.
    override var acceptsFirstResponder: Bool { true }

    // MARK: - hitTest interception

    /// Always return self to ensure all mouse events are routed through CanvasNodesView.mouseDown.
    /// NSHostingView may return nil when SwiftUI internally sets allowsHitTesting(false).
    /// Programming that causes events to bypass this view and directly reach CanvasViewportView, fileTree and other nodes
    /// The click forwarding logic fails (the expand button, row selection, and double-click navigation do not respond).
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept when the click is within the bounds of this view
        guard bounds.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas else {
            nextResponder?.mouseDown(with: event)
            return
        }

        let loc = canvas.convert(event.locationInWindow, from: nil)

        // Portal node navigation bar button processing (back/forward/refresh)
        if handlePortalNavBarClick(at: loc, event: event, canvas: canvas) {
            nextResponder?.mouseDown(with: event)  // Allow canvas to continue selecting nodes
            return
        }

        if let (nodeId, hitKind) = fileTreeHitKind(at: loc, canvas: canvas) {
            switch hitKind {
            case .navBar:
                // NavBar area: accurately distribute button actions; only consume events when the menu pops up,
                // In other cases (back/forward/blank title) continue to be forwarded to canvas to complete selection/drag.
                if handleNavBarClick(nodeId: nodeId, loc: loc, event: event, canvas: canvas) {
                    return
                }
            case .content:
                // NSOutlineView/NSCollectionView area: select nodes first, then forward events
                canvas.selectFileTreeNode(at: loc, modifiers: event.modifierFlags)
                forwardMouseDownToFileTreeContent(nodeId: nodeId, event: event)
                return
            case .swiftUI:
                // Pure SwiftUI areas (search bar, etc.):
                // super.mouseDown cannot route events to SwiftUI TextField because the node has allowsHitTesting(false) set.
                // So manually find the NSTextField under the click location and activate the first responder.
                canvas.selectFileTreeNode(at: loc, modifiers: event.modifierFlags)
                let windowPoint = event.locationInWindow
                let selfPoint = self.convert(windowPoint, from: nil)
                if let targetTextField = findTextField(at: selfPoint) {
                    self.window?.makeFirstResponder(targetTextField)
                } else {
                    super.mouseDown(with: event)
                }
                return
            }
        }

        nextResponder?.mouseDown(with: event)
    }

    /// Detect and handle button clicks (Back/Forward/Refresh) in the Portal node navigation bar.
    /// Returning true indicates that the navigation bar button was hit and processed, and the caller should continue to pass the event to canvas to complete the node selection.
    @discardableResult
    private func handlePortalNavBarClick(
        at loc: CGPoint, event: NSEvent, canvas: CanvasViewportView
    ) -> Bool {
        for node in canvas.currentNodes {
            guard case .portal = node.content else { continue }
            let sf = canvas.canvasRectToScreen(node.frame)
            guard sf.contains(loc) else { continue }

            // Navigation bar area: header(32) + navBar padding(6 top + 6 bottom) + navBar content(28) = about 72pt height after scaling
            // But PortalNavBarView is actually placed at the top of the content area, and content starts below header(32)
            // PortalNavBarView height = padding(6) + 28 + padding(6) = 40pt (canvas unit)
            let headerH  = CanvasNodeConstants.headerHeight * canvas.zoom
            let navBarH  = 40.0 * canvas.zoom
            let localY   = loc.y - sf.minY
            guard localY > headerH && localY <= headerH + navBarH else { continue }

            // x coordinate (restore zoom)
            // PortalNavBarView left capsule layout: padding(.horizontal, 8) + padding(.horizontal, 4) internal
            // = leading 12pt, then back(26) forward(26) refresh(26)
            let localX = (loc.x - sf.minX) / canvas.zoom
            let backRange    = 12.0...38.0  as ClosedRange<CGFloat>
            let forwardRange = 38.0...64.0  as ClosedRange<CGFloat>
            let refreshRange = 64.0...90.0  as ClosedRange<CGFloat>

            guard let wv = PortalWebViewStore.shared.webView(for: node.id) else { return false }

            if backRange.contains(localX) {
                wv.goBack()
                return true
            } else if forwardRange.contains(localX) {
                wv.goForward()
                return true
            } else if refreshRange.contains(localX) {
                if wv.isLoading { wv.stopLoading() } else { wv.reload() }
                return true
            }
            return false
        }
        return false
    }

    /// Handling navBar area clicks: accurately dispatch to back/forward/menu buttons based on x coordinate.
    /// Returning true means that the event has been consumed (menu pops up), false means that it should continue to be handed over to canvas for processing (select/drag).
    @discardableResult
    private func handleNavBarClick(
        nodeId: UUID, loc: CGPoint, event: NSEvent, canvas: CanvasViewportView
    ) -> Bool {
        guard let node = canvas.currentNodes.first(where: { $0.id == nodeId }) else { return false }
        let sf = canvas.canvasRectToScreen(node.frame)
        let localX    = (loc.x - sf.minX) / canvas.zoom
        let nodeWidth = node.frame.width

        // FileTreeNavigationBar layout (left to right):
        //   leading(8) + back(28) + Divider(~1) + forward(28) + title/Spacer + [git button] + menu capsule + trailing(8)
        //   Menu capsule content: list.dash(12) + spacing(4) + chevron.up.chevron.down(9) ≈ 25pt
        //   Add padding(.horizontal, 10) × 2 = 45pt wide, trailing padding 8pt
        //   → Capsule hot zone: menuMinX = nodeWidth - 53, menuMaxX = nodeWidth - 8
        let backRange    = 8.0...35.0 as ClosedRange<CGFloat>
        let forwardRange = 36.0...63.0 as ClosedRange<CGFloat>
        let menuMinX     = nodeWidth - 53.0
        let menuMaxX     = nodeWidth - 8.0

        if backRange.contains(localX) {
            FileTreeViewRegistry.shared.view(for: nodeId)?.onGoBack?()
            FileTreeGridViewRegistry.shared.view(for: nodeId)?.onGoBack?()
            return false   // Canvas is still allowed to select nodes after going back
        } else if forwardRange.contains(localX) {
            FileTreeViewRegistry.shared.view(for: nodeId)?.onGoForward?()
            FileTreeGridViewRegistry.shared.view(for: nodeId)?.onGoForward?()
            return false   // Still allowing canvas to select nodes after forwarding
        } else if localX >= menuMinX && localX <= menuMaxX {
            showNavBarMenu(nodeId: nodeId, event: event)
            return true    // The menu has popped up, consume events, no longer select/drag
        }
        return false       // Title/blank area: leave it to canvas drag and drop
    }

    /// Pop up the right menu of navBar (list/icon view switching, show hidden files, etc.).
    /// No longer forward mouseDown events, directly construct and pop up NSMenu, completely avoiding recursion.
    private func showNavBarMenu(nodeId: UUID, event: NSEvent) {
        guard let fileTreeView = FileTreeViewRegistry.shared.view(for: nodeId) else { return }

        let menu = NSMenu()

        let listItem = NSMenuItem(title: "filetree.menu.list_view".localized, action: #selector(menuSetListView(_:)), keyEquivalent: "")
        listItem.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        listItem.target = self
        listItem.representedObject = nodeId.uuidString
        menu.addItem(listItem)

        let gridItem = NSMenuItem(title: "filetree.menu.icon_view".localized, action: #selector(menuSetGridView(_:)), keyEquivalent: "")
        gridItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        gridItem.target = self
        gridItem.representedObject = nodeId.uuidString
        menu.addItem(gridItem)

        menu.addItem(.separator())

        let hiddenTitle = fileTreeView.showHiddenFiles ? "filetree.menu.hide_hidden_files".localized : "filetree.menu.show_hidden_files".localized
        let hiddenIcon  = fileTreeView.showHiddenFiles ? "eye.slash" : "eye"
        let hiddenItem = NSMenuItem(title: hiddenTitle, action: #selector(menuToggleHidden(_:)), keyEquivalent: "")
        hiddenItem.image = NSImage(systemSymbolName: hiddenIcon, accessibilityDescription: nil)
        hiddenItem.target = self
        hiddenItem.representedObject = nodeId.uuidString
        menu.addItem(hiddenItem)

        menu.addItem(.separator())

        let collapseItem = NSMenuItem(title: "filetree.menu.collapse_all".localized, action: #selector(menuCollapseAll(_:)), keyEquivalent: "")
        collapseItem.image = NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: nil)
        collapseItem.target = self
        collapseItem.representedObject = nodeId.uuidString
        menu.addItem(collapseItem)

        let popupPoint: NSPoint
        let anchorView: NSView
        if let canvas = canvas {
            popupPoint = canvas.convert(event.locationInWindow, from: nil)
            anchorView = canvas
        } else {
            popupPoint = self.convert(event.locationInWindow, from: nil)
            anchorView = self
        }
        menu.popUp(positioning: nil, at: popupPoint, in: anchorView)
    }

    @objc private func menuSetListView(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let nodeId = UUID(uuidString: idStr) else { return }
        NavBarMenuActionRelay.shared.setViewMode(.list, for: nodeId)
    }

    @objc private func menuSetGridView(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let nodeId = UUID(uuidString: idStr) else { return }
        NavBarMenuActionRelay.shared.setViewMode(.grid, for: nodeId)
    }

    @objc private func menuToggleHidden(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let nodeId = UUID(uuidString: idStr) else { return }
        NavBarMenuActionRelay.shared.toggleHidden(for: nodeId)
    }

    @objc private func menuCollapseAll(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let nodeId = UUID(uuidString: idStr) else { return }
        FileTreeViewRegistry.shared.view(for: nodeId)?.collapseAll()
    }

    /// Handle click events in the fileTree content area (programmatic API, does not rely on NSEvent forwarding)
    ///
    /// Since NSOutlineView is embedded through SwiftUI NSViewRepresentable, after scaleEffect transformation
    /// Its frame in the window coordinate system is inconsistent with the visual position, and forwarding NSEvent directly will cause coordinate errors.
    /// The local coordinates of the click within the content area are therefore calculated and the operation is performed via the programmatic API.
    private func forwardMouseDownToFileTreeContent(nodeId: UUID, event: NSEvent) {
        guard let canvas = canvas,
              let node = canvas.currentNodes.first(where: { $0.id == nodeId }) else { return }

        // Calculate the local coordinates of the click in the content area
        let canvasLoc = canvas.convert(event.locationInWindow, from: nil)
        let nodeScreenFrame = canvas.canvasRectToScreen(node.frame)
        let navBarH = (CanvasNodeConstants.headerHeight + 8) * canvas.zoom
        let contentTop = nodeScreenFrame.minY + navBarH

        // Coordinates relative to the upper left corner of the content area (reverting to zoom=1 space)
        let localX = (canvasLoc.x - nodeScreenFrame.minX) / canvas.zoom
        let localY = (canvasLoc.y - contentTop) / canvas.zoom
        let localPoint = NSPoint(x: localX, y: localY)

        // list mode: programmatically handle clicks
        if let fileTreeView = FileTreeViewRegistry.shared.view(for: nodeId) {
            fileTreeView.handleClickAtLocalPoint(localPoint, clickCount: event.clickCount)
            return
        }
        // grid mode: handling clicks programmatically
        if let gridView = FileTreeGridViewRegistry.shared.view(for: nodeId) {
            gridView.handleClickAtLocalPoint(localPoint, clickCount: event.clickCount)
            return
        }
    }

    /// Hit region type within fileTree node
    /// - navBar: Top navigation bar (back/forward/menu buttons), height = headerHeight(32) + 8 = 40
    /// - content: NSOutlineView / NSCollectionView area, needs to be forwarded to AppKit view
    /// - swiftUI: Areas rendered by SwiftUI such as the bottom search bar need to use super.mouseDown for normal routing.
    private enum FileTreeContentHitKind { case navBar, content, swiftUI }

    private func fileTreeHitKind(
        at loc: CGPoint,
        canvas: CanvasViewportView
    ) -> (UUID, FileTreeContentHitKind)? {
        // loc is the canvas's flipped coordinate system (isFlipped=true, y downward, minY=top edge)
        for node in canvas.currentNodes {
            guard case .fileTree = node.content else { continue }
            let sf = canvas.canvasRectToScreen(node.frame)
            guard sf.contains(loc) else { continue }
            let localFromTop = loc.y - sf.minY
            let navBarH    = (CanvasNodeConstants.headerHeight + 8) * canvas.zoom
            // Bottom SwiftUI area = search bar(40) + git panel(0 or 120, provided by extraBottomSwiftUIHeight)
            let extraH = FileTreeViewRegistry.shared.view(for: node.id)?.extraBottomSwiftUIHeight ?? 0
            let swiftUIBottomH = (40 + extraH) * canvas.zoom
            let localFromBottom = sf.height - (loc.y - sf.minY)
            if localFromTop <= navBarH {
                return (node.id, .navBar)
            } else if localFromBottom <= swiftUIBottomH {
                // Pure SwiftUI area at the bottom (search bar + git panel): use super.mouseDown normal route
                return (node.id, .swiftUI)
            } else {
                return (node.id, .content)
            }
        }
        return nil
    }

    /// Recursively search for NSTextField at specified coordinates (SwiftUI TextField is rendered using NSTextField underneath)
    private func findTextField(at point: CGPoint) -> NSTextField? {
        // Recursively find the NSTextField containing the point starting from self
        return findTextField(in: self, at: point)
    }

    private func findTextField(in view: NSView, at pointInSelf: CGPoint) -> NSTextField? {
        for subview in view.subviews.reversed() {
            let pointInSubview = subview.convert(pointInSelf, from: self)
            guard subview.bounds.contains(pointInSubview) else { continue }
            if let textField = subview as? NSTextField, textField.isEditable || textField.isSelectable {
                return textField
            }
            if let found = findTextField(in: subview, at: pointInSelf) {
                return found
            }
        }
        return nil
    }

    override func mouseUp(with event: NSEvent) {
        nextResponder?.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        nextResponder?.mouseDragged(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        nextResponder?.rightMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        nextResponder?.mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

// MARK: - CanvasNodesSwiftUIView
/// All nodes are laid out with .frame + .position in ZStack.
/// Set allowsHitTesting(false) for all, and the interaction is handled by the AppKit layer.
struct CanvasNodesSwiftUIView: View {
    /// Node list (the caller is responsible for sorting it in ascending order by zIndex to avoid repeated sorting in the body)
    let nodes: [CanvasNode]
    let canvasOrigin: CGPoint
    let zoom: CGFloat
    let selectedNodeIds: Set<UUID>
    let lockedNodeIds: Set<UUID>
    let workspace: WorkspaceManager?
    var dropTargetNodeId: UUID? = nil
    var onActivated: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onDuplicate: ((UUID) -> Void)?
    var onLockToggle: ((UUID, Bool) -> Void)?

    var body: some View {
        ZStack {
            ForEach(nodes, id: \.id) { node in
                let posX = (node.frame.midX - canvasOrigin.x) * zoom
                let posY = (node.frame.midY - canvasOrigin.y) * zoom
                nodeView(for: node)
                    // Rendering at original canvas size, content not zoom aware
                    .frame(width: node.frame.width, height: node.frame.height)
                    // scaleEffect scales from center to screen size, matching position center semantics
                    .scaleEffect(zoom)
                    // position is completely consistent with hitTestCanvas/canvasRectToScreen coordinate system
                    .position(x: posX, y: posY)
                    // All geometric transformations (frame/scaleEffect/position) are driven by the AppKit layer on a frame-by-frame basis,
                    // All animation propagation paths must be cut off (including scaleEffect animations triggered by zoom changes),
                    // Otherwise SwiftUI implicit animation will interpolate nodes to wrong coordinates and disappear when dragging/zooming.
                    // .animation(.none, value:) only overrides channels with specific values,
                    // Cutting off all transactions is the only reliable solution.
                    .transaction { $0.animation = nil }
                    // fileTree node's hitTesting event is forwarded manually by CanvasNodesView.mouseDown:
                    // If set to true, NSHostingView.hitTest will penetrate into the inner NSOutlineView.
                    // As a result, CanvasNodesView.mouseDown is not called and all routing logic becomes invalid.
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Ignore safe area and ensure SwiftUI .position() coordinates are fully aligned with AppKit hitTest coordinate system
        .ignoresSafeArea()
        .environment(\.dropTargetNodeId, dropTargetNodeId)
    }

    @ViewBuilder
    private func nodeView(for node: CanvasNode) -> some View {
        let isSelected = selectedNodeIds.contains(node.id)
        let isLocked = lockedNodeIds.contains(node.id)
        switch node.content {
        case .terminal(let tc):
            if tc.agentType == "orca_external" {
                OrcaTerminalNodeSwiftUIView(
                    nodeId: node.id,
                    fallbackContent: tc,
                    isSelected: isSelected,
                    isLocked: isLocked,
                    zoom: zoom,
                    onLockToggle: onLockToggle
                )
            } else {
                TerminalNodeSwiftUIView(
                    nodeId: node.id, content: tc, isSelected: isSelected, isLocked: isLocked,
                    zoom: zoom, nodeSize: node.frame.size, workspace: workspace,
                    onActivated: onActivated, onClose: onClose,
                    onRename: onRename, onDuplicate: onDuplicate, onLockToggle: onLockToggle
                )
            }
        case .stickyNote(let nc):
            NoteNodeSwiftUIView(
                nodeId: node.id, content: nc, isSelected: isSelected, isLocked: isLocked,
                zoom: zoom, workspace: workspace,
                onActivated: onActivated, onClose: onClose,
                onRename: onRename, onDuplicate: onDuplicate, onLockToggle: onLockToggle
            )
        case .portal(let pc):
            PortalNodeSwiftUIView(
                nodeId: node.id, content: pc, isSelected: isSelected, isLocked: isLocked,
                zoom: zoom,
                onActivated: onActivated, onClose: onClose,
                onRename: onRename, onDuplicate: onDuplicate, onLockToggle: onLockToggle
            )
        case .fileTree(let fc):
            FileTreeNodeSwiftUIView(
                nodeId: node.id, content: fc, isSelected: isSelected, isLocked: isLocked,
                zoom: zoom, workspace: workspace,
                onActivated: onActivated, onClose: onClose,
                onRename: onRename, onDuplicate: onDuplicate, onLockToggle: onLockToggle
            )
        case .text(let tc):
            TextNodeSwiftUIView(
                nodeId: node.id, content: tc, isSelected: isSelected, isLocked: isLocked,
                zoom: zoom,
                onActivated: onActivated, onClose: onClose,
                onRename: onRename, onDuplicate: onDuplicate, onLockToggle: onLockToggle
            )
        case .shape(let sc):
            ShapeNodeSwiftUIView(
                nodeId: node.id,
                content: sc,
                isSelected: isSelected,
                zoom: zoom,
                onContentChange: { newContent in
                    NotificationCenter.default.post(
                        name: .canvasNodeContentChanged,
                        object: nil,
                        userInfo: ["nodeId": node.id, "content": NodeContent.shape(newContent)]
                    )
                },
                onClose: onClose
            )
        case .stroke(let sc):
            StrokeNodeSwiftUIView(
                nodeId: node.id,
                content: sc,
                isSelected: isSelected,
                zoom: zoom,
                onContentChange: { newContent in
                    NotificationCenter.default.post(
                        name: .canvasNodeContentChanged,
                        object: nil,
                        userInfo: ["nodeId": node.id, "content": NodeContent.stroke(newContent)]
                    )
                },
                onClose: onClose
            )
        case .freehand(let fc):
            FreehandNodeSwiftUIView(
                nodeId: node.id,
                content: fc,
                isSelected: isSelected,
                zoom: zoom,
                onContentChange: { newContent in
                    NotificationCenter.default.post(
                        name: .canvasNodeContentChanged,
                        object: nil,
                        userInfo: ["nodeId": node.id, "content": NodeContent.freehand(newContent)]
                    )
                },
                onClose: onClose
            )
        }
    }
}
