import AppKit

extension CanvasViewportView {

    // MARK: - Semantic hit testing

    /// Map canvas coordinate point to semantic hit area
    /// Priority: Selected nodes expand resize hot area > node content area (header/footer/content) > unselected nodes shrink resize > blank
    /// Pure geometric calculation, does not rely on BaseNodeView or subview hitTest (avoid infinite recursion)
    func hitTestCanvas(at loc: CGPoint) -> CanvasHitTestResult {
        // Directly return the cached result when the mouse displacement is less than the threshold (avoiding two O(n) traversals per frame at 60fps)
        let dx = loc.x - _hitTestCachedPoint.x
        let dy = loc.y - _hitTestCachedPoint.y
        if dx * dx + dy * dy < Self._hitTestReuseThreshold * Self._hitTestReuseThreshold {
            return _hitTestCachedResult
        }

        // Pass 0: shape node rotation handle hit detection (highest priority)
        for node in sortedNodesByZIndexDesc where selectedNodeIds.contains(node.id) {
            guard case .shape(let sc) = node.content else { continue }
            let screenFrame = canvasRectToScreen(node.frame)
            let nodeCenter = CGPoint(x: screenFrame.midX, y: screenFrame.midY)

            // Rotation handle above midpoint of node top edge (lineLength=20 + dotRadius=5) = 25pt (unrotated coordinate system)
            let handleOffsetY: CGFloat = 25
            let unrotatedHandleX = screenFrame.midX
            let unrotatedHandleY = screenFrame.minY - handleOffsetY

            // Rotate handle position from node local coordinates to screen coordinates
            let dx0 = unrotatedHandleX - nodeCenter.x
            let dy0 = unrotatedHandleY - nodeCenter.y
            let cosA = cos(sc.rotation)
            let sinA = sin(sc.rotation)
            let rotatedX = nodeCenter.x + dx0 * cosA - dy0 * sinA
            let rotatedY = nodeCenter.y + dx0 * sinA + dy0 * cosA

            let handleCenter = CGPoint(x: rotatedX, y: rotatedY)
            let halo: CGFloat = 12
            let distSq = (loc.x - handleCenter.x) * (loc.x - handleCenter.x) +
                         (loc.y - handleCenter.y) * (loc.y - handleCenter.y)
            if distSq <= halo * halo {
                let r = CanvasHitTestResult.nodeRotateHandle(node.id)
                _hitTestCachedPoint = loc; _hitTestCachedResult = r
                return r
            }
        }

        // Pass 1: First detect the external resize hot area of the selected node (outside the node border and does not conflict with the content)
        for node in sortedNodesByZIndexDesc where selectedNodeIds.contains(node.id) {
            guard !isNodeLocked(node.id) else { continue }
            // The text/drawing node does not support resize, and the size is adaptive based on the content.
            if case .text    = node.content { continue }
            if case .shape(let sc) = node.content, sc.rotation != 0 { continue }
            let screenFrame = canvasRectToScreen(node.frame)
            // External expansion hot area: expand outward with selectionOutset + resizeHaloWidth
            let halo = Self.resizeHaloWidth
            let expandedFrame = screenFrame.insetBy(dx: -halo, dy: -halo)
            guard expandedFrame.contains(loc) && !screenFrame.insetBy(dx: Self.resizeInnerDeadZone, dy: Self.resizeInnerDeadZone).contains(loc) else { continue }
            let localPt = CGPoint(x: loc.x - screenFrame.minX, y: loc.y - screenFrame.minY)
            if let edge = outerResizeEdge(at: localPt, nodeSize: screenFrame.size, halo: halo) {
                let r = CanvasHitTestResult.nodeResize(node.id, edge)
                _hitTestCachedPoint = loc; _hitTestCachedResult = r
                return r
            }
        }

        // Pass 2: Normal node internal hit test
        for node in sortedNodesByZIndexDesc {
            let screenFrame = canvasRectToScreen(node.frame)

            // stroke/freehand node: path distance hit (no rectangle is used, only close to the actual line segment is considered a hit)
            if case .stroke(let sc) = node.content {
                let hitRadius: CGFloat = max(6, sc.strokeWidth * zoom * 0.5 + 4)
                guard screenFrame.insetBy(dx: -hitRadius, dy: -hitRadius).contains(loc) else { continue }
                let localPt = CGPoint(x: loc.x - screenFrame.minX, y: loc.y - screenFrame.minY)
                let w = screenFrame.width
                let h = screenFrame.height
                let start   = CGPoint(x: sc.startPoint.x * w, y: sc.startPoint.y * h)
                let end     = CGPoint(x: sc.endPoint.x   * w, y: sc.endPoint.y   * h)
                let onPath: Bool
                if sc.strokeType == .arrow, let cp = sc.controlPoint {
                    let ctrl = CGPoint(x: cp.x * w, y: cp.y * h)
                    onPath = distanceToQuadBezier(localPt, p0: start, p1: ctrl, p2: end) <= hitRadius
                } else {
                    onPath = distanceToSegment(localPt, a: start, b: end) <= hitRadius
                }
                guard onPath else { continue }
                let r = CanvasHitTestResult.nodeContent(node.id, nodesHostingView ?? self)
                _hitTestCachedPoint = loc; _hitTestCachedResult = r
                return r
            }

            if case .freehand(let fc) = node.content {
                let hitRadius: CGFloat = max(6, fc.strokeWidth * zoom * 0.5 + 4)
                guard screenFrame.insetBy(dx: -hitRadius, dy: -hitRadius).contains(loc) else { continue }
                let localPt = CGPoint(x: loc.x - screenFrame.minX, y: loc.y - screenFrame.minY)
                let w = screenFrame.width
                let h = screenFrame.height
                let pts = fc.points.map { CGPoint(x: $0.x * w, y: $0.y * h) }
                var hit = false
                for i in 0..<pts.count - 1 {
                    if distanceToSegment(localPt, a: pts[i], b: pts[i + 1]) <= hitRadius { hit = true; break }
                }
                guard hit else { continue }
                let r = CanvasHitTestResult.nodeContent(node.id, nodesHostingView ?? self)
                _hitTestCachedPoint = loc; _hitTestCachedResult = r
                return r
            }

            guard screenFrame.contains(loc) else { continue }

            let localPt = CGPoint(
                x: loc.x - screenFrame.minX,
                y: loc.y - screenFrame.minY
            )

            // header at top of node (y down: minY is top edge, localPt.y small = top)
            let scaledHeaderHeight = CanvasNodeConstants.headerHeight * zoom
            if localPt.y <= scaledHeaderHeight {
                let r = CanvasHitTestResult.nodeHeader(node.id)
                _hitTestCachedPoint = loc; _hitTestCachedResult = r
                return r
            }

            // footer at the bottom of the node (only terminal nodes have footer)
            if case .terminal = node.content {
                let scaledFooterHeight = CanvasNodeConstants.footerHeight * zoom
                if localPt.y >= screenFrame.height - scaledFooterHeight {
                    let r = CanvasHitTestResult.nodeFooter(node.id)
                    _hitTestCachedPoint = loc; _hitTestCachedResult = r
                    return r
                }
            }

            let r = CanvasHitTestResult.nodeContent(node.id, nodesHostingView ?? self)
            _hitTestCachedPoint = loc; _hitTestCachedResult = r
            return r
        }
        let r = CanvasHitTestResult.canvas
        _hitTestCachedPoint = loc; _hitTestCachedResult = r
        return r
    }

    // MARK: - Resize hot zone constant

    /// Expansion resize the total width of the hot zone (screen pixels, not affected by zoom)
    /// The blue dotted frame is selectedOutset(3pt) from the edge of the node, and the hot zone extends inward to this width
    private static let resizeHaloWidth: CGFloat = 10
    /// Node internal dead zone: Clicks within this range do not trigger external expansion resize and directly enter the content area for interaction
    private static let resizeInnerDeadZone: CGFloat = 0

    /// Expansion mode: hot zone is within the [-halo, +halo] range of the node edge (based on the node screenFrame, localPt allows negative values)
    /// Corners first, edges second; respond only within strips close to edges
    private func outerResizeEdge(at localPt: CGPoint, nodeSize: CGSize, halo: CGFloat) -> ResizeEdge? {
        let w = nodeSize.width
        let h = nodeSize.height
        guard w > halo * 4 && h > halo * 4 else { return nil }

        // Hot zone strip: within halo range from each edge (localPt relative to screenFrame.origin, can be negative)
        let nearLeft   = localPt.x < halo
        let nearRight  = localPt.x > w - halo
        let nearTop    = localPt.y < halo
        let nearBottom = localPt.y > h - halo

        // Respond only if it is close to at least one edge
        guard nearLeft || nearRight || nearTop || nearBottom else { return nil }

        if nearTop    && nearLeft  { return .topLeft }
        if nearTop    && nearRight { return .topRight }
        if nearBottom && nearLeft  { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }
        if nearLeft                { return .left }
        if nearRight               { return .right }
        if nearTop                 { return .top }
        if nearBottom              { return .bottom }
        return nil
    }

    // MARK: - Node Lock Query

    /// O(1) Set lookup maintained by lockedNodeIds cache (replaces original O(n) linear scan)
    func isNodeLocked(_ id: UUID) -> Bool {
        lockedNodeIds.contains(id)
    }

    // MARK: - Select logic

    /// Update selectedNodeIds according to the modifier key and promote the selected node to the highest level
    func updateSelection(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedNodeIds.contains(id) {
                selectedNodeIds.remove(id)
            } else {
                selectedNodeIds.insert(id)
            }
        } else {
            if !selectedNodeIds.contains(id) {
                selectedNodeIds = [id]
            }
            // If the node is already in the selected set (batch selected state), narrow it again during mouseUp
        }
        // Promote the selected node to the highest level to ensure correct operation when overlapping
        bringNodesToFront([id])
    }

    /// When the fileTree content area is clicked, it is actively called by CanvasNodesView to trigger the node selection process.
    /// (Content area events are consumed by NSOutlineView/NSCollectionView and will not reach CanvasInteractionHandler.mouseDown)
    func selectFileTreeNode(at loc: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let hit = hitTestCanvas(at: loc)
        switch hit {
        case .nodeContent(let id, _), .nodeHeader(let id), .nodeFooter(let id):
            // Clicking on an unconnectable node in connection mode: cancels connection mode and retains the original selected state.
            if isInConnectingMode || connectingFromNodeId != nil {
                let isConnectable = currentNodes.first(where: { $0.id == id })?.content.isConnectable ?? true
                if !isConnectable {
                    isInConnectingMode = false
                    return
                }
            }
            updateSelection(id, modifiers: modifiers)
            NotificationCenter.default.post(
                name: .canvasNodeActivated,
                object: nil,
                userInfo: ["nodeId": id]
            )
        case .nodeResize, .nodeRotateHandle, .canvas:
            break
        }
    }

    // MARK: - Geometry Assist: Path Distance Hit Detection

    /// The shortest distance from a point to a line segment
    private func distanceToSegment(_ p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Approximate shortest distance from point to quadratic Bezier curve (20 segments linear sampling)
    private func distanceToQuadBezier(_ p: CGPoint, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGFloat {
        let steps = 20
        var minDist = CGFloat.greatestFiniteMagnitude
        var prev = p0
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let mt = 1 - t
            let cur = CGPoint(x: mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
                              y: mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y)
            let d = distanceToSegment(p, a: prev, b: cur)
            if d < minDist { minDist = d }
            prev = cur
        }
        return minDist
    }
}
