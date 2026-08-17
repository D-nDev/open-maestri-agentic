import Foundation

struct OrcaResponseMeta: Decodable, Equatable, Sendable {
    let runtimeId: String?
}

struct OrcaAPIEnvelope<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
    let meta: OrcaResponseMeta?

    private enum CodingKeys: String, CodingKey {
        case ok, result
        case meta = "_meta"
    }
}

struct OrcaTerminalListResult: Decodable, Sendable {
    let terminals: [OrcaTerminalDescriptor]
    let totalCount: Int?
    let truncated: Bool?
}

struct OrcaTerminalDescriptor: Decodable, Equatable, Identifiable, Sendable {
    var id: String { handle }

    let handle: String
    let ptyId: String?
    let incarnationId: String?
    let orphaned: Bool
    let worktreeId: String?
    let worktreePath: String?
    let branch: String?
    let tabId: String?
    let leafId: String?
    let title: String?
    let connected: Bool
    let writable: Bool
    let lastOutputAt: Int64?
    let preview: String?

    var stableIdentity: String {
        [worktreeId, tabId, leafId, ptyId]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    private enum CodingKeys: String, CodingKey {
        case handle, ptyId, incarnationId, orphaned, worktreeId, worktreePath
        case branch, tabId, leafId, title, connected, writable, lastOutputAt, preview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handle = try container.decode(String.self, forKey: .handle)
        ptyId = try container.decodeIfPresent(String.self, forKey: .ptyId)
        incarnationId = try container.decodeIfPresent(String.self, forKey: .incarnationId)
        orphaned = try container.decodeIfPresent(Bool.self, forKey: .orphaned) ?? false
        worktreeId = try container.decodeIfPresent(String.self, forKey: .worktreeId)
        worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        tabId = try container.decodeIfPresent(String.self, forKey: .tabId)
        leafId = try container.decodeIfPresent(String.self, forKey: .leafId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected) ?? true
        writable = try container.decodeIfPresent(Bool.self, forKey: .writable) ?? false
        lastOutputAt = try container.decodeIfPresent(Int64.self, forKey: .lastOutputAt)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
    }
}

struct OrcaTerminalReadResult: Decodable, Sendable {
    let terminal: OrcaTerminalReadSnapshot
}

struct OrcaTerminalReadSnapshot: Decodable, Equatable, Sendable {
    let handle: String
    let status: String
    let tail: [String]
    let truncated: Bool
    let limited: Bool
    let oldestCursor: String?
    let nextCursor: String?
    let latestCursor: String?
    let returnedLineCount: Int

    private enum CodingKeys: String, CodingKey {
        case handle, status, tail, truncated, limited
        case oldestCursor, nextCursor, latestCursor, returnedLineCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handle = try container.decode(String.self, forKey: .handle)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        tail = try container.decodeIfPresent([String].self, forKey: .tail) ?? []
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        limited = try container.decodeIfPresent(Bool.self, forKey: .limited) ?? false
        oldestCursor = try container.decodeIfPresent(String.self, forKey: .oldestCursor)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
        latestCursor = try container.decodeIfPresent(String.self, forKey: .latestCursor)
        returnedLineCount = try container.decodeIfPresent(Int.self, forKey: .returnedLineCount) ?? tail.count
    }
}

struct OrcaEnvironmentListResult: Decodable, Sendable {
    let environments: [OrcaEnvironmentDescriptor]
}

struct OrcaEnvironmentDescriptor: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let connected: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, connected, reachable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try container.decodeIfPresent(String.self, forKey: .id)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .displayName)
        id = decodedId ?? decodedName ?? "remote"
        name = decodedName ?? decodedId ?? "remote"
        connected = try container.decodeIfPresent(Bool.self, forKey: .connected)
            ?? container.decodeIfPresent(Bool.self, forKey: .reachable)
    }
}

struct OrcaWorkerListResult: Decodable, Sendable {
    let workers: [OrcaWorkerDescriptor]
}

struct OrcaWorkerDescriptor: Decodable, Equatable, Sendable {
    let taskId: String?
    let parentTaskId: String?
    let terminalHandle: String?
    let displayName: String?
    let role: String?
    let model: String?
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case taskId, taskID, task_id
        case parentTaskId, parentTaskID, parent_task_id
        case parentWorkerId, parent_worker_id
        case terminalHandle, terminal_handle, handle
        case displayName, display_name, name
        case role, agent, agentId, agent_id
        case model, modelId, model_id
        case status, workerState, worker_state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = Self.firstString(container, keys: [.taskId, .taskID, .task_id])
        parentTaskId = Self.firstString(
            container,
            keys: [.parentTaskId, .parentTaskID, .parent_task_id, .parentWorkerId, .parent_worker_id]
        )
        terminalHandle = Self.firstString(container, keys: [.terminalHandle, .terminal_handle, .handle])
        displayName = Self.firstString(container, keys: [.displayName, .display_name, .name])
        role = Self.firstString(container, keys: [.role, .agent, .agentId, .agent_id])
        model = Self.firstString(container, keys: [.model, .modelId, .model_id])
        status = Self.firstString(container, keys: [.status, .workerState, .worker_state])
    }

    private static func firstString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}
