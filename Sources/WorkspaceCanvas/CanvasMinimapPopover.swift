import SwiftUI

// MARK: - Canvas thumbnail pop-up layer

struct CanvasMinimapPopover: View {
    let nodes: [CanvasNode]
    let canvasOrigin: CGPoint
    let zoom: CGFloat
    let viewportSize: CGSize
    let onJumpTo: (CGPoint) -> Void

    /// Thumbnail fixed size
    private let mapSize = CGSize(width: 280, height: 180)

    var body: some View {
        VStack(spacing: 0) {
            if nodes.isEmpty {
                Text("canvas.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: mapSize.width, height: mapSize.height)
            } else {
                minimapCanvas
            }
        }
        .padding(12)
    }

    private var minimapCanvas: some View {
        let viewportFrame = CanvasMinimapLayout.viewportFrame(
            origin: canvasOrigin,
            viewportSize: viewportSize,
            zoom: zoom
        )
        let bounds = CanvasMinimapLayout.contentBounds(
            nodeFrames: nodes.map(\.frame),
            viewportFrame: viewportFrame
        )
        let scale = CanvasMinimapLayout.scale(bounds: bounds, mapSize: mapSize)

        return ZStack(alignment: .topLeading) {
            // Light gray background (canvas area)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.96))
                .frame(width: mapSize.width, height: mapSize.height)

            // Node color block
            ForEach(nodes, id: \.id) { node in
                let rect = CanvasMinimapLayout.scaledRect(
                    for: node.frame,
                    bounds: bounds,
                    scale: scale,
                    mapSize: mapSize
                )
                Button {
                    // Click on a node → Position the canvas to center the node
                    let target = CGPoint(
                        x: node.frame.midX - viewportFrame.width / 2,
                        y: node.frame.midY - viewportFrame.height / 2
                    )
                    onJumpTo(target)
                } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(nodeColor(for: node.content))
                        .frame(width: max(rect.width, 6), height: max(rect.height, 4))
                        .offset(x: rect.minX, y: rect.minY)
                }
                .buttonStyle(.plain)
            }

            // Current viewport indicator box
            let viewportRect = CanvasMinimapLayout.scaledRect(
                for: viewportFrame,
                bounds: bounds,
                scale: scale,
                mapSize: mapSize
            )
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.blue.opacity(0.6), lineWidth: 1.5)
                .frame(width: viewportRect.width, height: viewportRect.height)
                .offset(x: viewportRect.minX, y: viewportRect.minY)
        }
        .frame(width: mapSize.width, height: mapSize.height)
        .clipped()
    }

    /// Return the corresponding color according to the node type (consistent with the screenshot)
    private func nodeColor(for content: NodeContent) -> Color {
        switch content {
        case .terminal:
            return Color.blue                          // Blue (Terminal)
        case .stickyNote:
            return Color(red: 0.6, green: 0.88, blue: 0.88)  // Light cyan (notes)
        case .portal:
            return Color(red: 1.0, green: 0.92, blue: 0.6)   // Light yellow (Portal)
        case .fileTree:
            return Color(red: 1.0, green: 0.82, blue: 0.6)   // Light Orange (File Tree)
        case .text:
            return Color(red: 0.7, green: 0.7, blue: 0.9)    // Light purple (text label)
        case .shape:
            return Color(red: 0.9, green: 0.75, blue: 0.85)  // Light pink (hand-painted)
        case .stroke:
            return Color(red: 0.59, green: 0.51, blue: 0.94)  // Light purple blue (line/arrow)
        case .freehand:
            return Color(red: 0.6, green: 0.85, blue: 0.75)   // Light turquoise (hand-painted)
        }
    }
}

enum CanvasMinimapLayout {
    static func viewportFrame(origin: CGPoint, viewportSize: CGSize, zoom: CGFloat) -> CGRect {
        let safeZoom = max(zoom, 0.01)
        return CGRect(
            origin: origin,
            size: CGSize(
                width: max(1, viewportSize.width) / safeZoom,
                height: max(1, viewportSize.height) / safeZoom
            )
        )
    }

    static func contentBounds(
        nodeFrames: [CGRect],
        viewportFrame: CGRect,
        padding: CGFloat = 100
    ) -> CGRect {
        let combined = nodeFrames.reduce(viewportFrame) { $0.union($1) }
        return combined.insetBy(dx: -padding, dy: -padding)
    }

    static func scale(bounds: CGRect, mapSize: CGSize) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(mapSize.width / bounds.width, mapSize.height / bounds.height)
    }

    static func scaledRect(
        for frame: CGRect,
        bounds: CGRect,
        scale: CGFloat,
        mapSize: CGSize
    ) -> CGRect {
        let totalSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let offset = CGPoint(
            x: (mapSize.width - totalSize.width) / 2,
            y: (mapSize.height - totalSize.height) / 2
        )
        return CGRect(
            x: (frame.minX - bounds.minX) * scale + offset.x,
            y: (frame.minY - bounds.minY) * scale + offset.y,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }
}
