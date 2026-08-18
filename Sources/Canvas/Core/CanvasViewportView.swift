import AppKit
import OSLog

/// Infinite canvas master NSView
/// - The origin of the coordinate system is approximately (9800, 8500), which is the "infinite" canvas center area
/// - Map to screen coordinates via origin + zoom transformation
/// - All nodes are added directly as child NSView
final class CanvasViewportView: NSView {
    private let logger = Logger.make(category: "CanvasViewportView")

    // MARK: - Status

    var canvasOrigin: CGPoint = Constants.canvasInitialOrigin {
        didSet {
            needsLayout = true
            backgroundView?.canvasOrigin = canvasOrigin
            drawingLayerView?.canvasOrigin = canvasOrigin
            drawingOverlayView?.canvasOrigin = canvasOrigin
            snapGuideView?.canvasOrigin = canvasOrigin
        }
    }

    var zoom: CGFloat = 1.0 {
        didSet {
            needsLayout = true
            backgroundView?.zoom = zoom
            drawingLayerView?.zoom = zoom
            drawingOverlayView?.zoom = zoom
            snapGuideView?.zoom = zoom
        }
    }

    /// Canvas background mode (read from Preferences)
    var backgroundMode: String = "dotGrid" {
        didSet {
            backgroundView?.backgroundMode = backgroundMode
        }
    }

    // MARK: - Layered View

    private var backgroundView: CanvasBackground?
    var drawingLayerView: DrawingLayerView?
    var drawingOverlayView: DrawingOverlayView?
    private(set) var snapGuideView: MagneticSnapGuideView?
    /// Connection overlay view (registered after being created by CanvasNodeRenderer, used to draw temporary connections)
    weak var connectionOverlayView: ConnectionOverlayView?

    /// Node view mapping (nodeId → NSView)
    private(set) var nodeViews: [UUID: NSView] = [:]
    /// Reverse mapping (NSView pointer → nodeId) for O(1) reverse lookup (hitTest hot path)
    var viewToNodeId: [ObjectIdentifier: UUID] = [:]

    /// Currently selected node ID set
    var selectedNodeIds: Set<UUID> = [] {
        didSet {
            // Invalidate hitTestCanvas cache when selected state changes (resize hot area range changes with selected state)
            _hitTestCachedPoint = CGPoint(x: -1e9, y: -1e9)
            updateSelectionVisuals()
            reportSelectionChange()
        }
    }

    // MARK: - hitTestCanvas result caching (to avoid repeated traversal when mouse moves at 60fps)
    var _hitTestCachedPoint: CGPoint = CGPoint(x: -1e9, y: -1e9)
    var _hitTestCachedResult: CanvasHitTestResult = .canvas
    static let _hitTestReuseThreshold: CGFloat = 2.0

    // MARK: - callback

    var onViewportChanged: ((CGPoint, CGFloat) -> Void)?
    /// Callback immediately after canvas pan/zoom (used for real-time re-rendering of the connection layer without going through the SwiftUI loop)
    var onViewportPanned: (() -> Void)?
    var onDeleteSelectedNodes: (() -> Void)?
    var onFocusSelectedNode: (() -> Void)?
    var onNodeJumpNumbersRequested: ((Bool) -> Void)? // true=show, false=hide
    /// Callback when the selected node changes (selected ID set, screen frame or nil of the first selected node)
    var onSelectionChanged: ((Set<UUID>, CGRect?) -> Void)?

    // MARK: - Connection tool status
    /// Connection starting point node ID (nil = connection not started)
    var connectingFromNodeId: UUID? = nil {
        didSet {
            needsDisplay = true
            syncTemporaryConnectionToOverlay()
        }
    }
    /// Current screen coordinates of the mouse when connecting (used to draw temporary connections)
    var connectionDragPoint: CGPoint? = nil {
        didSet {
            syncTemporaryConnectionToOverlay()
        }
    }
    /// Connection completion callback (input two node UUIDs, the caller determines the type)
    var onConnectionCreated: ((UUID, UUID) -> Void)? = nil

    /// Whether the connection tool is active (set by CanvasViewportRepresentable according to isConnecting)
    var isInConnectingMode: Bool = false {
        didSet {
            if isInConnectingMode { activateConnectionMode() }
            else { deactivateConnectionMode() }
        }
    }

    /// External activation of connected mode (called by CanvasViewportRepresentable when isConnecting=true)
    func activateConnectionMode() {
        // If the starting point of the connection has not been set but there is a selected node, the first selected node will be automatically set as the starting point.
        // (The L key entry has been set connectingFromNodeId in advance and will not be covered here)
        if connectingFromNodeId == nil, let firstSelected = selectedNodeIds.first {
            connectingFromNodeId = firstSelected
        }
        connectionDragPoint = nil
        needsDisplay = true
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(makeTrackingArea())
        NSCursor.crosshair.set()
    }

    func deactivateConnectionMode() {
        connectingFromNodeId = nil
        connectionDragPoint = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    /// Synchronize temporary connection state to ConnectionOverlayView (make sure temporary connections are drawn at the correct view level)
    func syncTemporaryConnectionToOverlay() {
        guard let overlay = connectionOverlayView else { return }
        if let fromId = connectingFromNodeId,
           let fromCanvasFrame = nodeCanvasFrames[fromId] {
            let screenFrame = canvasRectToScreen(fromCanvasFrame)
            overlay.tempConnectionFromFrame = screenFrame
            overlay.tempConnectionToPoint = connectionDragPoint
        } else {
            overlay.tempConnectionFromFrame = nil
            overlay.tempConnectionToPoint = nil
        }
    }

    /// Node content type query (registered by CanvasNodeRenderer after node creation)
    var nodeContentTypes: [UUID: String] = [:]  // nodeId → "terminal"|"stickyNote"|"portal"|"fileTree"

    /// Node SwiftUI container (created and registered by CanvasNodeRenderer for use by hitTestCanvas)
    weak var nodesHostingView: CanvasNodesView?

    /// Current canvas node list (synchronized by CanvasNodeRenderer.sync() for use by hitTestCanvas)
    /// Note: Sort cache update is automatically triggered when assignment. For high-frequency intra-frame frame updates, please use updateNodeFrameInPlace.
    var currentNodes: [CanvasNode] = [] {
        didSet {
            guard !_skipSortOnDidSet else { return }
            invalidateSortedNodesCache()
        }
    }
    /// Internal flag: currentNodes.didSet skips sorting when true (only used when frame changes)
    private var _skipSortOnDidSet = false

    /// Node cache pre-sorted by zIndex in ascending order (for use by SwiftUI rendering + hitTest to avoid O(n log n) per frame)
    private(set) var sortedNodesByZIndex: [CanvasNode] = []
    /// Node cache pre-sorted by zIndex descending (for use by hitTest front-to-back hit detection)
    private(set) var sortedNodesByZIndexDesc: [CanvasNode] = []
    /// Locking node ID collection (O(1) lookup cache, synchronized by invalidateSortedNodesCache + updateNodeLockedInPlace)
    /// Note: CanvasHitTesting extension (stand-alone file) needs to access this property and cannot be used private
    var lockedNodeIds: Set<UUID> = []

    /// Viewport crop cache: avoid layout() re-traversing all nodes every frame
    private var _cachedViewportNodes: [CanvasNode] = []
    private var _cachedViewportOrigin: CGPoint = .zero
    private var _cachedViewportZoom: CGFloat = 0
    private var _viewportCacheDirty: Bool = true
    /// Viewport cache tolerance: Do not re-crop when origin changes less than this value (canvas coordinates) to avoid small translation triggering O(n) traversal
    private static let viewportCacheTolerance: CGFloat = 50.0

    /// rootView throttling during pan/zoom: timestamp of last updated rootView
    /// Maximum 60fps during continuous pan/zoom (max one rootView update every 16ms) to avoid rebuilding the SwiftUI tree every frame
    private var _lastRootViewUpdateTime: TimeInterval = 0
    private static let rootViewUpdateMinInterval: TimeInterval = 1.0 / 60.0  // 60fps cap

    private func invalidateSortedNodesCache() {
        sortedNodesByZIndex = currentNodes.sorted { $0.zIndex < $1.zIndex }
        sortedNodesByZIndexDesc = sortedNodesByZIndex.reversed()
        lockedNodeIds = Set(currentNodes.compactMap { $0.isLocked ? $0.id : nil })
    }

    /// Force the viewport clipping cache to be invalidated (for CanvasNodeRenderer.sync() to be called after writing directly to rootView,
    /// Ensure that _cachedViewportNodes is consistent with the actual rendered node collection,
    /// Prevent new nodes from disappearing due to old whitelist filtering when dragging branches)
    func invalidateViewportCache() {
        _viewportCacheDirty = true
    }

    /// Only update the frame of the specified node (full sort is not triggered because zIndex has not changed)
    /// Used for high-frequency scenes such as dragging/resize to avoid O(n log n) + O(n) array copy per frame
    func updateNodeFrameInPlace(id: UUID, frame: CGRect) {
        _skipSortOnDidSet = true
        for i in currentNodes.indices where currentNodes[i].id == id {
            currentNodes[i].frame = frame
            break
        }
        _skipSortOnDidSet = false
        // Synchronously update the frame of the corresponding entry in the sort cache (zIndex remains unchanged, so the position remains unchanged)
        for i in sortedNodesByZIndex.indices where sortedNodesByZIndex[i].id == id {
            sortedNodesByZIndex[i].frame = frame
            break
        }
        for i in sortedNodesByZIndexDesc.indices where sortedNodesByZIndexDesc[i].id == id {
            sortedNodesByZIndexDesc[i].frame = frame
            break
        }
    }

    /// Update isLocked of the specified node in place (does not trigger full sort, synchronizes sort cache + O(1) locked set + viewport cache)
    func updateNodeLockedInPlace(id: UUID, isLocked: Bool) {
        _skipSortOnDidSet = true
        for i in currentNodes.indices where currentNodes[i].id == id {
            currentNodes[i].isLocked = isLocked
            break
        }
        _skipSortOnDidSet = false
        for i in sortedNodesByZIndex.indices where sortedNodesByZIndex[i].id == id {
            sortedNodesByZIndex[i].isLocked = isLocked
            break
        }
        for i in sortedNodesByZIndexDesc.indices where sortedNodesByZIndexDesc[i].id == id {
            sortedNodesByZIndexDesc[i].isLocked = isLocked
            break
        }
        // Incremental sync O(1) lookup cache (avoids full rebuild)
        if isLocked {
            lockedNodeIds.insert(id)
        } else {
            lockedNodeIds.remove(id)
        }
        _viewportCacheDirty = true
    }

    /// Update the content of the specified node in place (does not trigger full sort, synchronizes sort cache + viewport cache)
    func updateNodeContentInPlace(id: UUID, content: NodeContent) {
        _skipSortOnDidSet = true
        for i in currentNodes.indices where currentNodes[i].id == id {
            currentNodes[i].content = content
            break
        }
        _skipSortOnDidSet = false
        for i in sortedNodesByZIndex.indices where sortedNodesByZIndex[i].id == id {
            sortedNodesByZIndex[i].content = content
            break
        }
        for i in sortedNodesByZIndexDesc.indices where sortedNodesByZIndexDesc[i].id == id {
            sortedNodesByZIndexDesc[i].content = content
            break
        }
        _viewportCacheDirty = true
    }

    /// Update frames of multiple nodes in batches (without triggering full sort)
    func updateNodeFramesInPlace(frames: [UUID: CGRect]) {
        _skipSortOnDidSet = true
        for i in currentNodes.indices {
            if let newFrame = frames[currentNodes[i].id] {
                currentNodes[i].frame = newFrame
            }
        }
        _skipSortOnDidSet = false
        // Synchronously update the sort cache
        for i in sortedNodesByZIndex.indices {
            if let newFrame = frames[sortedNodesByZIndex[i].id] {
                sortedNodesByZIndex[i].frame = newFrame
            }
        }
        for i in sortedNodesByZIndexDesc.indices {
            if let newFrame = frames[sortedNodesByZIndexDesc[i].id] {
                sortedNodesByZIndexDesc[i].frame = newFrame
            }
        }
    }

    /// Frame-level callback during node dragging (the connection physics engine uses this to update the endpoint)
    /// Parameter: ID collection of the dragged node
    var onNodeFramesDuringDrag: ((Set<UUID>) -> Void)?

    /// option+drag copy node callback
    var onDuplicateNode: ((UUID) -> Void)?

    /// Right-click menu: Close node callback (set by CanvasNodeRenderer)
    var onContextMenuClose: ((UUID) -> Void)?
    /// Right-click menu: Rename node callback (set by CanvasNodeRenderer)
    var onContextMenuRename: ((UUID) -> Void)?
    /// Right-click menu: Lock/unlock node callback (set by CanvasNodeRenderer)
    var onContextMenuLockToggle: ((UUID) -> Void)?
    /// Right-click menu: Edit Terminal (EditTerminalSheet pops up)
    var onContextMenuEditTerminal: ((UUID) -> Void)?
    /// Right-click menu: Start connecting
    var onContextMenuConnect: ((UUID) -> Void)?
    /// Right-click menu: Assign role (Terminal exclusive)
    var onContextMenuAssignRole: ((UUID) -> Void)?
    /// Right-click menu: Switch Maestro mode (Terminal exclusive)
    var onContextMenuToggleMaestro: ((UUID) -> Void)?
    /// Right-click menu: Clear buffer (Terminal exclusive)
    var onContextMenuClearBuffer: ((UUID) -> Void)?
    /// Right-click menu: Reload terminal (Terminal exclusive)
    var onContextMenuReloadTerminal: ((UUID) -> Void)?
    /// Right-click menu: Copy terminal content (Terminal exclusive)
    var onContextMenuCopyTerminal: ((UUID) -> Void)?
    /// Right-click menu: Switch monitoring activities (Terminal exclusive)
    var onContextMenuToggleMonitor: ((UUID) -> Void)?

    // MARK: - Right-click menu callback in blank area of canvas

    /// Right-click menu: Create a node of the specified type (nodeType, canvasPoint) at the specified position on the canvas
    /// nodeType: "terminal", "stickyNote", "portal", "fileTree", "text", "linkedFile"
    var onCanvasContextCreateNode: ((String, CGPoint) -> Void)?
    /// Right-click menu: Create a terminal node at the specified position on the canvas (presetIndex, canvasPoint)
    var onCanvasContextCreateTerminal: ((Int, CGPoint) -> Void)?
    /// Right-click menu: Paste (canvas coordinates)
    var onCanvasContextPaste: ((CGPoint) -> Void)?
    /// Agent default list (for use by canvas right-click menu Terminal submenu)
    var agentPresets: [AgentPreset] = []

    /// Node zIndex change callback (node ID → new zIndex), persisted by WorkspaceManager
    var onNodeZIndexChanged: ((UUID, Int) -> Void)?

    // MARK: - Node level management

    /// Promote the specified node to the highest level (zIndex maximum value + 1)
    func bringNodesToFront(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let maxZ = currentNodes.map { $0.zIndex }.max() ?? 0

        // Determine whether the highest level has been exclusively occupied: the zIndex of the selected node is equal to maxZ,
        // And there are no other unselected nodes in maxZ (that is, the selected node is the only highest level)
        let otherNodesAtMax = currentNodes.contains { node in
            !ids.contains(node.id) && node.zIndex >= maxZ
        }
        let selectedAllAtMax = ids.allSatisfy { id in
            currentNodes.first { $0.id == id }?.zIndex == maxZ
        }
        if selectedAllAtMax && !otherNodesAtMax { return }

        let newZ = maxZ + 1
        var changed = false
        for i in currentNodes.indices {
            if ids.contains(currentNodes[i].id) {
                currentNodes[i].zIndex = newZ
                onNodeZIndexChanged?(currentNodes[i].id, newZ)
                changed = true
            }
        }
        // Rebuild the sort cache after level changes (subscript assignment does not trigger didSet and must be refreshed manually)
        if changed {
            invalidateSortedNodesCache()
            _viewportCacheDirty = true
            // Marking requires layout, ensuring that the next time layout() rebuilds the rootView with the new zIndex order
            needsLayout = true
            // Combined with updateSelectionVisuals() into a single delivery when triggered by the same RunLoop Turn,
            // Avoid double SwiftUI tree rebuild
            scheduleSelectionChangedNotification()
        }
    }

    // MARK: - Initialization

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawConcurrently = true
        allowedTouchTypes = [.indirect, .direct]
        registerDragTypes()
        setupNotificationObservers()
        setupBackgroundView()
        setupDrawingLayerView()
        setupSnapGuideView()
    }

    private func setupBackgroundView() {
        let bg = CanvasBackground(frame: bounds)
        bg.autoresizingMask = [.width, .height]
        bg.canvasOrigin = canvasOrigin
        bg.zoom = zoom
        bg.backgroundMode = backgroundMode
        addSubview(bg)
        backgroundView = bg
    }

    private func setupDrawingLayerView() {
        let drawLayer = DrawingLayerView(frame: bounds)
        drawLayer.autoresizingMask = [.width, .height]
        drawLayer.canvasOrigin = canvasOrigin
        drawLayer.zoom = zoom
        addSubview(drawLayer)
        drawingLayerView = drawLayer
    }

    private func setupSnapGuideView() {
        let snapView = MagneticSnapGuideView(frame: bounds)
        snapView.autoresizingMask = [.width, .height]
        addSubview(snapView)
        snapGuideView = snapView
    }

    private func setupNotificationObservers() {
        let nc = NotificationCenter.default
        notificationObservers.append(
            nc.addObserver(forName: .canvasJumpToOrigin, object: nil, queue: .main) { [weak self] notif in
                guard let self, let target = notif.userInfo?["origin"] as? CGPoint else { return }
                self.animateOriginTo(target)
            }
        )
        notificationObservers.append(
            nc.addObserver(forName: .canvasZoomIn, object: nil, queue: .main) { [weak self] _ in
                self?.zoomCanvas(delta: +Constants.canvasZoomStep)
            }
        )
        notificationObservers.append(
            nc.addObserver(forName: .canvasZoomOut, object: nil, queue: .main) { [weak self] _ in
                self?.zoomCanvas(delta: -Constants.canvasZoomStep)
            }
        )
        notificationObservers.append(
            nc.addObserver(forName: .canvasZoomReset, object: nil, queue: .main) { [weak self] _ in
                self?.zoomCanvas(toAbsolute: 1.0)
            }
        )
        notificationObservers.append(
            nc.addObserver(forName: .toggleCanvasZoom, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                let target: CGFloat = abs(zoom - 1.0) < 0.05 ? 0.5 : 1.0
                self.zoomCanvas(toAbsolute: target)
            }
        )
        notificationObservers.append(
            nc.addObserver(forName: .nextTerminal, object: nil, queue: .main) { [weak self] _ in
                self?.cycleTerminalFocus(forward: true)
            }
        )
        notificationObservers.append(
            nc.addObserver(forName: .prevTerminal, object: nil, queue: .main) { [weak self] _ in
                self?.cycleTerminalFocus(forward: false)
            }
        )
    }

    /// Smooth animation jumps to the specified canvas origin (for external calls such as Minimap clicks)
    func animateOriginTo(_ target: CGPoint, duration: TimeInterval = 0.3) {
        animateOrigin(from: canvasOrigin, to: target, startTime: CACurrentMediaTime(), duration: duration)
    }

    // MARK: - Coordinate system

    override var isFlipped: Bool { true }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ensure to be the first responder to receive gesture events (magnify/scrollWheel)
        // Only grab focus when the window has no attached sheet to avoid incorrect routing of keyboard events during Sheet pop-up.
        if window?.attachedSheet == nil {
            window?.makeFirstResponder(self)
        }
        installScrollEventMonitor()
    }

    // MARK: - Scroll Event Routing (Local Event Monitor)

    /// Interception of scrollWheel / magnify events via local event monitor
    /// Terminal content always receives scrolling under the pointer, regardless of selection.
    /// Other scrollable content receives the event when its node is selected;
    /// headers, footers, and empty space continue navigating the canvas.
    private var scrollMonitor: Any?
    var notificationObservers: [NSObjectProtocol] = []

    private func installScrollEventMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            return self.routeScrollEvent(event)
        }
    }

    private func routeScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard let myWindow = self.window else { return event }
        if let eventWindow = event.window, eventWindow !== myWindow { return event }

        // Use the frame of the canvas coordinate system to determine whether the mouse is within the scope of this view (canvas)
        // Avoid relying on hitTest + isDescendant (NSHostingView’s flipped view can lead to misjudgment)
        let locInCanvas = convert(event.locationInWindow, from: nil)
        guard bounds.contains(locInCanvas) else { return event }

        // magnify is always handled by canvas (pinch zoom canvas viewport)
        if event.type == .magnify {
            self.magnify(with: event)
            return nil
        }
        guard event.type == .scrollWheel else { return event }

        // Terminal content scrolls directly under the pointer, whether the node
        // is selected or not. Header/footer keep their canvas navigation behavior.
        if case .nodeContent(let nodeId, _) = hitTestCanvas(at: locInCanvas),
           let node = currentNodes.first(where: { $0.id == nodeId }),
           case .terminal = node.content {
            if let provider = TerminalManager.shared.providers[nodeId],
               let terminalView = provider.terminalView {
                terminalView.scrollWheel(with: event)
                return nil
            }
            if let scrollView = OrcaTerminalScrollViewRegistry.shared.scrollView(for: nodeId) {
                scrollView.scrollWheel(with: event)
                return nil
            }
        }

        // Use canvasFrame for hit testing: no dependence on nodeViews (NSHostingView is empty after migration)
        for selectedId in selectedNodeIds {
            guard let canvasFrame = nodeCanvasFrames[selectedId] else { continue }
            let screenFrame = canvasRectToScreen(canvasFrame)
            guard screenFrame.contains(locInCanvas) else { continue }
            // Exclude header area (header is at the top, flipped coordinate system minY = top edge)
            let headerScreenHeight = CanvasNodeConstants.headerHeight * zoom
            let contentScreenFrame = CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY + headerScreenHeight,
                width: screenFrame.width,
                height: screenFrame.height - headerScreenHeight
            )
            guard contentScreenFrame.contains(locInCanvas) else { break }
            // FileTree Node: Route scroll events to internal NSScrollView
            if let fileTreeView = FileTreeViewRegistry.shared.view(for: selectedId),
               let scrollView = fileTreeView.innerScrollView {
                scrollView.scrollWheel(with: event)
                return nil
            }
            // Note Node: Routing scroll events to NSTextView's ScrollView
            if let noteScrollView = NoteScrollViewRegistry.shared.scrollView(for: selectedId) {
                noteScrollView.scrollWheel(with: event)
                return nil
            }
            // Portal node: Route scroll events to WKWebView
            if let webView = PortalWebViewStore.shared.webView(for: selectedId) {
                webView.scrollWheel(with: event)
                return nil
            }
            // Other nodes: handed over to canvas for processing
            break
        }

        // Canvas handling: Panning
        self.scrollWheel(with: event)
        return nil
    }

    /// In the view tree (with root as the root and point as the bounds coordinate of the root),
    /// Find the most suitable scroll target:
    ///  1. NSScrollView (highest priority, including scrollView in Terminal)
    ///  2. Non-standard custom NSView (such as SwiftTerm TerminalView)
    /// NSHostingView (SwiftUI container, unreliable) is intentionally skipped.
    private func findScrollTarget(in root: NSView, at point: CGPoint) -> NSView? {
        guard root.bounds.contains(point), !root.isHidden, root.alphaValue > 0 else { return nil }
        // NSScrollView direct hit (highest priority, no further depth)
        if root is NSScrollView { return root }
        // NSHostingView: Exclude, do not recurse inside it (NSScrollView in SwiftUI view is not directly controllable)
        let rootTypeName = String(describing: type(of: root))
        if rootTypeName.contains("HostingView") || rootTypeName.contains("Hosting") { return nil }
        // Recursive subviews (depth first)
        for sub in root.subviews.reversed() {
            let subPoint = root.convert(point, to: sub)
            if let found = findScrollTarget(in: sub, at: subPoint) {
                return found
            }
        }
        // Non-standard NSView (such as SwiftTerm TerminalView, type != NSView && != NSClipView)
        if type(of: root) != NSView.self && !(root is NSClipView) {
            return root
        }
        return nil
    }

    private func handle(scrollOrMagnify event: NSEvent) {
        if event.type == .magnify {
            magnify(with: event)
        } else {
            scrollWheel(with: event)
        }
    }

    /// Check the owning node ID from the view (or its subview) (O(1) direct check + O(n) ancestor downgrade)
    private func nodeIdForHitView(_ hitView: NSView?) -> UUID? {
        nodeId(for: hitView)
    }


    deinit {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
        animationTimer?.invalidate()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Coordinate conversion

    func canvasToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - canvasOrigin.x) * zoom,
            y: (point.y - canvasOrigin.y) * zoom
        )
    }

    func screenToCanvas(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x / zoom + canvasOrigin.x,
            y: point.y / zoom + canvasOrigin.y
        )
    }

    func canvasRectToScreen(_ rect: CGRect) -> CGRect {
        let origin = canvasToScreen(rect.origin)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: rect.width * zoom,
            height: rect.height * zoom
        )
    }

    func screenRectToCanvas(_ rect: CGRect) -> CGRect {
        let origin = screenToCanvas(rect.origin)
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: rect.width / zoom,
            height: rect.height / zoom
        )
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        // Update CanvasNodesView's frame to fill the canvas viewport
        nodesHostingView?.frame = bounds

        // Update canvasOrigin/zoom of SwiftUI node tree to trigger node repositioning
        if let hostingView = nodesHostingView {
            let current = hostingView.rootView

            // Skip viewport cropping during dragging (without refiltering the visible set), but the real-time frame needs to be synchronized into the cache
            let isDragging: Bool
            switch interaction {
            case .draggingNode, .batchDragging, .resizingNode:
                isDragging = true
            default:
                isDragging = false
            }

            if isDragging {
                // Rebuilding _cachedViewportNodes with sortedNodesByZIndex as the authoritative source during dragging:
                // 1. Sort order follows latest zIndex (bringNodesToFront updated sortedNodesByZIndex)
                // 2. The frame takes the real-time value (updateNodeFrameInPlace has been synchronized to sortedNodesByZIndex)
                // 3. When the cache is dirty (such as when sync() has just added a new node), it must be pruned again, otherwise the new node will never be included in the whitelist.
                if _viewportCacheDirty {
                    _cachedViewportNodes = viewportCulledNodes()
                    _cachedViewportOrigin = canvasOrigin
                    _cachedViewportZoom = zoom
                    _viewportCacheDirty = false
                } else {
                    let cachedIds = Set(_cachedViewportNodes.map { $0.id })
                    _cachedViewportNodes = sortedNodesByZIndex.filter { cachedIds.contains($0.id) }
                }
            } else {
                // Only re-crop when viewport parameters change significantly or cache is explicitly invalidated (avoiding O(n) passes per frame)
                // Tolerance policy: small changes in origin (< 50 canvas units ≈ sub-node level translation) do not trigger recalculation
                let originDelta = hypot(_cachedViewportOrigin.x - canvasOrigin.x,
                                        _cachedViewportOrigin.y - canvasOrigin.y)
                let needsRecalc = _viewportCacheDirty
                    || _cachedViewportZoom != zoom
                    || currentNodes.count != _cachedViewportNodes.count
                    || originDelta > Self.viewportCacheTolerance
                if needsRecalc {
                    _cachedViewportNodes = viewportCulledNodes()
                    _cachedViewportOrigin = canvasOrigin
                    _cachedViewportZoom = zoom
                    _viewportCacheDirty = false
                }
            }

            // Rebuild rootView only when origin/zoom/visible nodes change (avoiding redundant assignments when there are no changes at all)
            let nodesChanged = current.nodes != _cachedViewportNodes
            let viewportChanged = current.canvasOrigin != canvasOrigin || current.zoom != zoom
            if nodesChanged || viewportChanged {
                // Pan/zoom time throttling: 60fps upper limit to avoid rebuilding the SwiftUI tree every frame triggering updateNSView on all terminals
                // Force immediate update when node set changes (user operations require immediate response)
                let now = CACurrentMediaTime()
                let shouldUpdate = nodesChanged
                    || isDragging  // Maintain real-time updates when dragging nodes
                    || (now - _lastRootViewUpdateTime) >= Self.rootViewUpdateMinInterval
                guard shouldUpdate else { return }
                _lastRootViewUpdateTime = now

                hostingView.rootView = CanvasNodesSwiftUIView(
                    nodes: _cachedViewportNodes,
                    canvasOrigin: canvasOrigin,
                    zoom: zoom,
                    selectedNodeIds: current.selectedNodeIds,
                    lockedNodeIds: current.lockedNodeIds,
                    workspace: current.workspace,
                    dropTargetNodeId: current.dropTargetNodeId,
                    onActivated: current.onActivated,
                    onClose: current.onClose,
                    onRename: current.onRename,
                    onDuplicate: current.onDuplicate,
                    onLockToggle: current.onLockToggle
                )
            }
        }
    }

    // MARK: - Viewport cropping

    /// Viewport clipping margin (canvas coordinate unit), nodes beyond this distance from the viewport are not rendered
    /// Use larger margins to ensure nodes are ready before entering the viewport to avoid flickering
    private static let viewportCullMargin: CGFloat = 200

    /// Compute the list of nodes visible in the current viewport (in ascending order by zIndex)
    /// Logic: Convert the viewport screen bounds to canvas coordinates, add margins and make intersects judgment with the node frame
    func viewportCulledNodes() -> [CanvasNode] {
        let viewportCanvas = screenRectToCanvas(bounds).insetBy(
            dx: -Self.viewportCullMargin,
            dy: -Self.viewportCullMargin
        )
        return sortedNodesByZIndex.filter { node in
            viewportCanvas.intersects(node.frame)
        }
    }

    /// Save the canvas coordinates of each node (for recalculation of screen coordinates during layout)
    var nodeCanvasFrames: [UUID: CGRect] = [:]

    // MARK: - Node Management

    func addNodeView(_ view: NSView, id: UUID, canvasFrame: CGRect) {
        nodeViews[id] = view
        viewToNodeId[ObjectIdentifier(view)] = id
        addSubview(view)
        updateNodeFrame(id: id, canvasFrame: canvasFrame)
    }

    func removeNodeView(id: UUID) {
        if let view = nodeViews[id] {
            viewToNodeId.removeValue(forKey: ObjectIdentifier(view))
            view.removeFromSuperview()
        }
        nodeViews.removeValue(forKey: id)
        nodeCanvasFrames.removeValue(forKey: id)
    }

    func updateNodeFrame(id: UUID, canvasFrame: CGRect) {
        // External overwriting of the frame of the interacted node is not allowed during drag/resize
        switch interaction {
        case .draggingNode(let did, _, _) where did == id: return
        case .batchDragging(let frames, _, _) where frames.keys.contains(id): return
        case .resizingNode(let rid, _, _, _) where rid == id: return
        case .mayDragNode(let mid, _, _, _) where mid == id: return
        default: break
        }
        nodeCanvasFrames[id] = canvasFrame
        currentNodes = currentNodes.map { node in
            guard node.id == id else { return node }
            return CanvasNode(id: node.id, frame: canvasFrame, content: node.content,
                              zIndex: node.zIndex, isLocked: node.isLocked)
        }
        // Node frame changes may affect viewport visibility, forcing the crop cache to be invalidated
        _viewportCacheDirty = true
        needsLayout = true
    }


    // MARK: - Select notification merge delivery

    /// Prevent multiple deliveries of .canvasSelectionChanged in the same run loop (merged into one SwiftUI rebuild)
    private var _pendingSelectionNotification = false

    /// Delay delivery of .canvasSelectionChanged notifications until the end of the current run loop.
    /// Multiple calls within the same RunLoop Turn only generate one notification, thus
    /// The respective posts of updateSelectionVisuals() and bringNodesToFront() are merged into a single SwiftUI tree rebuild.
    private func scheduleSelectionChangedNotification() {
        guard !_pendingSelectionNotification else { return }
        _pendingSelectionNotification = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self._pendingSelectionNotification = false
            NotificationCenter.default.post(
                name: .canvasSelectionChanged,
                object: nil,
                userInfo: ["selectedIds": self.selectedNodeIds]
            )
        }
    }

    // MARK: - Check visual updates

    private func updateSelectionVisuals() {
        scheduleSelectionChangedNotification()
    }

    private func reportSelectionChange() {
        guard let callback = onSelectionChanged else { return }
        let frame = selectedNodeIds.first
            .flatMap { nodeCanvasFrames[$0] }
            .map { canvasRectToScreen($0) }
        callback(selectedNodeIds, frame)
    }

    // MARK: - Unified interactive state machine

    /// Current canvas interaction state (replaces all scattered drag/select/resize state variables)
    var interaction: CanvasInteraction = .idle

    /// Used for drag guideline drawing during dragging
    var dragGuidelines: [GuideLine] = [] {
        didSet {
            snapGuideView?.guidelines = dragGuidelines
        }
    }

    // The following is reserved (not related to the state machine, for external callbacks)
    var onNodeDragEnded: ((UUID, CGRect) -> Void)?
    var onBatchNodeDragEnded: (([UUID: CGRect]) -> Void)?
    /// Callback when resize ends (replaces the old mechanism of onFrameChanged)
    var onNodeResizeEnded: ((UUID, CGRect) -> Void)?

    // MARK: - Pan mode state (used by CanvasInputHandler extension)

    var isPanMode = false
    var isSpaceHeld = false

    // MARK: - Node drawing mode status

    var isInDrawingMode: Bool = false
    var drawingNodeType: String = "terminal" {
        didSet { snapGuideView?.drawingNodeType = drawingNodeType }
    }
    var onNodeDrawn: ((String, CGRect) -> Void)?
    /// freehand drawing completion callback (nodeType, normalized point sequence, bounding rectangle canvas coordinates)
    var onFreehandDrawn: ((String, [CGPoint], CGRect) -> Void)?

    /// Whether the current drawing tool is in stroke (line/arrow) mode
    var isStrokeDrawing: Bool { drawingNodeType.hasPrefix("stroke_") }
    /// Whether the current drawing tool is in freehand mode
    var isFreehandDrawing: Bool { drawingNodeType.hasPrefix("freehand_") }

    // MARK: - Frame selection/drawing/snap auxiliary state (maintained by CanvasInteractionHandler)

    /// Marquee select the current mouse position (only valid when interaction == .marquee)
    var marqueeCurrentPoint: CGPoint?
    /// Current mouse position in node drawing mode
    var drawingCurrentPoint: CGPoint?
    /// Draw mode grid snapping: Canvas rectangle after last snapping (used to detect grid spanning and trigger haptic)
    var drawingLastSnappedRect: CGRect?
    /// Magnet/grid snap assist status
    var lastSnapActive: Bool = false
    var lastSnappedGridOrigin: CGPoint? = nil

    // MARK: - File drag and drop state (used by the CanvasDragHandler extension)

    var onFilesDropped: (([String], CGPoint) -> Void)?
    var onFilesDroppedOnNode: (([String], UUID) -> Void)?
    var dropTargetNodeId: UUID?

    // MARK: - Animation timer (used by CanvasInputHandler extension)

    var animationTimer: Timer?

    // MARK: - Change notification

    func notifyViewportChanged() {
        onViewportChanged?(canvasOrigin, zoom)
    }

    // MARK: - Foreground overlay drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The background is drawn by the CanvasBackground subview
        // The magnetic auxiliary lines, selection rectangle, and drawing preview rectangle are drawn by the MagneticSnapGuideView (topmost)
        // Temporary connections have been moved to ConnectionOverlayView for drawing (to avoid being blocked by subviews)
    }

    // MARK: - Tracking Area Maintenance

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Always register the full canvas tracking area to ensure that mouseMoved continues to trigger to update the cursor
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(makeTrackingArea())
    }
}

// MARK: - Comparable clamped

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
