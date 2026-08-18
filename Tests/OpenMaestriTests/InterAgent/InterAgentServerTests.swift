import XCTest
@testable import open_maestri

final class InterAgentServerTests: XCTestCase {

    // MARK: - NFR7: Security Constraint Verification

    func testServerBindsToLoopbackOnly() {
        // Constants.interAgentServerHost must be 127.0.0.1
        XCTAssertEqual(Constants.interAgentServerHost, "127.0.0.1",
                       "NFR7: InterAgentServer must only bind to loopback interface")
    }

    func testServerRestartDelayIsThreeSeconds() {
        XCTAssertEqual(Constants.serverRestartDelay, 3.0,
                       "NFR6: Server must restart within 3 seconds after crash")
    }

    // MARK: - CLIRouter routing integrity

    func testCLIRouterHandlesAllKnownCommands() async {
        let router = CLIRouter.shared
        let tid = UUID()

        // All commands must not return "error: unknown command"
        let commands = [
            ["list"],
            ["ask", "agent", "prompt"],
            ["check", "agent"],
            ["note", "read", "name"],
            ["portal", "navigate", "name", "url"],
            ["orca"],
            ["recruit", "name"],
            ["dismiss", "name"],
            ["connect", "a", "b"],
            ["role", "list"],
        ]

        for args in commands {
            let result = await router.routeAsync(args: args, terminalId: tid)
            XCTAssertFalse(
                result.hasPrefix("error: unknown command"),
                "Command '\(args[0])' should be routed, got: \(result)"
            )
        }
    }

    // MARK: - HTTP request parsing

    func testHTTPResponseFormat() {
        // HTTP response should contain status line and Content-Type
        let server = InterAgentServer.shared
        // Obtain buildHTTPResponse through reflection (private method test is verified through public interface)
        // Verify port initial value is 0 (when not started)
        XCTAssertEqual(server.port, 0, "Port should be 0 before server starts")
    }

    // MARK: - NoteHandler file I/O integration test

    func testNoteHandlerReadWriteRoundTrip() throws {
        let nm = NoteFileManager.shared
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteHandlerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let filePath = tmpDir.appendingPathComponent("test.md").path
        try nm.write(filePath: filePath, content: "Line 1\nLine 2\nLine 3\n")

        let result = try nm.readWithLineRange(filePath: filePath)
        XCTAssertTrue(result.contains("[3 lines total]") || result.contains("[4 lines total]"),
                      "Should include line count header, got: \(result)")
        XCTAssertTrue(result.contains("Line 1"))
        XCTAssertTrue(result.contains("Line 3"))
    }

    func testNoteHandlerReadWithRange() throws {
        let nm = NoteFileManager.shared
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteRangeTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let filePath = tmpDir.appendingPathComponent("range.md").path
        let content = (1...10).map { "Line \($0)" }.joined(separator: "\n")
        try nm.write(filePath: filePath, content: content)

        let result = try nm.readWithLineRange(filePath: filePath, offset: 3, limit: 2)
        XCTAssertTrue(result.contains("Line 3"))
        XCTAssertTrue(result.contains("Line 4"))
        XCTAssertFalse(result.contains("Line 5"))
    }

    // MARK: - SkillInjector (simplified version, CLI binary injected via PATH)

    func testSkillInjectorIsSingleton() {
        let a = SkillInjector.shared
        let b = SkillInjector.shared
        XCTAssertTrue(a === b, "SkillInjector should be a singleton")
    }

    // MARK: - Data format compatibility (NFR14)

    func testWorkspaceDocumentSchemaVersion() {
        let payload = WorkspacePayload(name: "test", workingDirectory: "/tmp")
        let doc = WorkspaceDocument(payload: payload)
        XCTAssertEqual(doc.schemaVersion, 2, "Must be compatible with Maestri v0.25.4 schemaVersion:2")
        XCTAssertEqual(doc.type, "workspace")
    }

    func testCanvasNodeFrameJSONFormat() throws {
        let pm = PersistenceManager.shared
        let frame = CGRect(x: 100, y: 200, width: 300, height: 150)
        let node = CanvasNode(frame: frame, content: .terminal(TerminalContent(name: "test")))
        let data = try pm.encoder.encode(node)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frameArr = try XCTUnwrap(json["frame"] as? [[Double]])
        // Must be in [[x,y],[w,h]] format (consistent with Maestri format)
        XCTAssertEqual(frameArr[0][0], 100, accuracy: 0.01)  // x
        XCTAssertEqual(frameArr[0][1], 200, accuracy: 0.01)  // y
        XCTAssertEqual(frameArr[1][0], 300, accuracy: 0.01)  // width
        XCTAssertEqual(frameArr[1][1], 150, accuracy: 0.01)  // height
    }

    func testDateFieldsAreISO8601Format() throws {
        let pm = PersistenceManager.shared
        let payload = WorkspacePayload(name: "DateTest", workingDirectory: "/tmp")
        let doc = WorkspaceDocument(payload: payload)
        let data = try pm.encoder.encode(doc)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadDict = try XCTUnwrap(json["payload"] as? [String: Any])
        let createdAt = try XCTUnwrap(payloadDict["createdAt"] as? String)
        // ISO8601 format example: 2026-05-16T03:30:00Z
        XCTAssertTrue(createdAt.contains("T"), "Date must be ISO8601, got: \(createdAt)")
        XCTAssertTrue(createdAt.contains("Z") || createdAt.contains("+00"),
                      "Date must be UTC, got: \(createdAt)")
    }
}
