import XCTest
@testable import open_maestri

final class OrcaProxyLayoutTests: XCTestCase {
    func testFirstProxyIsPlacedRelativeToVisibleCanvasOrigin() {
        let frame = OrcaProxyLayout.frame(index: 0, canvasOrigin: CGPoint(x: 9_800, y: 8_500))

        XCTAssertEqual(frame, CGRect(x: 9_920, y: 8_640, width: 400, height: 250))
    }

    func testProxyGridUsesThreeColumns() {
        let origin = CGPoint(x: 9_800, y: 8_500)

        XCTAssertEqual(
            OrcaProxyLayout.frame(index: 1, canvasOrigin: origin),
            CGRect(x: 10_360, y: 8_640, width: 400, height: 250)
        )
        XCTAssertEqual(
            OrcaProxyLayout.frame(index: 3, canvasOrigin: origin),
            CGRect(x: 9_920, y: 8_940, width: 400, height: 250)
        )
    }

    func testLegacyGridFrameMigratesToCanvasOrigin() {
        let migrated = OrcaProxyLayout.migratedLegacyFrame(
            CGRect(x: 560, y: 140, width: 400, height: 250),
            canvasOrigin: CGPoint(x: 9_800, y: 8_500)
        )

        XCTAssertEqual(migrated, CGRect(x: 10_360, y: 8_640, width: 400, height: 250))
    }

    func testMigrationPreservesManuallyMovedProxy() {
        let migrated = OrcaProxyLayout.migratedLegacyFrame(
            CGRect(x: 250, y: 325, width: 400, height: 250),
            canvasOrigin: CGPoint(x: 9_800, y: 8_500)
        )

        XCTAssertNil(migrated)
    }
}
