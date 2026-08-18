import AppKit
import WebKit

extension CanvasViewportView {

    // MARK: - Terminal mouse coordinate correction

    /// Fix mouse event coordinates forwarded to terminal views.
    ///
    /// Problem background: Nodes are scaled through SwiftUI `.scaleEffect(zoom)`, which is the CALayer transform,
    /// Does not affect NSView's frame/bounds. So inside SwiftTerm
    /// `convert(event.locationInWindow, from: nil)` when calculating coordinates based on NSView hierarchy
    /// The layer transform is not considered, resulting in mapping to the wrong terminal row and column position.
    ///
    /// Correction plan:
    /// 1. Calculate the relative position of the mouse in the terminal content area from the canvas screen coordinates (zoomed)
    /// 2. Divide by zoom to get the local coordinates of the terminal view (unzoomed)
    /// 3. Use terminalView’s own convert(to: nil) to reversely synthesize the correct window coordinates
    ///    Make SwiftTerm's convert(from: nil) correctly restore to local coordinates
    func correctedWindowLocation(for event: NSEvent, nodeId: UUID, terminalView: NSView) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)

        guard let node = currentNodes.first(where: { $0.id == nodeId }) else {
            return event.locationInWindow
        }

        let screenFrame = canvasRectToScreen(node.frame)
        let scaledHeaderHeight = CanvasNodeConstants.headerHeight * zoom

        // The terminal node has a footer and needs to be subtracted; add a divider (about 1pt after scaling)
        let scaledDividerHeight: CGFloat = 1.0 * zoom

        // Relative position of the mouse in the node's content area (screen coordinates, multiplied by zoom)
        let relX = loc.x - screenFrame.minX
        let relY = loc.y - screenFrame.minY - scaledHeaderHeight - scaledDividerHeight

        // Convert to terminal view local coordinates (unscaled)
        // SwiftTerm TerminalView is not flipped (y from bottom up) and needs to flip the y axis
        let tvHeight = terminalView.bounds.height
        let localX = relX / zoom
        let localY = tvHeight - (relY / zoom)

        // Use terminalView's own coordinate system to convert back to window coordinates
        // In this way, SwiftTerm gets (localX, localY) when calling convert(locationInWindow, from: nil)
        return terminalView.convert(CGPoint(x: localX, y: localY), to: nil)
    }

    /// Portal WKWebView coordinate correction
    /// WKWebView is a flipped coordinate system (y from top to bottom), and the Portal node has header + navBar + divider offset
    func correctedWindowLocationForWebView(for event: NSEvent, nodeId: UUID, webView: NSView) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)

        guard let node = currentNodes.first(where: { $0.id == nodeId }) else {
            return event.locationInWindow
        }

        let screenFrame = canvasRectToScreen(node.frame)
        // Portal content area offset: header(32) + navBar padding(6) + navBar height(28) + padding(6) + divider(1) = 73
        let contentTopOffset: CGFloat = 73.0
        let scaledContentTop = contentTopOffset * zoom

        // Relative position of the mouse in the WebView content area (screen coordinates)
        let relX = loc.x - screenFrame.minX
        let relY = loc.y - screenFrame.minY - scaledContentTop

        // Convert to WebView local coordinates (unscaled)
        // WKWebView is flipped (y from top to bottom) consistent with the screen coordinate system (AppKit's y from down)
        let localX = relX / zoom
        let localY = relY / zoom

        // Use webView's own coordinate system to convert back to window coordinates
        return webView.convert(CGPoint(x: localX, y: localY), to: nil)
    }

    /// NSTextView coordinate correction (Shape node)
    /// Shape node has no header/footer, NSTextView covers the entire node frame, just subtract the frame origin
    func correctedWindowLocationForShapeTextView(for event: NSEvent, nodeId: UUID, textView: NSView) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)

        guard let node = currentNodes.first(where: { $0.id == nodeId }) else {
            return event.locationInWindow
        }

        let screenFrame = canvasRectToScreen(node.frame)

        let relX = loc.x - screenFrame.minX
        let relY = loc.y - screenFrame.minY

        let localX = relX / zoom
        let localY = relY / zoom

        return textView.convert(CGPoint(x: localX, y: localY), to: nil)
    }

    /// NSTextView coordinate correction (Note node)
    /// NSTextView defaults to isFlipped=true (y from top to bottom), which is consistent with the screen coordinate system and does not require flipping the y axis.
    func correctedWindowLocationForTextView(for event: NSEvent, nodeId: UUID, textView: NSView) -> CGPoint {
        let loc = convert(event.locationInWindow, from: nil)

        guard let node = currentNodes.first(where: { $0.id == nodeId }) else {
            return event.locationInWindow
        }

        let screenFrame = canvasRectToScreen(node.frame)
        let scaledHeaderHeight = CanvasNodeConstants.headerHeight * zoom
        let scaledDividerHeight: CGFloat = 1.0 * zoom

        // Relative position of the mouse in the NSTextView content area (screen coordinates)
        let relX = loc.x - screenFrame.minX
        let relY = loc.y - screenFrame.minY - scaledHeaderHeight - scaledDividerHeight

        // NSTextView is flipped (y from top to bottom), consistent with the screen coordinate direction, divided directly by zoom
        let localX = relX / zoom
        let localY = relY / zoom

        return textView.convert(CGPoint(x: localX, y: localY), to: nil)
    }
}
