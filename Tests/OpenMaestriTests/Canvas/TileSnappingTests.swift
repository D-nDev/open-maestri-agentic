import XCTest
import CoreGraphics
@testable import open_maestri

// Story 2.3 AC: Magnetic tile alignment test
final class TileSnappingTests: XCTestCase {

    // MARK: - Basic adsorption

    func testSnapToNearbyNodeEdge() {
        // When the left side of the dragged node is close to the right side of the target node, it should be automatically aligned
        let dragging = CGRect(x: 202, y: 100, width: 200, height: 150)  // x is 2 more than the right side of the target
        let other = CGRect(x: 0, y: 100, width: 200, height: 150)       // Target right x=200

        let (snapped, guidelines) = TileSnapping.snap(draggingFrame: dragging, against: [other])

        XCTAssertEqual(snapped.x, 200, accuracy: 0.5, "Should snap left edge to other's right edge")
        XCTAssertFalse(guidelines.isEmpty, "Should produce a guideline on snap")
    }

    func testNoXSnapWhenTooFar() {
        // X-direction distance 50 > threshold 12, no X-direction adsorption
        // The Y axis is deliberately staggered to avoid accidental adsorption in the Y direction
        let dragging = CGRect(x: 250, y: 500, width: 200, height: 150)
        let other = CGRect(x: 0, y: 0, width: 200, height: 150)

        let (snapped, guidelines) = TileSnapping.snap(draggingFrame: dragging, against: [other])

        XCTAssertEqual(snapped.x, 250, accuracy: 0.5, "Should not snap X when too far")
        let xGuidelines = guidelines.filter { $0.axis == .vertical }
        XCTAssertTrue(xGuidelines.isEmpty, "Should not produce X guideline when too far")
    }

    func testSnapThresholdIs12() {
        XCTAssertEqual(TileSnapping.snapThreshold, 12.0,
                       "Snap threshold should be 12 canvas units")
    }

    func testSnapVerticalAlignment() {
        // The upper edge is close to the lower edge of the target
        let dragging = CGRect(x: 100, y: 308, width: 200, height: 150)  // y=308, y=300 below the target
        let other = CGRect(x: 100, y: 100, width: 200, height: 200)     // Lower y=300

        let (snapped, guidelines) = TileSnapping.snap(draggingFrame: dragging, against: [other])

        XCTAssertEqual(snapped.y, 300, accuracy: 0.5, "Should snap top to other's bottom")
        XCTAssertTrue(guidelines.contains { $0.axis == .horizontal },
                      "Should produce horizontal guideline")
    }

    func testSnapProducesVerticalGuideline() {
        let dragging = CGRect(x: 202, y: 50, width: 200, height: 150)
        let other = CGRect(x: 0, y: 0, width: 200, height: 150)

        let (_, guidelines) = TileSnapping.snap(draggingFrame: dragging, against: [other])

        XCTAssertTrue(guidelines.contains { $0.axis == .vertical },
                      "X-axis snap should produce vertical guideline")
    }

    func testSnapWithMultipleNodes() {
        let dragging = CGRect(x: 408, y: 100, width: 200, height: 150)
        let node1 = CGRect(x: 0, y: 100, width: 200, height: 150)
        let node2 = CGRect(x: 200, y: 100, width: 200, height: 150)  // Right x=400, distance 8

        let (snapped, _) = TileSnapping.snap(draggingFrame: dragging, against: [node1, node2])

        XCTAssertEqual(snapped.x, 400, accuracy: 0.5, "Should snap to closest edge")
    }

    // MARK: - GuideLine

    func testGuideLineAxisValues() {
        let hLine = GuideLine(axis: .horizontal, position: 100, start: 0, end: 200)
        let vLine = GuideLine(axis: .vertical, position: 50, start: 10, end: 150)
        XCTAssertEqual(hLine.axis, .horizontal)
        XCTAssertEqual(vLine.axis, .vertical)
        XCTAssertEqual(hLine.position, 100)
        XCTAssertEqual(vLine.start, 10)
    }
}
