import AppKit

/// Freehand select the interaction layer (above the connecting line) and draw a selection border for the selected drawing node.
final class DrawingOverlayView: NSView {
    override var isFlipped: Bool { true }

    var selectedDrawingIds: Set<UUID> = [] { didSet { needsDisplay = true } }
    var canvasOrigin: CGPoint = .zero { didSet { needsDisplay = true } }
    var zoom: CGFloat = 1.0 { didSet { needsDisplay = true } }

    /// (node id, node canvas frame) pair, updated externally during sync
    var drawingNodeFrames: [(id: UUID, frame: CGRect)] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !selectedDrawingIds.isEmpty else { return }

        let selectedFrames = drawingNodeFrames.filter { selectedDrawingIds.contains($0.id) }
        guard !selectedFrames.isEmpty else { return }

        NSColor.systemBlue.withAlphaComponent(0.5).setStroke()
        for item in selectedFrames {
            let screenOrigin = canvasToScreen(item.frame.origin)
            let screenFrame = CGRect(
                x: screenOrigin.x,
                y: screenOrigin.y,
                width: item.frame.width * zoom,
                height: item.frame.height * zoom
            )
            let path = NSBezierPath(rect: screenFrame.insetBy(dx: -2, dy: -2))
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.stroke()
        }
    }

    private func canvasToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - canvasOrigin.x) * zoom,
            y: (point.y - canvasOrigin.y) * zoom
        )
    }
}
