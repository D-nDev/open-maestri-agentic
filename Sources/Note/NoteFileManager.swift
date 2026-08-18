import Foundation
import OSLog

/// Note File Manager
/// - Note contents are stored as .md files
/// - Supports two storage modes: managed (~/.open-maestri/workspaces/{id}/notes/) and custom (any path)
/// - All file I/O via atomic writes via PersistenceManager
final class NoteFileManager {
    static let shared = NoteFileManager()
    private let logger = Logger.make(category: "NoteFileManager")
    private let pm = PersistenceManager.shared
    private init() {}

    // MARK: - Read

    /// Read Note content
    /// - Parameter filePath: .md file absolute path
    /// - Returns: file content string
    func read(filePath: String) throws -> String {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw MaestriError.noteReadFailed("File not found: \(filePath)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Read Note content (with line range)
    /// The format is consistent with Maestri CLI: `[14 lines total]\n1 content...`
    func readWithLineRange(filePath: String, offset: Int? = nil, limit: Int? = nil) throws -> String {
        let content = try read(filePath: filePath)
        let lines = content.components(separatedBy: "\n")
        let total = lines.count

        let start = max(0, (offset ?? 1) - 1)
        let end = min(total, start + (limit ?? total))
        let selectedLines = Array(lines[start..<end])

        let header: String
        if let o = offset, let l = limit {
            header = "[lines \(o)-\(o + l - 1) of \(total)]"
        } else {
            header = "[\(total) lines total]"
        }

        let numbered = selectedLines.enumerated().map { idx, line in
            "\(start + idx + 1)    \(line)"
        }.joined(separator: "\n")

        return "\(header)\n\(numbered)"
    }

    // MARK: - Write

    /// Completely replace Note content
    func write(filePath: String, content: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let data = Data(content.utf8)
        // Make sure the parent directory exists
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItem(at: url, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
        logger.debug("Note written: \(filePath)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .noteFileDidChange,
                object: nil,
                userInfo: ["filePath": filePath, "content": content]
            )
        }
    }

    /// Partial editing (replaces first matching text)
    func edit(filePath: String, oldText: String, newText: String) throws {
        let current = try read(filePath: filePath)
        guard current.contains(oldText) else {
            throw MaestriError.noteWriteFailed("Text '\(oldText)' not found in note")
        }
        let updated = current.replacingOccurrences(of: oldText, with: newText, range: current.range(of: oldText))
        try write(filePath: filePath, content: updated)
    }

    // MARK: - Path Management

    /// Generate managed paths for new Notes
    func managedPath(workspaceId: UUID, noteName: String) -> String {
        pm.notesDirURL(workspaceId: workspaceId)
            .appendingPathComponent("\(sanitizeFilename(noteName)).md")
            .path
    }

    /// Create new Note file (empty content)
    func createNote(workspaceId: UUID, name: String) throws -> String {
        let path = managedPath(workspaceId: workspaceId, noteName: name)
        if !FileManager.default.fileExists(atPath: path) {
            try write(filePath: path, content: "")
        }
        return path
    }

    // MARK: - Note Chain traversal (FR30)

    /// Traverse the Note Chain and collect all connected Note contents
    /// - Parameters:
    ///   - entryNote: filePath of entry Note
    ///   - visited: visited path collection (to prevent loops)
    func readChain(entryNotePath: String, visited: inout Set<String>) throws -> String {
        guard !visited.contains(entryNotePath) else { return "" }
        visited.insert(entryNotePath)
        let content = try read(filePath: entryNotePath)
        return content
    }

    // MARK: - Tools

    private func sanitizeFilename(_ name: String) -> String {
        name.components(separatedBy: .init(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
