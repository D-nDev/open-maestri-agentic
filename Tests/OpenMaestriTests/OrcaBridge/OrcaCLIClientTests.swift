import XCTest
@testable import open_maestri

final class OrcaCLIClientTests: XCTestCase {
    func testListUsesEnvironmentAndJSON() throws {
        let executor = RecordingOrcaExecutor()
        let client = OrcaCLIClient(executor: executor, environmentName: "vps")

        _ = try client.list(limit: 42)

        XCTAssertEqual(executor.calls, [[
            "terminal", "list", "--limit", "42", "--environment", "vps", "--json",
        ]])
    }

    func testReadUsesCursorWithoutShellInterpolation() throws {
        let executor = RecordingOrcaExecutor()
        let client = OrcaCLIClient(executor: executor)

        _ = try client.read(handle: "term_abc", cursor: "99", limit: 500)

        XCTAssertEqual(executor.calls, [[
            "terminal", "read", "--terminal", "term_abc", "--limit", "500",
            "--cursor", "99", "--json",
        ]])
    }

    func testQueuedSendWaitsForTUIIdleBeforeSending() throws {
        let executor = RecordingOrcaExecutor()
        let client = OrcaCLIClient(executor: executor)

        _ = try client.send(
            handle: "term_abc",
            text: "Read the connected note",
            mode: .queue,
            timeoutMilliseconds: 12_000
        )

        XCTAssertEqual(executor.calls, [
            [
                "terminal", "wait", "--terminal", "term_abc", "--for", "tui-idle",
                "--timeout-ms", "12000", "--json",
            ],
            [
                "terminal", "send", "--terminal", "term_abc", "--text",
                "Read the connected note", "--enter", "--json",
            ],
        ])
    }

    func testInterruptSendUsesExplicitInterruptFlag() throws {
        let executor = RecordingOrcaExecutor()
        let client = OrcaCLIClient(executor: executor)

        _ = try client.send(handle: "term_abc", text: "Stop and reread", mode: .interrupt)

        XCTAssertEqual(executor.calls, [[
            "terminal", "send", "--terminal", "term_abc", "--text", "Stop and reread",
            "--enter", "--interrupt", "--json",
        ]])
    }

    func testQueueDoesNotSendWhenIdleWaitFails() {
        let executor = RecordingOrcaExecutor()
        executor.outputs = [
            OrcaCommandOutput(stdout: "", stderr: "timed out", exitCode: 1),
        ]
        let client = OrcaCLIClient(executor: executor)

        XCTAssertThrowsError(
            try client.send(handle: "term_abc", text: "Do not deliver yet", mode: .queue)
        )
        XCTAssertEqual(executor.calls.count, 1)
        XCTAssertEqual(Array(executor.calls[0].prefix(2)), ["terminal", "wait"])
    }

    func testCommandFailureRedactsPromptFromError() {
        let executor = RecordingOrcaExecutor()
        executor.outputs = [
            OrcaCommandOutput(
                stdout: "",
                stderr: "could not deliver private context",
                exitCode: 1
            ),
        ]
        let client = OrcaCLIClient(executor: executor)

        XCTAssertThrowsError(
            try client.send(handle: "term_abc", text: "private context", mode: .interrupt)
        ) { error in
            XCTAssertFalse(error.localizedDescription.contains("private context"))
            XCTAssertTrue(error.localizedDescription.contains("<redacted>"))
        }
    }

    func testRejectsWhitespaceInRuntimeHandle() {
        let executor = RecordingOrcaExecutor()
        let client = OrcaCLIClient(executor: executor)

        XCTAssertThrowsError(try client.read(handle: "term bad"))
        XCTAssertTrue(executor.calls.isEmpty)
    }
}

private final class RecordingOrcaExecutor: OrcaCommandExecuting {
    var calls: [[String]] = []
    var outputs: [OrcaCommandOutput] = []

    func execute(arguments: [String]) throws -> OrcaCommandOutput {
        calls.append(arguments)
        if !outputs.isEmpty {
            return outputs.removeFirst()
        }
        return OrcaCommandOutput(stdout: "{\"ok\":true}\n", stderr: "", exitCode: 0)
    }
}
