import Foundation

struct AgenticOSMetadataReader {
    private let homeURL: URL
    private let maximumFileSize = 5 * 1024 * 1024

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let path = environment["AGENTIC_OS_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentic-os").path
        homeURL = URL(fileURLWithPath: path).standardizedFileURL
    }

    func loadWorkers() -> [AgenticWorkerMetadata] {
        var workers: [String: AgenticWorkerMetadata] = [:]
        loadGatewayState(into: &workers)
        loadPendingEvents(into: &workers)
        return Array(workers.values)
    }

    private func loadGatewayState(into workers: inout [String: AgenticWorkerMetadata]) {
        let url = homeURL.appendingPathComponent("state-store/bridges/maestri/gateway-state.json")
        guard let root = loadJSONObject(at: url),
              let runs = root["runs"] as? [String: Any] else { return }
        for (runId, rawRun) in runs {
            guard let run = rawRun as? [String: Any],
                  let rawWorkers = run["workers"] as? [String: Any] else { continue }
            for (workerId, rawWorker) in rawWorkers {
                guard let worker = rawWorker as? [String: Any],
                      let handle = safeString(worker["terminal_handle"]) else { continue }
                workers[key(environment: safeString(worker["environment"]), handle: handle)] = AgenticWorkerMetadata(
                    runId: runId,
                    workerId: workerId,
                    parentWorkerId: safeString(worker["parent_worker_id"]),
                    terminalHandle: handle,
                    role: safeString(worker["role"]),
                    model: safeString(worker["model"]),
                    status: safeString(worker["status"]),
                    worktree: safeString(worker["worktree"]) ?? safeString(run["project_dir"]),
                    environment: safeString(worker["environment"])
                )
            }
        }
    }

    private func loadPendingEvents(into workers: inout [String: AgenticWorkerMetadata]) {
        let url = homeURL.appendingPathComponent("state-store/bridges/maestri/pending.jsonl")
        guard let data = boundedData(at: url),
              let content = String(data: data, encoding: .utf8) else { return }
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = safeString(event["type"]),
                  let runId = safeString(event["run_id"]),
                  let workerId = safeString(event["worker_id"]) else { continue }
            let environment = safeString(event["environment"])
            switch type {
            case "worker_started":
                guard let handle = safeString(event["terminal_handle"]) else { continue }
                let storageKey = key(environment: environment, handle: handle)
                let existing = workers[storageKey]
                workers[storageKey] = AgenticWorkerMetadata(
                    runId: runId,
                    workerId: workerId,
                    parentWorkerId: safeString(event["parent_worker_id"])
                        ?? existing?.parentWorkerId,
                    terminalHandle: handle,
                    role: safeString(event["role"]) ?? existing?.role,
                    model: safeString(event["model"]) ?? existing?.model,
                    status: safeString(event["status"]) ?? existing?.status,
                    worktree: safeString(event["worktree"])
                        ?? safeString(event["project_dir"])
                        ?? existing?.worktree,
                    environment: environment ?? existing?.environment
                )
            case "worker_status", "worker_done":
                guard let status = safeString(event["status"]) else { continue }
                let matchingKeys = workers.compactMap { storageKey, worker -> String? in
                    guard worker.runId == runId, worker.workerId == workerId,
                          environment == nil || worker.environment == environment else { return nil }
                    return storageKey
                }
                for storageKey in matchingKeys {
                    workers[storageKey]?.status = status
                    if let model = safeString(event["model"]) {
                        workers[storageKey]?.model = model
                    }
                }
            default:
                continue
            }
        }
    }

    private func loadJSONObject(at url: URL) -> [String: Any]? {
        guard let data = boundedData(at: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func boundedData(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumFileSize else { return nil }
        return try? Data(contentsOf: url)
    }

    private func safeString(_ raw: Any?) -> String? {
        guard let value = raw as? String,
              !value.isEmpty,
              value.count <= 512,
              !value.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        return value
    }

    private func key(environment: String?, handle: String) -> String {
        "\(environment ?? "local")|\(handle)"
    }
}
