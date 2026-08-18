import Foundation
import OSLog

/// CLI command router: distributed to the corresponding Handler according to args[0]
final class CLIRouter {
    static let shared = CLIRouter()
    private let logger = Logger.make(category: "CLIRouter")
    private init() {}

    /// Asynchronous routing (InterAgentServer is directly awaited in the Task context)
    func routeAsync(args: [String], terminalId: UUID?) async -> String {
        guard let command = args.first else { return "error: empty command" }
        switch command {
        case "list":
            return await ListHandler.shared.handleAsync(args: args, terminalId: terminalId)
        case "ask":
            return await AskHandler.shared.handleAsync(args: args, terminalId: terminalId)
        case "check":
            return await CheckHandler.shared.handleAsync(args: args, terminalId: terminalId)
        case "note":
            return await NoteHandler.shared.handleAsync(args: args, terminalId: terminalId)
        case "portal":
            return await PortalHandler.shared.handleAsync(args: args, terminalId: terminalId)
        case "orca":
            return await OrcaBridgeHandler.shared.handleAsync(args: args, terminalId: terminalId)
        case "recruit", "dismiss", "connect", "role", "preset":
            return await MaestroHandlers.shared.handleAsync(args: args, terminalId: terminalId)
        case "debug":
            return buildDebugInfo(terminalId: terminalId)
        default:
            return "error: unknown command '\(command)'. Try 'omaestri list' for available commands."
        }
    }

    // MARK: - debug

    private func buildDebugInfo(terminalId: UUID?) -> String {
        let port = InterAgentServer.shared.port
        let tidStr = terminalId?.uuidString ?? "(none)"
        let commands = "list ask check note portal orca recruit dismiss connect role preset debug"
        return "open-maestri inter-agent server debug:\n  Server port: \(port)\n  Terminal ID: \(tidStr)\n  Commands: \(commands)"
    }
}
