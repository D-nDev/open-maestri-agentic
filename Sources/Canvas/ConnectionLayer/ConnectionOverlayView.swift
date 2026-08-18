import AppKit

/// Render layer NSView for all wires (Story 5.1 AC)
/// - Overlay on top of the canvas and draw all active connections with a RopePathRenderer via draw(_:)
/// - Wires rendered with physical rope animation (catenary, 21 control points, Story 5.1 AC)
/// - Color status coding: gray (idle) → green glow (communicating) → red (disconnected) (UX-DR5)
/// - Support hover highlighting and right-click deletion of connections
final class ConnectionOverlayView: NSView {
    override var isFlipped: Bool { true }

    // MARK: - Data source

    /// List of connections that currently need to be drawn (updated by the canvas when nodes move/connections change)
    /// Only trigger redraw when wire data actually changes (avoid redundant redraw when viewport pan/zoom)
    var connections: [RenderableConnection] = [] {
        didSet {
            guard connectionsDidChange(old: oldValue, new: connections) else { return }
            needsDisplay = true
        }
    }

    /// Quickly determine whether there are actual changes in connection data
    /// Comparison strategy: Quantity → Each connection id + start and end midpoint (covers 95% of scenarios, avoiding point-by-point full comparison)
    private func connectionsDidChange(old: [RenderableConnection], new: [RenderableConnection]) -> Bool {
        guard old.count == new.count else { return true }
        for i in old.indices {
            let o = old[i], n = new[i]
            if o.id != n.id || o.status != n.status { return true }
            // Compare the three sampling positions of the first point, the last point and the middle point
            guard o.screenPoints.count == n.screenPoints.count,
                  !o.screenPoints.isEmpty else { return o.screenPoints.count != n.screenPoints.count }
            let midIdx = o.screenPoints.count / 2
            if !pointsEqual(o.screenPoints[0], n.screenPoints[0]) ||
               !pointsEqual(o.screenPoints[midIdx], n.screenPoints[midIdx]) ||
               !pointsEqual(o.screenPoints[o.screenPoints.count - 1], n.screenPoints[n.screenPoints.count - 1]) {
                return true
            }
        }
        return false
    }

    /// Floating point coordinate comparison (0.5 pixel tolerance to avoid sub-pixel jitter triggering redraws)
    private func pointsEqual(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
    }

    /// The connection ID currently highlighted by hover
    private var highlightedConnectionId: UUID? {
        didSet {
            if oldValue != highlightedConnectionId { needsDisplay = true }
        }
    }

    /// Connection delete callback (incoming connection UUID)
    var onDeleteConnection: ((UUID) -> Void)?

    /// Wire hit detection tolerance (pixels)
    private static let hitTolerance: CGFloat = 8.0

    // MARK: - Temporary connection data (synchronized by CanvasViewportView during dragging of the connection tool)

    /// Screen coordinate frame of the temporary connection starting point node
    var tempConnectionFromFrame: CGRect? = nil {
        didSet { if oldValue != tempConnectionFromFrame { needsDisplay = true } }
    }
    /// Temporary connection end point (mouse current screen coordinates)
    var tempConnectionToPoint: CGPoint? = nil {
        didSet { if oldValue != tempConnectionToPoint { needsDisplay = true } }
    }

    // MARK: - Initialization

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        setupTracking()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = .clear
        setupTracking()
    }

    private func setupTracking() {
        // Initial tracking area will be refreshed in updateTrackingAreas
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Mouse events

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        highlightedConnectionId = connectionId(at: loc)
        if highlightedConnectionId != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        highlightedConnectionId = nil
        NSCursor.arrow.set()
    }

    /// Right-click on the connection to pop up the delete menu
    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard let connId = connectionId(at: loc) else {
            super.rightMouseDown(with: event)
            return
        }
        highlightedConnectionId = connId

        let menu = NSMenu()
        let deleteTitle = "connection.delete".localized
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteHighlightedConnection), keyEquivalent: "")
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.systemRed]
        deleteItem.attributedTitle = NSAttributedString(string: deleteTitle, attributes: attrs)
        deleteItem.target = self
        menu.addItem(deleteItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func deleteHighlightedConnection() {
        guard let connId = highlightedConnectionId else { return }
        onDeleteConnection?(connId)
        highlightedConnectionId = nil
    }

    /// Let mouse events penetrate to the lower layer (only intercept when above the connection)
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if connectionId(at: localPoint) != nil {
            return self
        }
        return nil  // Penetrate to the lower layer
    }

    // MARK: - Connection hit detection

    /// Find the closest connection (within tolerance) to a specified point
    /// - Parameter point: Point in the coordinate system of this view
    /// - Returns: hit connection UUID, nil means miss
    func connectionId(at point: CGPoint) -> UUID? {
        var bestId: UUID?
        var bestDist: CGFloat = Self.hitTolerance

        for conn in connections {
            let dist = minDistance(from: point, to: conn.screenPoints)
            if dist < bestDist {
                bestDist = dist
                bestId = conn.id
            }
        }
        return bestId
    }

    /// Calculate the minimum distance from a point to a polyline segment
    private func minDistance(from point: CGPoint, to polyline: [CGPoint]) -> CGFloat {
        guard polyline.count >= 2 else { return .greatestFiniteMagnitude }
        var minDist: CGFloat = .greatestFiniteMagnitude
        for i in 0..<(polyline.count - 1) {
            let d = distanceToSegment(point: point, a: polyline[i], b: polyline[i + 1])
            if d < minDist { minDist = d }
        }
        return minDist
    }

    /// Distance from point to line segment
    private func distanceToSegment(point: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            return hypot(point.x - a.x, point.y - a.y)
        }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }

    // MARK: - Draw (Story 5.1 AC: real-time recalculation of catenary lines, 60fps)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // dirtyRect clipping: only draw the connection line where the bounding box intersects dirtyRect
        let inflatedDirty = dirtyRect.insetBy(dx: -10, dy: -10) // Extend slight tolerance to avoid edge truncation
        for conn in connections {
            // Fast bounding box detection: estimate the connected bounding box using three points in the first and last
            guard !conn.screenPoints.isEmpty else { continue }
            let bbox = boundingBox(of: conn.screenPoints)
            guard inflatedDirty.intersects(bbox) else { continue }

            let isHighlighted = conn.id == highlightedConnectionId
            RopePathRenderer.draw(points: conn.screenPoints, status: conn.status, isHighlighted: isHighlighted)

            // Status text (Injecting Skill.../Skill has been injected into both ends)
            if let label = conn.statusLabel, let mid = RopePathRenderer.midpoint(of: conn.screenPoints) {
                drawLabel(label, at: mid)
            }
        }

        // Temporary connection drawing (when dragging the connection tool)
        drawTemporaryConnectionLine()
    }

    // MARK: - Temporary line drawing

    /// Temporary dashed line (straight line) when dragging with the Draw Connection tool
    private func drawTemporaryConnectionLine() {
        guard let fromFrame = tempConnectionFromFrame else { return }

        // Draw four edge connection point indicators when mouse is not moving
        guard let toPoint = tempConnectionToPoint else {
            drawEdgeConnectors(on: fromFrame)
            return
        }

        // Calculate the anchor point starting from the edge of the node (towards the intersection point with the border in the direction of the mouse)
        let fromCenter = CGPoint(x: fromFrame.midX, y: fromFrame.midY)
        let fromPoint = Self.edgeAnchor(of: fromFrame, center: fromCenter, toward: toPoint)

        // Draw a dashed straight line
        let path = NSBezierPath()
        path.move(to: fromPoint)
        path.line(to: toPoint)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        path.stroke()

        // Start connection point indicator (draw a small circle at the starting point on the edge of the node)
        drawConnectorDot(at: fromPoint)

        // End point indicator (draw a small circle at the mouse position)
        drawConnectorDot(at: toPoint, color: NSColor.systemBlue.withAlphaComponent(0.5))

        // Source node border highlight (light blue)
        let borderPath = NSBezierPath(roundedRect: fromFrame, xRadius: 6, yRadius: 6)
        borderPath.lineWidth = 1.5
        NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
        borderPath.stroke()
    }

    /// Draw a connection point circle at the midpoint of the four edges of the node (when wire mode is activated but the mouse is not moved)
    private func drawEdgeConnectors(on frame: CGRect) {
        let midPoints = [
            CGPoint(x: frame.midX, y: frame.minY),  // on
            CGPoint(x: frame.midX, y: frame.maxY),  // Next
            CGPoint(x: frame.minX, y: frame.midY),  // Left
            CGPoint(x: frame.maxX, y: frame.midY),  // Right
        ]

        // Node border highlighting
        let borderPath = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        borderPath.lineWidth = 1.5
        NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
        borderPath.stroke()

        // Four connection points
        for pt in midPoints {
            drawConnectorDot(at: pt)
        }
    }

    /// Draw connector dots (blue outer ring + white inner ring)
    private func drawConnectorDot(at point: CGPoint, color: NSColor = .systemBlue) {
        let outerRadius: CGFloat = 5.0
        let innerRadius: CGFloat = 2.5
        let outerRect = CGRect(
            x: point.x - outerRadius, y: point.y - outerRadius,
            width: outerRadius * 2, height: outerRadius * 2
        )
        color.setFill()
        NSBezierPath(ovalIn: outerRect).fill()

        let innerRect = CGRect(
            x: point.x - innerRadius, y: point.y - innerRadius,
            width: innerRadius * 2, height: innerRadius * 2
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: innerRect).fill()
    }

    // MARK: - Edge anchor point calculation

    /// Calculate the anchor point starting from the node border (make a ray from the frame center to the target direction and return the intersection with the border)
    static func edgeAnchor(of frame: CGRect, center: CGPoint, toward target: CGPoint) -> CGPoint {
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

    /// Calculate axis-aligned bounding box of control point sequence
    private func boundingBox(of points: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            if p.x < minX { minX = p.x }
            if p.y < minY { minY = p.y }
            if p.x > maxX { maxX = p.x }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        attributed.draw(at: CGPoint(x: point.x - 40, y: point.y + 4))
    }

    // MARK: - Update the connection position (called in real time when the node is dragged)

    func updateConnection(id: UUID, screenPoints: [CGPoint]) {
        if let idx = connections.firstIndex(where: { $0.id == id }) {
            connections[idx].screenPoints = screenPoints
        }
    }

    func addConnection(_ conn: RenderableConnection) {
        if !connections.contains(where: { $0.id == conn.id }) {
            connections.append(conn)
        }
    }

    func removeConnection(id: UUID) {
        connections.removeAll { $0.id == id }
    }

    func updateStatus(_ status: ConnectionStatus, for id: UUID) {
        if let idx = connections.firstIndex(where: { $0.id == id }) {
            connections[idx].status = status
            needsDisplay = true
        }
    }
}

/// Renderable connection data (canvas coordinates converted to screen coordinates)
struct RenderableConnection {
    let id: UUID
    var screenPoints: [CGPoint]  // 21 control points (converted to screen coordinates)
    var status: ConnectionStatus
    var statusLabel: String?     // nil means do not display the label
}
