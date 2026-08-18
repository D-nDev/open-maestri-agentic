import AppKit

extension CanvasViewportView {

    // MARK: - Resize auxiliary

    func applyResizeOnCanvas(id: UUID,
                             edge: ResizeEdge,
                             dx: CGFloat, dy: CGFloat,
                             startFrame: CGRect) {
        let minW = CanvasNodeConstants.minNodeWidth * zoom
        let minH = CanvasNodeConstants.minNodeHeight * zoom
        let grid = Constants.canvasGridSpacing

        var x = startFrame.origin.x
        var y = startFrame.origin.y
        var w = startFrame.width
        var h = startFrame.height

        // startFrame is the screen coordinate (after scaling), dx/dy is also the screen coordinate
        // isFlipped = true: y=0 at top, dy>0 down
        switch edge {
        case .right:
            w = max(w + dx, minW)
        case .left:
            let newW = max(w - dx, minW)
            x = startFrame.maxX - newW
            w = newW
        case .bottom:
            h = max(h + dy, minH)
        case .top:
            let bottom = y + h
            let newH = max(h - dy, minH)
            y = bottom - newH
            h = newH
        case .bottomLeft:
            let newW = max(w - dx, minW)
            x = startFrame.maxX - newW
            w = newW
            h = max(h + dy, minH)
        case .bottomRight:
            w = max(w + dx, minW)
            h = max(h + dy, minH)
        case .topLeft:
            let newW = max(w - dx, minW)
            x = startFrame.maxX - newW
            w = newW
            let bottom = y + h
            let newH = max(h - dy, minH)
            y = bottom - newH
            h = newH
        case .topRight:
            w = max(w + dx, minW)
            let bottom = y + h
            let newH = max(h - dy, minH)
            y = bottom - newH
            h = newH
        }

        // Snap active edges to canvas grid (consistent with drag/draw)
        // First convert to canvas coordinates and then convert back to screen coordinates
        let rawCanvasOrigin = screenToCanvas(CGPoint(x: x, y: y))
        let rawCanvasW = w / zoom
        let rawCanvasH = h / zoom

        let snappedCanvasOrigin: CGPoint
        let snappedCanvasW: CGFloat
        let snappedCanvasH: CGFloat

        switch edge {
        case .right, .bottomRight, .topRight:
            // Right activity: Adsorb the right side
            let snappedRight = ((rawCanvasOrigin.x + rawCanvasW) / grid).rounded() * grid
            snappedCanvasW = max(snappedRight - rawCanvasOrigin.x, CanvasNodeConstants.minNodeWidth)
            snappedCanvasOrigin = rawCanvasOrigin
            snappedCanvasH = rawCanvasH
        case .left, .bottomLeft, .topLeft:
            // Left activity: adsorb the left side (right side is fixed)
            let fixedRight = rawCanvasOrigin.x + rawCanvasW
            let snappedLeft = (rawCanvasOrigin.x / grid).rounded() * grid
            snappedCanvasW = max(fixedRight - snappedLeft, CanvasNodeConstants.minNodeWidth)
            snappedCanvasOrigin = CGPoint(x: fixedRight - snappedCanvasW, y: rawCanvasOrigin.y)
            snappedCanvasH = rawCanvasH
        case .bottom:
            // Bottom activity: adsorb the bottom
            let snappedBottom = ((rawCanvasOrigin.y + rawCanvasH) / grid).rounded() * grid
            snappedCanvasH = max(snappedBottom - rawCanvasOrigin.y, CanvasNodeConstants.minNodeHeight)
            snappedCanvasOrigin = rawCanvasOrigin
            snappedCanvasW = rawCanvasW
        case .top:
            // Top activity: adsorb the top (fix the bottom)
            let fixedBottom = rawCanvasOrigin.y + rawCanvasH
            let snappedTop = (rawCanvasOrigin.y / grid).rounded() * grid
            snappedCanvasH = max(fixedBottom - snappedTop, CanvasNodeConstants.minNodeHeight)
            snappedCanvasOrigin = CGPoint(x: rawCanvasOrigin.x, y: fixedBottom - snappedCanvasH)
            snappedCanvasW = rawCanvasW
        }

        let newCanvasFrame = CGRect(x: snappedCanvasOrigin.x, y: snappedCanvasOrigin.y,
                                    width: snappedCanvasW, height: snappedCanvasH)

        // Trigger haptic feedback on grid crossing (consistent with dragging/drawing)
        if let prev = nodeCanvasFrames[id], prev != newCanvasFrame {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nodeCanvasFrames[id] = newCanvasFrame
        // Update currentNodes synchronously to avoid "bounce" caused by using the old frame when layout() rebuilds the SwiftUI view
        updateNodeFrameInPlace(id: id, frame: newCanvasFrame)
        CATransaction.commit()
        needsLayout = true
        // Notify the wired physics engine: resize also changes the node center
        onNodeFramesDuringDrag?([id])
    }
}
