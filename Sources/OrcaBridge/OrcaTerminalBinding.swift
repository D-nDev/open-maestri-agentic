import Foundation

struct OrcaTerminalBindingDocument: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion = Self.currentSchemaVersion
    var workspaceId: UUID
    var bindings: [OrcaTerminalBinding] = []
}
struct OrcaTerminalBinding: Codable, Equatable, Identifiable {
    var id: UUID { nodeId }

    var nodeId: UUID
    var environment: String?
    var stableIdentity: String
    var handle: String
    var incarnationId: String?
    var worktreePath: String?
    var runId: String?
    var workerId: String?
    var parentWorkerId: String?
    var lastCursor: String?
    var lastSeenAt: Date
    var noteHashes: [String: String] = [:]
}

struct OrcaTerminalRuntimeState: Equatable {
    var nodeId: UUID
    var environment: String?
    var handle: String
    var title: String
    var role: String?
    var model: String?
    var runId: String?
    var workerId: String?
    var parentWorkerId: String?
    var worktreePath: String?
    var branch: String?
    var status: String
    var output: [String]
    var connected: Bool
    var writable: Bool
    var orphaned: Bool
    var lastUpdatedAt: Date
    var errorMessage: String?

    var environmentLabel: String { environment ?? "local" }
}

struct AgenticWorkerMetadata: Equatable, Sendable {
    var runId: String
    var workerId: String
    var parentWorkerId: String?
    var terminalHandle: String
    var role: String?
    var model: String?
    var status: String?
    var worktree: String?
    var environment: String?
}
