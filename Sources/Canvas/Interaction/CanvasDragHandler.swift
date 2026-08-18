import AppKit

extension CanvasViewportView {

    // MARK: - Node drawing mode

    /// Default node size (canvas coordinates) on click creation
    func defaultNodeSize(for nodeType: String) -> CGSize {
        switch nodeType {
        case "terminal":
            return CGSize(width: 600, height: 400)
        case "stickyNote":
            return CGSize(width: 300, height: 240)
        case "portal":
            return CGSize(width: 500, height: 380)
        case "fileTree":
            return CGSize(width: 360, height: 480)
        case "text":
            return CGSize(width: 45, height:35)
        case "shape":
            return CGSize(width: 200, height: 150)
        default:
            return CGSize(width: 400, height: 300)
        }
    }

    // MARK: - Connection assistance

    /// Check the node ID from the view (or its subview)
    /// Try O(1) direct mapped cache first, O(n) ancestor chain traversal on miss
    func nodeId(for view: NSView?) -> UUID? {
        guard let v = view else { return nil }
        if let id = viewToNodeId[ObjectIdentifier(v)] { return id }
        for (id, nodeView) in nodeViews {
            if v.isDescendant(of: nodeView) { return id }
        }
        return nil
    }

    func handleConnectionClick(nodeId: UUID) {
        if let fromId = connectingFromNodeId {
            // Second click: Complete connection
            if fromId != nodeId {
                onConnectionCreated?(fromId, nodeId)
            }
            connectingFromNodeId = nil
            connectionDragPoint = nil
            // Exit the connection mode after the connection is completed (notify the SwiftUI layer to update isConnecting)
            isInConnectingMode = false
        } else {
            // First click: Set the starting point and select the node
            connectingFromNodeId = nodeId
            selectedNodeIds = [nodeId]
            // Turn on mouse tracking
            for ta in trackingAreas { removeTrackingArea(ta) }
            addTrackingArea(makeTrackingArea())
        }
        needsDisplay = true
    }

    func makeTrackingArea() -> NSTrackingArea {
        NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
    }

    // MARK: - Grid adsorption

    /// Adsorb the four edges of the node frame to the background grid line (consistent with the coordinate system used by drawLineGrid)
    /// Round the four sides of left/right/top/bottom respectively, and select the side with the smallest displacement to align
    func snapToGrid(_ origin: CGPoint, size: CGSize) -> CGPoint {
        let grid = Constants.canvasGridSpacing

        let left   = origin.x
        let right  = origin.x + size.width
        let bottom = origin.y
        let top    = origin.y + size.height

        let snappedLeft   = (left   / grid).rounded() * grid
        let snappedRight  = (right  / grid).rounded() * grid
        let snappedBottom = (bottom / grid).rounded() * grid
        let snappedTop    = (top    / grid).rounded() * grid

        let dx = abs(snappedLeft - left) <= abs(snappedRight - right)
            ? snappedLeft - left
            : snappedRight - right
        let dy = abs(snappedBottom - bottom) <= abs(snappedTop - top)
            ? snappedBottom - bottom
            : snappedTop - top

        return CGPoint(x: origin.x + dx, y: origin.y + dy)
    }

    // MARK: - Draw rectangle preview

    func drawDrawingRect() {
        guard isInDrawingMode,
              case .drawing(let start) = interaction,
              let current = drawingCurrentPoint else { return }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
        NSColor.systemBlue.withAlphaComponent(0.05).setFill()
        path.stroke()
        path.fill()
    }

    // MARK: - Drawing of frame selection rectangle

    func drawSelectionRect() {
        guard let rect = selectionRect, rect.width > 2 || rect.height > 2 else { return }
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1.0
        NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
        NSColor.systemBlue.withAlphaComponent(0.08).setFill()
        path.stroke()
        path.fill()
    }

    // MARK: - Temporary connection drawing (when dragging the connection tool, use the physical droop curve)

    func drawTemporaryConnection() {
        guard let fromId = connectingFromNodeId,
              let fromCanvasFrame = nodeCanvasFrames[fromId] else { return }
        let fromScreenFrame = canvasRectToScreen(fromCanvasFrame)

        // If the mouse has not been moved yet (just entered wired mode), show four edge connection point indicators
        guard let toPoint = connectionDragPoint else {
            drawEdgeConnectors(on: fromScreenFrame)
            return
        }
        // Calculate the anchor point starting from the edge of the node (towards the intersection point with the border in the direction of the mouse)
        let fromCenter = CGPoint(x: fromScreenFrame.midX, y: fromScreenFrame.midY)
        let fromPoint = Self.edgeAnchorScreen(of: fromScreenFrame, center: fromCenter, toward: toPoint)

        // Use static catenary calculations (with natural droop effect)
        let catenaryPoints = RopeSimulation.computeStaticCatenary(from: fromPoint, to: toPoint)

        guard catenaryPoints.count >= 2 else { return }

        // Use polyline drawing (21 control points are dense enough to visually approximate a smooth curve)
        let path = NSBezierPath()
        path.move(to: catenaryPoints[0])
        for i in 1..<catenaryPoints.count {
            path.line(to: catenaryPoints[i])
        }
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        path.stroke()

        // Start connection point indicator (draw a small circle at the starting point on the edge of the node)
        let connectorRadius: CGFloat = 5.0
        let connectorRect = CGRect(
            x: fromPoint.x - connectorRadius,
            y: fromPoint.y - connectorRadius,
            width: connectorRadius * 2,
            height: connectorRadius * 2
        )
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: connectorRect).fill()
        NSColor.white.setFill()
        let innerRadius: CGFloat = 2.5
        let innerRect = CGRect(
            x: fromPoint.x - innerRadius,
            y: fromPoint.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        )
        NSBezierPath(ovalIn: innerRect).fill()

        // Source node border highlight (light blue)
        let borderPath = NSBezierPath(roundedRect: fromScreenFrame, xRadius: 6, yRadius: 6)
        borderPath.lineWidth = 1.5
        NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
        borderPath.stroke()
    }

    // MARK: - Connection point indicator

    /// Draw a connection point circle at the midpoint of the four edges of the node (when wire mode is activated but the mouse is not moved)
    private func drawEdgeConnectors(on frame: CGRect) {
        let midPoints = [
            CGPoint(x: frame.midX, y: frame.minY),  // on
            CGPoint(x: frame.midX, y: frame.maxY),  // Next
            CGPoint(x: frame.minX, y: frame.midY),  // Left
            CGPoint(x: frame.maxX, y: frame.midY),  // Right
        ]
        let radius: CGFloat = 5.0
        let innerRadius: CGFloat = 2.5

        // Node border highlighting
        let borderPath = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        borderPath.lineWidth = 1.5
        NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
        borderPath.stroke()

        // Four connection points
        for pt in midPoints {
            let outerRect = CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: outerRect).fill()
            let innerRect = CGRect(x: pt.x - innerRadius, y: pt.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: innerRect).fill()
        }
    }

    // MARK: - Edge anchor point calculation (screen coordinates)

    /// Compute anchor point starting from node bounding box (screen coordinate version)
    /// Make a ray from the center of the frame to the target direction and return the intersection point with the border
    static func edgeAnchorScreen(of frame: CGRect, center: CGPoint, toward target: CGPoint) -> CGPoint {
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

    // MARK: - Finder file drag-in (create Note node)

    /// Register drag-and-drop target (in setup() call)
    func registerDragTypes() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFileURLs(sender) else { return [] }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard containsFileURLs(sender) else { return [] }
        // Highlight target node (if mouse is over node)
        let loc = convert(sender.draggingLocation, from: nil)
        updateDropTargetHighlight(at: loc)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropTargetHighlight()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDropTargetHighlight()
        let locScreen = convert(sender.draggingLocation, from: nil)
        let urls = extractFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let paths = urls.map { $0.path }

        // Check whether it falls on a certain node
        if let targetNodeId = nodeId(at: locScreen) {
            onFilesDroppedOnNode?(paths, targetNodeId)
            return true
        }

        // Falling in white space: Note nodes are created for all files
        let locCanvas = screenToCanvas(locScreen)
        if !paths.isEmpty {
            onFilesDropped?(paths, locCanvas)
        }
        return true
    }

    /// Find the node ID at the specified screen coordinates (using hitTestCanvas, compatible with the case where nodeViews is empty after NSHostingView migration)
    func nodeId(at screenPoint: CGPoint) -> UUID? {
        let hit = hitTestCanvas(at: screenPoint)
        switch hit {
        case .nodeHeader(let id), .nodeFooter(let id), .nodeContent(let id, _), .nodeResize(let id, _), .nodeRotateHandle(let id):
            return id
        case .canvas:
            return nil
        }
    }

    /// Highlight target node when dragging and hovering (updating SwiftUI layer dropTargetNodeId via NotificationCenter)
    private func updateDropTargetHighlight(at screenPoint: CGPoint) {
        let newTarget = nodeId(at: screenPoint)
        if newTarget != dropTargetNodeId {
            dropTargetNodeId = newTarget
            NotificationCenter.default.post(
                name: .canvasDropTargetChanged,
                object: nil,
                userInfo: ["dropTargetNodeId": newTarget as Any]
            )
        }
    }

    private func clearDropTargetHighlight() {
        dropTargetNodeId = nil
        NotificationCenter.default.post(
            name: .canvasDropTargetChanged,
            object: nil,
            userInfo: [:]
        )
    }

    private func containsFileURLs(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }
        return !urls.isEmpty
    }

    private func extractFileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    }

    private func isMarkdownPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "txt"
    }
}
