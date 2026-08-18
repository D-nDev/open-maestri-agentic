import AppKit
import CoreGraphics

/// Lower right corner Minimap (Story 2.4 AC)
/// - Display a thumbnail of the current canvas, with a blue box marking the viewport position
/// - Click anywhere: the viewport jumps to the corresponding area (300ms animation)
/// - Live updates (when nodes are moved/added)
final class MinimapView: NSView {
    override var isFlipped: Bool { true }

    // MARK: - data

    /// Canvas frame for all nodes
    var nodeFrames: [CGRect] = [] { didSet { needsDisplay = true } }

    /// Current viewport (canvas coordinates)
    var viewportRect: CGRect = .zero { didSet { needsDisplay = true } }

    /// Effective area of canvas (bounding box of all nodes, with padding)
    var canvasBounds: CGRect = CGRect(x: 9600, y: 8300, width: 600, height: 600)

    /// Click jump callback (pass in the origin of the target canvas)
    var onJumpTo: ((CGPoint) -> Void)?

    // MARK: - Appearance

    private let backgroundColor = NSColor.black.withAlphaComponent(0.75)
    private let nodeColor = NSColor.white.withAlphaComponent(0.5)
    private let viewportColor = NSColor.systemBlue.withAlphaComponent(0.3)
    private let viewportBorderColor = NSColor.systemBlue

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
        layer?.cornerRadius = 6
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        layer?.borderWidth = 0.5
    }

    // MARK: - draw

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard NSGraphicsContext.current?.cgContext != nil else { return }

        backgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        let scale = minimapScale()

        // Draw node rectangle
        nodeColor.setFill()
        for nodeFrame in nodeFrames {
            let mapped = mapToMinimap(nodeFrame, scale: scale)
            let path = NSBezierPath(roundedRect: mapped, xRadius: 2, yRadius: 2)
            path.fill()
        }

        // Draw the viewport blue box
        let mappedViewport = mapToMinimap(viewportRect, scale: scale)
        viewportColor.setFill()
        NSBezierPath(roundedRect: mappedViewport, xRadius: 2, yRadius: 2).fill()
        viewportBorderColor.setStroke()
        let borderPath = NSBezierPath(roundedRect: mappedViewport, xRadius: 2, yRadius: 2)
        borderPath.lineWidth = 1.0
        borderPath.stroke()
    }

    // MARK: - Coordinate mapping

    private func minimapScale() -> CGFloat {
        let scaleX = bounds.width / canvasBounds.width
        let scaleY = bounds.height / canvasBounds.height
        return min(scaleX, scaleY) * 0.9
    }

    private func mapToMinimap(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let padding: CGFloat = 4
        let ox = (rect.origin.x - canvasBounds.minX) * scale + padding
        let oy = (rect.origin.y - canvasBounds.minY) * scale + padding
        return CGRect(
            x: ox, y: oy,
            width: max(rect.width * scale, 3),
            height: max(rect.height * scale, 3)
        )
    }

    private func minimapPointToCanvas(_ point: CGPoint) -> CGPoint {
        let padding: CGFloat = 4
        let scale = minimapScale()
        let cx = (point.x - padding) / scale + canvasBounds.minX
        let cy = (point.y - padding) / scale + canvasBounds.minY
        return CGPoint(x: cx, y: cy)
    }

    // MARK: - Click to jump (Story 2.4 AC: 300ms animation)

    override func mouseDown(with event: NSEvent) {
        let click = convert(event.locationInWindow, from: nil)
        let canvasPoint = minimapPointToCanvas(click)
        onJumpTo?(canvasPoint)
    }

    // MARK: - External update API

    /// Update Minimap based on current node list and viewport
    func update(nodes: [CGRect], viewport: CGRect) {
        if nodes.isEmpty {
            canvasBounds = CGRect(x: 9600, y: 8300, width: 800, height: 600)
        } else {
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity
            var minY = CGFloat.infinity, maxY = -CGFloat.infinity
            for r in nodes {
                minX = min(minX, r.minX); maxX = max(maxX, r.maxX)
                minY = min(minY, r.minY); maxY = max(maxY, r.maxY)
            }
            canvasBounds = CGRect(
                x: minX - 100,
                y: minY - 100,
                width: maxX - minX + 200,
                height: maxY - minY + 200
            )
        }
        nodeFrames = nodes
        viewportRect = viewport
    }
}
