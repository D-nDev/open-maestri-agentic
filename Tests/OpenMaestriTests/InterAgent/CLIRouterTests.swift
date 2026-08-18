import XCTest
@testable import open_maestri

final class CLIRouterTests: XCTestCase {
    let router = CLIRouter.shared
    let testTerminalId = UUID()

    // MARK: - Routing basics (use async interface to avoid @MainActor deadlock)

    func testUnknownCommandReturnsError() async {
        let result = await router.routeAsync(args: ["foobar"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"), "Unknown command should return error: \(result)")
    }

    func testEmptyArgsReturnsError() async {
        let result = await router.routeAsync(args: [], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testAskCommandRequiresArgs() async {
        let result = await router.routeAsync(args: ["ask"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testCheckCommandRequiresArgs() async {
        let result = await router.routeAsync(args: ["check"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testRecruitRequiresName() async {
        let result = await router.routeAsync(args: ["recruit"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testDismissRequiresName() async {
        let result = await router.routeAsync(args: ["dismiss"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testConnectRequiresTwoArgs() async {
        let result = await router.routeAsync(args: ["connect", "A"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testPortalRequiresSubcommand() async {
        let result = await router.routeAsync(args: ["portal"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testPortalNavigateRequiresArgs() async {
        let result = await router.routeAsync(args: ["portal", "navigate", "MyPortal"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    // MARK: - Note

    func testNoteCommandRequiresSubcommand() async {
        let result = await router.routeAsync(args: ["note"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testNoteReadRequiresName() async {
        let result = await router.routeAsync(args: ["note", "read"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testNoteWriteReturnsError_NoteNotFound() async {
        // Note that does not exist should return error (path does not exist)
        let result = await router.routeAsync(args: ["note", "write", "NonExistentNote", "content"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"), "Write to non-existent note should error: \(result)")
    }

    func testNoteEditReturnsError_NoteNotFound() async {
        let result = await router.routeAsync(args: ["note", "edit", "NonExistentNote", "old", "new"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"), "Edit on non-existent note should error: \(result)")
    }

    func testNoteUnknownSubcommand() async {
        let result = await router.routeAsync(args: ["note", "foobar"], terminalId: testTerminalId)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    // MARK: - List/Check (async, requires @MainActor but no terminal connection)

    func testListWithMissingTerminalIdReturnsError() async {
        let result = await router.routeAsync(args: ["list"], terminalId: nil)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testCheckWithMissingTerminalIdReturnsError() async {
        let result = await router.routeAsync(args: ["check", "Agent"], terminalId: nil)
        XCTAssertTrue(result.hasPrefix("error:"))
    }

    func testListWithUnconnectedTerminalReturnsEmpty() async {
        let unconnectedId = UUID()
        let result = await router.routeAsync(args: ["list"], terminalId: unconnectedId)
        // There is a terminal ID but no connection, "No connections" should be returned
        XCTAssertFalse(result.hasPrefix("error: missing terminal ID"))
    }
}
