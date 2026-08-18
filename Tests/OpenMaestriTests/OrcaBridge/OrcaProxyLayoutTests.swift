import XCTest
@testable import open_maestri

final class OrcaProxyLayoutTests: XCTestCase {
    func testDiscoveryMirrorsOnlyAgenticOSWorkers() {
        XCTAssertFalse(OrcaTerminalDiscoveryPolicy.shouldMirror(agenticMetadata: nil))

        let worker = AgenticWorkerMetadata(
            runId: "run-1",
            workerId: "coordinator",
            parentWorkerId: nil,
            terminalHandle: "term-1",
            role: "Coordinator",
            model: "test-model",
            status: "running",
            worktree: "/tmp/worktree",
            environment: nil
        )
        XCTAssertTrue(OrcaTerminalDiscoveryPolicy.shouldMirror(agenticMetadata: worker))
    }

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

    func testClosedTerminalIsRemovedOnlyAfterGracePeriod() {
        let firstMissing = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(OrcaTerminalRetentionPolicy.shouldRemove(
            unseenSince: nil,
            now: firstMissing
        ))
        XCTAssertFalse(OrcaTerminalRetentionPolicy.shouldRemove(
            unseenSince: firstMissing,
            now: firstMissing.addingTimeInterval(5.9)
        ))
        XCTAssertTrue(OrcaTerminalRetentionPolicy.shouldRemove(
            unseenSince: firstMissing,
            now: firstMissing.addingTimeInterval(6)
        ))
    }

    func testAttemptStatusIsPresentedAsRunning() {
        XCTAssertEqual(OrcaTerminalStatus.normalized("attempt-1"), "running")
        XCTAssertEqual(OrcaTerminalStatus.normalized("attempt-42"), "running")
        XCTAssertEqual(OrcaTerminalStatus.normalized("running"), "running")
        XCTAssertEqual(OrcaTerminalStatus.normalized("completed"), "completed")
    }

    func testMinimapBoundsIncludeViewportAndNodes() {
        let viewport = CGRect(x: 10_000, y: 8_000, width: 1_200, height: 800)
        let node = CGRect(x: 10_400, y: 8_200, width: 400, height: 250)

        let bounds = CanvasMinimapLayout.contentBounds(
            nodeFrames: [node],
            viewportFrame: viewport,
            padding: 100
        )

        XCTAssertEqual(bounds, CGRect(x: 9_900, y: 7_900, width: 1_400, height: 1_000))
    }

    func testMinimapUsesActualViewportSize() {
        let frame = CanvasMinimapLayout.viewportFrame(
            origin: CGPoint(x: 500, y: 700),
            viewportSize: CGSize(width: 1_600, height: 900),
            zoom: 0.8
        )

        XCTAssertEqual(frame, CGRect(x: 500, y: 700, width: 2_000, height: 1_125))
    }
}
