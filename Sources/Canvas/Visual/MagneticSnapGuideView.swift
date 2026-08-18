import AppKit

/// Magnetic alignment guide lines layer (topmost), replacing CanvasViewportView.drawSnapGuidelines().
/// Responsible for drawing both the selection rectangle and the node drawing preview rectangle (because this layer is above all node layers).
/// Use canvasOrigin/zoom to convert canvas coordinates to screen coordinates and then draw.
final class MagneticSnapGuideView: NSView {
    override var isFlipped: Bool { true }

    var guidelines: [GuideLine] = [] { didSet { needsDisplay = true } }
    /// Selection rectangle (screen coordinates, nil = do not draw)
    var selectionRect: CGRect? { didSet { needsDisplay = true } }
    /// Node draw preview rectangle (screen coordinates, nil = do not draw)
    var drawingRect: CGRect? { didSet { needsDisplay = true } }
    /// Current drawing node type (synchronized by CanvasViewportView, used for preview style judgment)
    var drawingNodeType: String = "terminal"
    /// stroke preview path (screen coordinates), including start point, end point and node type
    var strokePreviewPath: (start: CGPoint, end: CGPoint, type: String)? {
        didSet {
            if strokePreviewPath != nil { startAnimation() } else { stopAnimation() }
            needsDisplay = true
        }
    }
    /// freehand preview point list (screen coordinates)
    var freehandPreviewPoints: [CGPoint]? {
        didSet {
            if freehandPreviewPoints != nil { startAnimation() } else { stopAnimation() }
            needsDisplay = true
        }
    }
    var canvasOrigin: CGPoint = .zero
    var zoom: CGFloat = 1.0

    // MARK: - Marching dash animation

    private var animationTimer: Timer?
    private var dashPhase: CGFloat = 0

    private func startAnimation() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            dashPhase -= 0.5
            needsDisplay = true
        }
    }

    private func stopAnimation() {
        guard strokePreviewPath == nil && freehandPreviewPoints == nil else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        dashPhase = 0
    }

    // MARK: - draw

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Frame selection rectangle
        if let rect = selectionRect, rect.width > 2 || rect.height > 2 {
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.0
            NSColor.systemBlue.withAlphaComponent(0.4).setStroke()
            NSColor.systemBlue.withAlphaComponent(0.08).setFill()
            path.stroke()
            path.fill()
        }

        // Node drawing preview rectangle
        if let rect = drawingRect {
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
            NSColor.systemBlue.withAlphaComponent(0.05).setFill()
            path.stroke()
            path.fill()
        }

        // stroke preview (arrow/line) - traveling dashed line
        if let preview = strokePreviewPath {
            drawStrokePreview(start: preview.start, end: preview.end, type: preview.type)
        }

        // freehand preview (pen/doodle) - marching dashed line
        if let pts = freehandPreviewPoints, pts.count >= 2 {
            drawFreehandPreview(points: pts)
        }

        guard !guidelines.isEmpty else { return }

        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        for line in guidelines {
            let path = NSBezierPath()
            path.lineWidth = 1.0
            path.setLineDash([4, 3], count: 2, phase: 0)
            if line.axis == .vertical {
                let screenX = canvasToScreen(CGPoint(x: line.position, y: 0)).x
                let screenStart = canvasToScreen(CGPoint(x: 0, y: line.start)).y
                let screenEnd = canvasToScreen(CGPoint(x: 0, y: line.end)).y
                path.move(to: CGPoint(x: screenX, y: screenStart))
                path.line(to: CGPoint(x: screenX, y: screenEnd))
            } else {
                let screenY = canvasToScreen(CGPoint(x: 0, y: line.position)).y
                let screenStart = canvasToScreen(CGPoint(x: line.start, y: 0)).x
                let screenEnd = canvasToScreen(CGPoint(x: line.end, y: 0)).x
                path.move(to: CGPoint(x: screenStart, y: screenY))
                path.line(to: CGPoint(x: screenEnd, y: screenY))
            }
            path.stroke()
        }
    }

    // MARK: - Preview drawing assistance

    private func drawStrokePreview(start: CGPoint, end: CGPoint, type: String) {
        let path = NSBezierPath()
        path.move(to: start)
        if type == "stroke_arrow" {
            let ctrl = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            path.curve(to: end, controlPoint1: ctrl, controlPoint2: ctrl)
        } else {
            path.line(to: end)
        }
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.setLineDash([6, 4], count: 2, phase: dashPhase)
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        path.stroke()

        // Start and end points
        drawEndpointDot(at: start)
        drawEndpointDot(at: end)
    }

    private func drawFreehandPreview(points: [CGPoint]) {
        let path = NSBezierPath()
        path.move(to: points[0])
        if points.count > 3 {
            for i in 0..<points.count - 1 {
                let p0 = points[max(i - 1, 0)]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = points[min(i + 2, points.count - 1)]
                let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.curve(to: p2, controlPoint1: cp1, controlPoint2: cp2)
            }
        } else {
            for pt in points.dropFirst() { path.line(to: pt) }
        }
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.setLineDash([6, 4], count: 2, phase: dashPhase)
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        path.stroke()
    }

    private func drawEndpointDot(at point: CGPoint) {
        let r: CGFloat = 4
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        let dot = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill()
        dot.fill()
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        dot.lineWidth = 1.5
        dot.stroke()
    }

    func clear() {
        guidelines = []
        selectionRect = nil
        drawingRect = nil
        strokePreviewPath = nil
        freehandPreviewPoints = nil
    }

    private func canvasToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - canvasOrigin.x) * zoom,
            y: (point.y - canvasOrigin.y) * zoom
        )
    }
}
