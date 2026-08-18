import Foundation
import OSLog

final class NoteHandler {
    static let shared = NoteHandler()
    private let logger = Logger.make(category: "NoteHandler")
    private let nm = NoteFileManager.shared
    private init() {}

    func handleAsync(args: [String], terminalId: UUID?) async -> String {
        guard args.count >= 2 else {
            return "error: usage: omaestri note <read|write|edit|create> ..."
        }
        switch args[1] {
        case "read":   return handleRead(args: args, terminalId: terminalId)
        case "write":  return handleWrite(args: args, terminalId: terminalId)
        case "edit":   return handleEdit(args: args, terminalId: terminalId)
        case "create": return await handleCreate(args: args, terminalId: terminalId)
        default: return "error: unknown note subcommand '\(args[1])'. Valid: read|write|edit|create"
        }
    }

    // MARK: - Read (FR35, FR36)

    private func handleRead(args: [String], terminalId: UUID?) -> String {
        guard args.count >= 3 else {
            return "error: usage: omaestri note read \"NoteName\""
        }
        let noteName = args[2]

        guard let filePath = resolveNotePath(name: noteName, terminalId: terminalId) else {
            return "error: note '\(noteName)' not found in connections"
        }

        do {
            return try nm.read(filePath: filePath)
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: - write (FR35 AC: complete replacement of Note content, canvas updated in real time)

    private func handleWrite(args: [String], terminalId: UUID?) -> String {
        guard args.count >= 4 else {
            return "error: usage: omaestri note write \"NoteName\" \"content\""
        }
        let noteName = args[2]
        let content  = args[3]

        guard let filePath = resolveNotePath(name: noteName, terminalId: terminalId) else {
            return "error: note '\(noteName)' not found in connections"
        }

        do {
            try nm.write(filePath: filePath, content: content)
            logger.debug("Note '\(noteName)' written (\(content.count) chars)")
            return "OK"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: - edit (FR35 AC: replace first matching text)

    private func handleEdit(args: [String], terminalId: UUID?) -> String {
        guard args.count >= 5 else {
            return "error: usage: omaestri note edit \"NoteName\" \"oldText\" \"newText\""
        }
        let noteName = args[2]
        let oldText  = args[3]
        let newText  = args[4]

        guard let filePath = resolveNotePath(name: noteName, terminalId: terminalId) else {
            return "error: note '\(noteName)' not found in connections"
        }

        do {
            try nm.edit(filePath: filePath, oldText: oldText, newText: newText)
            return "OK"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: - create (FR35 AC: Create a new Note in the canvas and connect the current terminal)

    private func handleCreate(args: [String], terminalId: UUID?) async -> String {
        let initialContent = args.count >= 3 ? args[2] : ""
        let noteName = "Note-\(UUID().uuidString.prefix(8))"
        let pm = PersistenceManager.shared

        // Find the workspace it belongs to through terminalId and write the correct workspaces/{id}/notes/ directory
        let workspaceId: UUID?
        if let tid = terminalId {
            workspaceId = await MainActor.run { TerminalManager.shared.terminalWorkspaceMap[tid] }
        } else {
            workspaceId = nil
        }

        do {
            let notesDir: URL
            if let wsId = workspaceId {
                notesDir = pm.notesDirURL(workspaceId: wsId)
            } else {
                // Fallback to global directory when workspace cannot be determined (should not happen)
                notesDir = pm.appDataURL.appendingPathComponent("notes")
            }
            try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
            let path = notesDir.appendingPathComponent("\(noteName).md").path
            try nm.write(filePath: path, content: initialContent)
            NoteRegistry.shared.register(name: noteName, filePath: path)
            logger.info("Note '\(noteName)' created at \(path)")
            return noteName
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    // MARK: - Note path analysis

    /// Resolving file paths through Note names
    /// Parsing strategy (priority order):
    /// 1. Find registered Notes from NoteRegistry (runtime cache)
    /// 2. Scan the notes/ directory under ~/.open-maestri/ for matching file names
    private func resolveNotePath(name: String, terminalId: UUID?) -> String? {
        // Strategy 1: Find from NoteRegistry
        if let path = NoteRegistry.shared.path(forName: name) {
            return path
        }

        // Strategy 2: Scan the notes directory of all workspaces
        let pm = PersistenceManager.shared
        let wsDir = pm.appDataURL.appendingPathComponent("workspaces")
        let fm = FileManager.default
        if let workspaceIds = try? fm.contentsOfDirectory(atPath: wsDir.path) {
            for wsId in workspaceIds {
                let notesDir = wsDir.appendingPathComponent("\(wsId)/notes")
                let candidates = [
                    notesDir.appendingPathComponent("\(name).md").path,
                    notesDir.appendingPathComponent(name).path,
                ]
                for path in candidates {
                    if fm.fileExists(atPath: path) { return path }
                }
                // Fuzzy match: file name contains name
                if let files = try? fm.contentsOfDirectory(atPath: notesDir.path) {
                    if let match = files.first(where: {
                        $0.lowercased().contains(name.lowercased()) && $0.hasSuffix(".md")
                    }) {
                        return notesDir.appendingPathComponent(match).path
                    }
                }
            }
        }

        // Strategy 3: Global notes directory (fallback)
        let globalNotesPath = pm.appDataURL.appendingPathComponent("notes/\(name).md").path
        if fm.fileExists(atPath: globalNotesPath) { return globalNotesPath }

        return nil
    }
}

// MARK: - NoteRegistry (runtime Note path cache)

/// Note node path registry, updated by canvas when creating/connecting Note
/// Allow NoteHandler to query Note paths in the HTTP thread without requiring @MainActor
final class NoteRegistry {
    static let shared = NoteRegistry()
    private var registry: [String: String] = [:]        // name → filePath
    private var nodeIdRegistry: [UUID: String] = [:]    // nodeId → name
    private let lock = NSLock()
    private init() {}

    func register(name: String, filePath: String, nodeId: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        registry[name] = filePath
        if let nodeId { nodeIdRegistry[nodeId] = name }
    }

    func unregister(name: String, nodeId: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        registry.removeValue(forKey: name)
        if let nodeId { nodeIdRegistry.removeValue(forKey: nodeId) }
    }

    /// Completely delete the two mappings after checking name through nodeId (called when node is deleted)
    func unregisterByNodeId(_ nodeId: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let name = nodeIdRegistry.removeValue(forKey: nodeId) {
            registry.removeValue(forKey: name)
        }
    }

    func path(forName name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return registry[name] ?? registry.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    func name(forNodeId nodeId: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return nodeIdRegistry[nodeId]
    }
}
