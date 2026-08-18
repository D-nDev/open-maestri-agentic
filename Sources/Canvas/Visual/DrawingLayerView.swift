import AppKit

/// A hand-drawn path rendering layer (below the node) that renders the DrawingContent as strokes on the canvas.
/// The stroke coordinates are the internal coordinates of the node and need to be converted to the canvas screen coordinates in conjunction with the node frame.
final class DrawingLayerView: NSView {
    override var isFlipped: Bool { true }

    var canvasOrigin: CGPoint = .zero
    var zoom: CGFloat = 1.0

    /// (node canvas frame, content) pair, updated externally at sync
    var drawingNodes: [(frame: CGRect, content: ShapeContent)] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Shape nodes are rendered by ShapeNodeSwiftUIView (SwiftUI layer).
        // This NSView drawing layer is no longer used.
    }

    private func canvasToScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - canvasOrigin.x) * zoom,
            y: (point.y - canvasOrigin.y) * zoom
        )
    }
}
