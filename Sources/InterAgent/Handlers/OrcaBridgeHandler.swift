import Foundation

final class OrcaBridgeHandler {
    static let shared = OrcaBridgeHandler()

    private init() {}

    func handleAsync(args: [String], terminalId: UUID?) async -> String {
        guard terminalId != nil else { return "error: missing terminal ID" }
        guard args.count >= 2 else { return Self.usage }

        do {
            let parsed = try ParsedOrcaCommand(args: Array(args.dropFirst(2)))
            let client = OrcaCLIClient(environmentName: parsed.environment)
            switch args[1] {
            case "list":
                guard parsed.positionals.isEmpty else { return Self.usage }
                return try client.list(limit: parsed.limit ?? 200)
            case "read":
                guard parsed.positionals.count == 1 else { return Self.usage }
                return try client.read(
                    handle: parsed.positionals[0],
                    cursor: parsed.cursor,
                    limit: parsed.limit ?? 1000
                )
            case "send":
                guard parsed.positionals.count == 2 else { return Self.usage }
                return try client.send(
                    handle: parsed.positionals[0],
                    text: parsed.positionals[1],
                    mode: parsed.mode,
                    timeoutMilliseconds: parsed.timeoutMilliseconds
                )
            default:
                return Self.usage
            }
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    static let usage = """
    error: usage:
      omaestri orca list [--limit N] [--environment NAME]
      omaestri orca read HANDLE [--cursor N] [--limit N] [--environment NAME]
      omaestri orca send HANDLE "TEXT" [--mode queue|interrupt] [--timeout-ms N] [--environment NAME]
    """
}

private struct ParsedOrcaCommand {
    var positionals: [String] = []
    var environment: String?
    var cursor: String?
    var limit: Int?
    var mode: OrcaDeliveryMode = .queue
    var timeoutMilliseconds = 300_000

    init(args: [String]) throws {
        var index = 0
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--environment":
                environment = try Self.value(after: argument, args: args, index: &index)
            case "--cursor":
                cursor = try Self.value(after: argument, args: args, index: &index)
            case "--limit":
                let raw = try Self.value(after: argument, args: args, index: &index)
                guard let parsed = Int(raw) else {
                    throw OrcaBridgeError.invalidArgument("--limit requires an integer")
                }
                limit = parsed
            case "--mode":
                let raw = try Self.value(after: argument, args: args, index: &index)
                guard let parsed = OrcaDeliveryMode(rawValue: raw) else {
                    throw OrcaBridgeError.invalidArgument("--mode must be queue or interrupt")
                }
                mode = parsed
            case "--timeout-ms":
                let raw = try Self.value(after: argument, args: args, index: &index)
                guard let parsed = Int(raw) else {
                    throw OrcaBridgeError.invalidArgument("--timeout-ms requires an integer")
                }
                timeoutMilliseconds = parsed
            default:
                if argument.hasPrefix("--") {
                    throw OrcaBridgeError.invalidArgument("unknown option: \(argument)")
                }
                positionals.append(argument)
            }
            index += 1
        }
    }

    private static func value(after option: String, args: [String], index: inout Int) throws -> String {
        index += 1
        guard index < args.count else {
            throw OrcaBridgeError.invalidArgument("\(option) requires a value")
        }
        return args[index]
    }
}
