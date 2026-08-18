import Foundation
import CoreGraphics

/// Magnetic tile alignment (Story 2.3 AC)
/// - Wall matching: node edges aligned to edges of neighboring nodes
/// - Gap filling: filling the gaps between nodes
/// - Does not rely on fixed grid, adapts based on actual layout
struct TileSnapping {
    /// Magnetic adsorption threshold (canvas coordinates, automatically aligned when less than this distance)
    static let snapThreshold: CGFloat = 12.0

    /// Proximity filter expansion radius (canvas coordinates): Only nodes within this range of the dragged node are considered for snap participation
    /// Set to snapThreshold * 50 to cover most reasonable layout spacing and reduce invalid calculations of distant nodes
    private static let proximityRadius: CGFloat = 600.0

    // MARK: - Main entrance

    /// Calculate the magnetic target position of the dragged node
    /// - Parameters:
    ///   - draggingFrame: current frame (canvas coordinates) of the node being dragged
    ///   - otherFrames: frames (canvas coordinates) of all other nodes
    /// - Returns: Origin after adsorption, and guide list (used for UI to display blue guide lines)
    static func snap(
        draggingFrame: CGRect,
        against otherFrames: [CGRect]
    ) -> (snappedOrigin: CGPoint, guidelines: [GuideLine]) {
        var x = draggingFrame.origin.x
        var y = draggingFrame.origin.y
        var guidelines: [GuideLine] = []

        let dW = draggingFrame.width
        let dH = draggingFrame.height
        let dMinX = x, dMaxX = x + dW
        let dMinY = y, dMaxY = y + dH

        var bestDX: CGFloat = snapThreshold + 1
        var bestDY: CGFloat = snapThreshold + 1

        // Pre-filtering: only do snap calculations on nodes within the proximityRadius range of the dragged node
        let expandedFrame = draggingFrame.insetBy(dx: -proximityRadius, dy: -proximityRadius)

        for other in otherFrames {
            // Spatial filtering: Skip nodes too far from the dragged node
            guard expandedFrame.intersects(other) else { continue }
            let oMinX = other.minX, oMaxX = other.maxX
            let oMinY = other.minY, oMaxY = other.maxY

            // Wall matching X: left/right alignment
            let candidatesX: [(CGFloat, CGFloat, GuideAxis)] = [
                (dMinX, oMinX, .vertical),   // Align left to left
                (dMinX, oMaxX, .vertical),   // Align left to right
                (dMaxX, oMinX, .vertical),   // Align right to left
                (dMaxX, oMaxX, .vertical),   // Align right to right
            ]
            for (da, oa, axis) in candidatesX {
                let dist = abs(da - oa)
                if dist < snapThreshold && dist < bestDX {
                    bestDX = dist
                    let delta = oa - da
                    x = dMinX + delta
                    guidelines.removeAll { $0.axis == .vertical }
                    guidelines.append(GuideLine(
                        axis: axis,
                        position: oa,
                        start: min(dMinY, oMinY) - 20,
                        end: max(dMaxY, oMaxY) + 20
                    ))
                }
            }

            // Wall matching Y: top/bottom alignment
            let candidatesY: [(CGFloat, CGFloat, GuideAxis)] = [
                (dMinY, oMinY, .horizontal),
                (dMinY, oMaxY, .horizontal),
                (dMaxY, oMinY, .horizontal),
                (dMaxY, oMaxY, .horizontal),
            ]
            for (da, oa, axis) in candidatesY {
                let dist = abs(da - oa)
                if dist < snapThreshold && dist < bestDY {
                    bestDY = dist
                    let delta = oa - da
                    y = dMinY + delta
                    guidelines.removeAll { $0.axis == .horizontal }
                    guidelines.append(GuideLine(
                        axis: axis,
                        position: oa,
                        start: min(dMinX, oMinX) - 20,
                        end: max(dMaxX, oMaxX) + 20
                    ))
                }
            }
        }
        return (CGPoint(x: x, y: y), guidelines)
    }
}

// MARK: - Reference line data

enum GuideAxis { case horizontal, vertical }

struct GuideLine {
    let axis: GuideAxis
    let position: CGFloat   // x (vertical line) or y (horizontal line)
    let start: CGFloat      // Starting point of line segment
    let end: CGFloat        // End point of line segment
}
