import XCTest
@testable import open_maestri

/// Test the Agent name matching logic of AskHandler/CheckHandler
@MainActor
final class AgentMatchingTests: XCTestCase {
    var tm: TerminalManager!

    override func setUp() async throws {
        tm = TerminalManager.shared
    }

    // MARK: - agentName matches

    func testAskHandlerMatchesByAgentName() async {
        // Simulate agentName set by Maestro recruit
        let recruitId = UUID()
        let preset = AgentPreset.defaults.first { $0.agentType == "claude_code" } ?? AgentPreset.defaults[0]
        let session = tm.createTerminal(id: recruitId, workingDirectory: "/tmp", preset: preset)
        session.agentName = "Builder"  // Actual name of Maestro setting

        // AskHandler should be able to find the terminal via "Builder"
        let cm = ConnectionManager.shared
        let callerId = UUID()
        let callerPreset = AgentPreset.defaults.last!
        _ = tm.createTerminal(id: callerId, workingDirectory: "/tmp", preset: callerPreset)
        _ = cm.connectTerminals(idA: callerId, idB: recruitId, serverPort: 0)

        let result = await AskHandler.shared.handleAsync(
            args: ["ask", "Builder", "hello"],
            terminalId: callerId
        )

        // "not found" should not be returned
        XCTAssertFalse(result.contains("not found"), "agentName='Builder' 应能被找到，实际返回：\(result)")

        // Cleanup
        cm.disconnectAll(involvedNode: callerId)
        tm.removeTerminal(id: callerId)
        tm.removeTerminal(id: recruitId)
    }

    func testAskHandlerMatchesByCommand() async {
        // When there is no agentName, match by command name
        let termId = UUID()
        let preset = AgentPreset(id: UUID(), name: "Shell", command: "zsh", icon: "terminal",
                                 agentType: "generic_shell", color: "#8E8E93", isActive: true, isBuiltIn: true)
        _ = tm.createTerminal(id: termId, workingDirectory: "/tmp", preset: preset)

        let callerId = UUID()
        let callerPreset = AgentPreset.defaults.last!
        _ = tm.createTerminal(id: callerId, workingDirectory: "/tmp", preset: callerPreset)
        let cm = ConnectionManager.shared
        _ = cm.connectTerminals(idA: callerId, idB: termId, serverPort: 0)

        let result = await AskHandler.shared.handleAsync(
            args: ["ask", "zsh", "hello"],
            terminalId: callerId
        )
        XCTAssertFalse(result.contains("not found"),
                       "command='zsh' 应能被找到，实际：\(result)")

        cm.disconnectAll(involvedNode: callerId)
        tm.removeTerminal(id: callerId)
        tm.removeTerminal(id: termId)
    }

    func testAskHandlerReturnsNotFoundForUnknownName() async {
        let callerId = UUID()
        let preset = AgentPreset.defaults.last!
        _ = tm.createTerminal(id: callerId, workingDirectory: "/tmp", preset: preset)

        let result = await AskHandler.shared.handleAsync(
            args: ["ask", "NonExistentAgent99", "hello"],
            terminalId: callerId
        )
        XCTAssertTrue(result.contains("not found"),
                      "未知 agent 应返回 not found，实际：\(result)")

        tm.removeTerminal(id: callerId)
    }
}
