import SwiftUI

// MARK: - Canvas thumbnail pop-up layer

struct CanvasMinimapPopover: View {
    let nodes: [CanvasNode]
    let canvasOrigin: CGPoint
    let zoom: CGFloat
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
        let bounds = computeBounds()
        let scale = computeScale(bounds: bounds)

        return ZStack(alignment: .topLeading) {
            // Light gray background (canvas area)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.96))
                .frame(width: mapSize.width, height: mapSize.height)

            // Node color block
            ForEach(nodes, id: \.id) { node in
                let rect = scaledRect(for: node.frame, bounds: bounds, scale: scale)
                Button {
                    // Click on a node → Position the canvas to center the node
                    let viewportW: CGFloat = 800 / zoom
                    let viewportH: CGFloat = 600 / zoom
                    let target = CGPoint(
                        x: node.frame.midX - viewportW / 2,
                        y: node.frame.midY - viewportH / 2
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
            let viewportRect = scaledViewportRect(bounds: bounds, scale: scale)
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.blue.opacity(0.6), lineWidth: 1.5)
                .frame(width: viewportRect.width, height: viewportRect.height)
                .offset(x: viewportRect.minX, y: viewportRect.minY)
        }
        .frame(width: mapSize.width, height: mapSize.height)
        .clipped()
    }

    // MARK: - Coordinate calculation

    /// Calculate bounding boxes for all nodes (including some padding)
    private func computeBounds() -> CGRect {
        guard !nodes.isEmpty else { return .zero }
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for node in nodes {
            minX = min(minX, node.frame.minX)
            minY = min(minY, node.frame.minY)
            maxX = max(maxX, node.frame.maxX)
            maxY = max(maxY, node.frame.maxY)
        }
        // Add padding
        let pad: CGFloat = 100
        return CGRect(x: minX - pad, y: minY - pad,
                      width: maxX - minX + pad * 2,
                      height: maxY - minY + pad * 2)
    }

    /// Compute scaling (keep aspect ratio fit to mapSize)
    private func computeScale(bounds: CGRect) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(mapSize.width / bounds.width, mapSize.height / bounds.height)
    }

    /// Map canvas coordinates to thumbnail coordinates
    private func scaledRect(for frame: CGRect, bounds: CGRect, scale: CGFloat) -> CGRect {
        let x = (frame.minX - bounds.minX) * scale
        let y = (frame.minY - bounds.minY) * scale
        let w = frame.width * scale
        let h = frame.height * scale
        // Center offset
        let totalW = bounds.width * scale
        let totalH = bounds.height * scale
        let offsetX = (mapSize.width - totalW) / 2
        let offsetY = (mapSize.height - totalH) / 2
        return CGRect(x: x + offsetX, y: y + offsetY, width: w, height: h)
    }

    /// The position of the current viewport in the thumbnail
    private func scaledViewportRect(bounds: CGRect, scale: CGFloat) -> CGRect {
        let vpW: CGFloat = 800 / zoom  // Estimating viewport width
        let vpH: CGFloat = 600 / zoom  // Estimating viewport height
        let vpFrame = CGRect(x: canvasOrigin.x, y: canvasOrigin.y, width: vpW, height: vpH)
        return scaledRect(for: vpFrame, bounds: bounds, scale: scale)
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
