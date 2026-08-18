import SwiftUI
import AppKit
import CoreGraphics

/// Wrap MinimapView (NSView) as a SwiftUI view
struct MinimapRepresentable: NSViewRepresentable {
    var nodeFrames: [CGRect]
    var canvasOrigin: CGPoint
    var zoom: CGFloat
    var onJumpTo: ((CGPoint) -> Void)?

    func makeNSView(context: Context) -> MinimapView {
        let view = MinimapView()
        view.onJumpTo = onJumpTo
        return view
    }

    func updateNSView(_ nsView: MinimapView, context: Context) {
        // Estimate current viewport size based on container view size and zoom
        let viewportWidth: CGFloat = 800 / zoom
        let viewportHeight: CGFloat = 500 / zoom
        let viewportRect = CGRect(
            x: canvasOrigin.x,
            y: canvasOrigin.y,
            width: viewportWidth,
            height: viewportHeight
        )
        nsView.update(nodes: nodeFrames, viewport: viewportRect)
        nsView.onJumpTo = onJumpTo
    }
}
