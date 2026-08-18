import XCTest
@testable import open_maestri

final class OrcaCLIClientTests: XCTestCase {
    func testPendingAgenticEventsRebuildLatestWorkerState() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bridge = temporary.appendingPathComponent(
            "state-store/bridges/maestri",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let events = """
        {"type":"worker_started","run_id":"run-1","worker_id":"backend","parent_worker_id":"coordinator","terminal_handle":"term-1","role":"Backend","model":"grok"}
        {"type":"worker_status","run_id":"run-1","worker_id":"backend","status":"reviewing","model":"terra"}
        {"type":"worker_done","run_id":"run-1","worker_id":"backend","status":"completed"}

        """
        try events.write(
            to: bridge.appendingPathComponent("pending.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let workers = AgenticOSMetadataReader(environment: [
            "AGENTIC_OS_HOME": temporary.path,
        ]).loadWorkers()

        XCTAssertEqual(workers.count, 1)
        XCTAssertEqual(workers.first?.parentWorkerId, "coordinator")
        XCTAssertEqual(workers.first?.status, "completed")
        XCTAssertEqual(workers.first?.model, "terra")
    }

    func testDecodesLiveTerminalListContract() throws {
        let executor = RecordingOrcaExecutor()
        executor.outputs = [OrcaCommandOutput(
            stdout: """
            {"ok":true,"result":{"terminals":[{"handle":"term_1","worktreeId":"repo::/tmp/w","worktreePath":"/tmp/w","tabId":"tab_1","leafId":"leaf_1","connected":true,"writable":true,"orphaned":false}],"totalCount":1,"truncated":false},"_meta":{"runtimeId":"runtime_1"}}
            """,
            stderr: "",
            exitCode: 0
        )]
        let client = OrcaCLIClient(executor: executor)

        let result = try client.listTerminals(limit: 10)

        XCTAssertEqual(result.runtimeId, "runtime_1")
        XCTAssertEqual(result.terminals.first?.handle, "term_1")
        XCTAssertEqual(result.terminals.first?.stableIdentity, "repo::/tmp/w|tab_1|leaf_1")
    }

    func testDecodesCursorReadContract() throws {
        let executor = RecordingOrcaExecutor()
        executor.outputs = [OrcaCommandOutput(
            stdout: """
            {"ok":true,"result":{"terminal":{"handle":"term_1","status":"running","tail":["one","two"],"truncated":false,"limited":false,"oldestCursor":"0","nextCursor":"2","latestCursor":"2","returnedLineCount":2}},"_meta":{"runtimeId":"runtime_1"}}
            """,
            stderr: "",
            exitCode: 0
        )]
        let client = OrcaCLIClient(executor: executor)

        let result = try client.readTerminal(handle: "term_1", cursor: "0")

        XCTAssertEqual(result.tail, ["one", "two"])
        XCTAssertEqual(result.latestCursor, "2")
    }

    func testEnvironmentDiscoveryDoesNotTargetCurrentRemote() throws {
        let executor = RecordingOrcaExecutor()
        executor.outputs = [OrcaCommandOutput(
            stdout: """
            {"ok":true,"result":{"environments":[{"id":"vps-1","name":"oracle-vps","connected":true}]},"_meta":{"runtimeId":"local"}}
            """,
            stderr: "",
            exitCode: 0
        )]
        let client = OrcaCLIClient(executor: executor, environmentName: "already-remote")

        let environments = try client.listEnvironments()

        XCTAssertEqual(environments.first?.name, "oracle-vps")
        XCTAssertFalse(executor.calls[0].contains("--environment"))
    }

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
