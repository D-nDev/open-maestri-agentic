import Foundation

struct OrcaCommandOutput: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol OrcaCommandExecuting {
    func execute(arguments: [String]) throws -> OrcaCommandOutput
}

enum OrcaBridgeError: LocalizedError, Equatable {
    case cliNotFound
    case invalidArgument(String)
    case commandFailed(arguments: [String], exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Orca CLI not found. Set OPEN_MAESTRI_ORCA_CLI or install Orca."
        case .invalidArgument(let message):
            return message
        case .commandFailed(let arguments, let exitCode, let message):
            let command = (["orca"] + Self.redactingTextValue(in: arguments)).joined(separator: " ")
            return "\(command) failed with exit \(exitCode): \(message)"
        }
    }

    private static func redactingTextValue(in arguments: [String]) -> [String] {
        var redacted = arguments
        if let textIndex = redacted.firstIndex(of: "--text"), textIndex + 1 < redacted.count {
            redacted[textIndex + 1] = "<redacted>"
        }
        return redacted
    }
}

final class ProcessOrcaCommandExecutor: OrcaCommandExecuting {
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func execute(arguments: [String]) throws -> OrcaCommandOutput {
        guard let executable = resolveExecutable() else {
            throw OrcaBridgeError.cliNotFound
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return OrcaCommandOutput(
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    private func resolveExecutable() -> String? {
        let fileManager = FileManager.default
        let candidates = [
            environment["OPEN_MAESTRI_ORCA_CLI"],
            environment["ORCA_CLI_COMMAND"],
            "/usr/local/bin/orca",
            "/Applications/Orca.app/Contents/Resources/bin/orca",
        ]
        return candidates.compactMap { $0 }.first(where: {
            fileManager.isExecutableFile(atPath: $0)
        })
    }
}

enum OrcaDeliveryMode: String, CaseIterable {
    case queue
    case interrupt
}

final class OrcaCLIClient {
    private let executor: any OrcaCommandExecuting
    private let environmentName: String?

    init(executor: any OrcaCommandExecuting, environmentName: String? = nil) {
        self.executor = executor
        self.environmentName = environmentName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    convenience init(environmentName: String? = nil) {
        self.init(executor: ProcessOrcaCommandExecutor(), environmentName: environmentName)
    }

    func list(limit: Int = 200) throws -> String {
        guard (1...1000).contains(limit) else {
            throw OrcaBridgeError.invalidArgument("limit must be between 1 and 1000")
        }
        return try run(["terminal", "list", "--limit", String(limit)])
    }

    func read(handle: String, cursor: String? = nil, limit: Int = 1000) throws -> String {
        try validateHandle(handle)
        guard (1...5000).contains(limit) else {
            throw OrcaBridgeError.invalidArgument("limit must be between 1 and 5000")
        }
        var arguments = ["terminal", "read", "--terminal", handle, "--limit", String(limit)]
        if let cursor, !cursor.isEmpty {
            arguments += ["--cursor", cursor]
        }
        return try run(arguments)
    }

    func send(
        handle: String,
        text: String,
        mode: OrcaDeliveryMode = .queue,
        timeoutMilliseconds: Int = 300_000
    ) throws -> String {
        try validateHandle(handle)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrcaBridgeError.invalidArgument("text must not be empty")
        }
        guard (1_000...3_600_000).contains(timeoutMilliseconds) else {
            throw OrcaBridgeError.invalidArgument("timeout-ms must be between 1000 and 3600000")
        }

        switch mode {
        case .queue:
            _ = try run([
                "terminal", "wait", "--terminal", handle,
                "--for", "tui-idle", "--timeout-ms", String(timeoutMilliseconds),
            ])
            return try run([
                "terminal", "send", "--terminal", handle,
                "--text", text, "--enter",
            ])
        case .interrupt:
            return try run([
                "terminal", "send", "--terminal", handle,
                "--text", text, "--enter", "--interrupt",
            ])
        }
    }

    private func validateHandle(_ handle: String) throws {
        guard !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !handle.contains(where: { $0.isWhitespace }) else {
            throw OrcaBridgeError.invalidArgument("terminal handle must be a non-empty token")
        }
    }

    private func run(_ baseArguments: [String]) throws -> String {
        var arguments = baseArguments
        if let environmentName, !environmentName.isEmpty {
            arguments += ["--environment", environmentName]
        }
        arguments.append("--json")

        let result = try executor.execute(arguments: arguments)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawMessage = message.isEmpty ? fallback : message
            throw OrcaBridgeError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: redactingTextValue(in: rawMessage, arguments: arguments)
            )
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func redactingTextValue(in message: String, arguments: [String]) -> String {
        guard let textIndex = arguments.firstIndex(of: "--text"), textIndex + 1 < arguments.count else {
            return message
        }
        return message.replacingOccurrences(of: arguments[textIndex + 1], with: "<redacted>")
    }
}
