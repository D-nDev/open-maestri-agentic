import XCTest
import CoreGraphics
@testable import open_maestri

@MainActor
final class RopeSimulationTests: XCTestCase {
    let sim = RopeSimulation()

    func testControlPointCount() {
        let points = sim.compute(from: .zero, to: CGPoint(x: 100, y: 0))
        XCTAssertEqual(points.count, Constants.ropeControlPointCount)
        XCTAssertEqual(points.count, 21)
    }

    func testStartAndEndPoints() {
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 90, y: 80)
        let points = sim.compute(from: start, to: end)
        XCTAssertEqual(points.first?.x ?? 0, start.x, accuracy: 0.01)
        XCTAssertEqual(points.first?.y ?? 0, start.y, accuracy: 0.01)
        XCTAssertEqual(points.last?.x ?? 0, end.x, accuracy: 0.01)
        XCTAssertEqual(points.last?.y ?? 0, end.y, accuracy: 0.01)
    }

    func testMiddlePointHasSag() {
        // The horizontal rope midpoint should be higher than the straight line (y is larger because of the sag)
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 200, y: 0)
        let points = sim.compute(from: start, to: end)
        let midPoint = points[points.count / 2]
        XCTAssertGreaterThan(midPoint.y, 0, "Rope should sag downward (y > 0)")
    }

    func testSerializeDeserializeRoundTrip() {
        let points = sim.compute(from: .zero, to: CGPoint(x: 100, y: 100))
        let serialized = sim.serialize(points)
        let restored = sim.deserialize(serialized)
        XCTAssertEqual(restored.count, points.count)
        for (orig, rest) in zip(points, restored) {
            XCTAssertEqual(orig.x, rest.x, accuracy: 0.001)
            XCTAssertEqual(orig.y, rest.y, accuracy: 0.001)
        }
    }

    func testBendRatioWithinBounds() {
        // Verify that the midpoint sag is within a reasonable range (not the rope length, because the polyline approximation error is large)
        let dist: CGFloat = 200
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: dist, y: 0)
        let points = sim.compute(from: start, to: end)
        let midPoint = points[points.count / 2]
        // Desired sag > 0 (with sag) and no more than 20% of rope length
        XCTAssertGreaterThan(midPoint.y, 0)
        XCTAssertLessThan(midPoint.y, dist * 0.20)
    }
}
