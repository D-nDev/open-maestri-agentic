import AppKit

// MARK: - Canvas hit test results

/// Semantic hit area for use by CanvasInteractionHandler
enum CanvasHitTestResult {
    case canvas
    case nodeHeader(UUID)
    case nodeFooter(UUID)
    case nodeContent(UUID, NSView)
    case nodeResize(UUID, ResizeEdge)
    case nodeRotateHandle(UUID)
}

// MARK: - Canvas interaction state machine

/// Replace all scattered interaction state variables on CanvasViewportView,
/// All states are stored in associated values to avoid inconsistent states.
enum CanvasInteraction {
    case idle
    /// The mouse has been pressed but it has not been determined whether to click or drag;
    /// contentTarget non-nil means that mouseDown has been transparently passed to the view (content area such as Terminal)
    case mayDragNode(UUID, startMouse: CGPoint, startFrame: CGRect, contentTarget: NSView?)
    case draggingNode(UUID, startMouse: CGPoint, startFrame: CGRect)
    case batchDragging([UUID: CGRect], primaryId: UUID, startMouse: CGPoint)
    case resizingNode(UUID, edge: ResizeEdge, startFrame: CGRect, startMouse: CGPoint)
    /// Rotating shape node
    case rotatingNode(UUID, startAngle: CGFloat, nodeCenter: CGPoint)
    case marquee(start: CGPoint)
    case panCanvas(startOrigin: CGPoint, startMouse: CGPoint)
    case drawing(start: CGPoint)
    /// Drawing stroke (line/arrow) node
    case drawingStroke(start: CGPoint)
    /// Freehand (free pen) node is being drawn; points is the screen coordinate sampling sequence
    case drawingFreehand(points: [CGPoint])
    /// Dragging stroke control points (start/end/Bezier control points)
    case draggingStrokePoint(UUID, pointRole: String, startContent: StrokeContent, startFrame: CGRect)
    /// The mouse is interacting with the node content area (such as terminal text selection); the event is forwarded to contentTarget
    case contentInteraction(UUID, contentTarget: NSView)
}

// MARK: - CanvasViewportView selectionRect helper

extension CanvasViewportView {
    /// Current marquee rectangle (read from interaction.marquee status)
    var selectionRect: CGRect? {
        guard case .marquee(let start) = interaction,
              let current = marqueeCurrentPoint else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }
}
