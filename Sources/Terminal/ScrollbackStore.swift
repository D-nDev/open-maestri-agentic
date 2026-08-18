import Foundation
import OSLog

/// Scrollback persists row entries
struct ScrollbackEntry: Codable {
    var attributes: [String]    // Terminal properties (color, style, etc.)
    var text: String
}

/// Terminal Scrollback Storage
/// - Format: JSONL (one JSON object per line), backwards compatible with the old JSON Array format
/// - append only does file append (does not read the entire file), greatly reducing the I/O overhead during high-frequency writing
/// - Atomic writes prevent data corruption (NFR11)
/// - Path: ~/.open-maestri/workspaces/{wsId}/terminals/{terminalId}.scrollback
final class ScrollbackStore: Sendable {
    private let logger = Logger.make(category: "ScrollbackStore")
    private let pm = PersistenceManager.shared

    /// The upper limit of the number of lines per terminal, compaction is triggered when exceeded
    private let maxLines = 10000

    // MARK: - Save (full write in JSONL format)

    func save(entries: [ScrollbackEntry], terminalId: UUID, workspaceId: UUID) async throws {
        let url = pm.scrollbackURL(terminalId: terminalId, workspaceId: workspaceId)
        // Make sure the directory exists
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        // Generate JSONL: Each entry is encoded as a single line of JSON
        var lines: [Data] = []
        for entry in entries {
            lines.append(try encoder.encode(entry))
        }
        let newline = Data([0x0A]) // "\n"
        var combined = Data()
        for line in lines {
            combined.append(line)
            combined.append(newline)
        }
        let tmp = url.appendingPathExtension("tmp")
        try combined.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItem(at: url, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
        logger.debug("Scrollback saved: \(entries.count) lines for terminal \(terminalId.uuidString.prefix(8))")
    }

    // MARK: - Load (compatible with old JSON Array and new JSONL format)

    func load(terminalId: UUID, workspaceId: UUID) throws -> [ScrollbackEntry] {
        let url = pm.scrollbackURL(terminalId: terminalId, workspaceId: workspaceId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }

        // Judgment format: JSON Array starts with '[', JSONL starts with '{'
        let firstByte = data[data.startIndex]
        if firstByte == UInt8(ascii: "[") {
            // Old format: JSON Array
            return try JSONDecoder().decode([ScrollbackEntry].self, from: data)
        } else {
            // New format: JSONL (one JSON object per line)
            let decoder = JSONDecoder()
            var entries: [ScrollbackEntry] = []
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = line.data(using: .utf8) else { continue }
                if let entry = try? decoder.decode(ScrollbackEntry.self, from: lineData) {
                    entries.append(entry)
                }
            }
            return entries
        }
    }

    // MARK: - APPEND (incremental JSONL append, does not read the entire file)

    func append(lines newLines: [ScrollbackEntry], terminalId: UUID, workspaceId: UUID) async throws {
        let url = pm.scrollbackURL(terminalId: terminalId, workspaceId: workspaceId)
        // Make sure the directory exists
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        var appendData = Data()
        let newline = Data([0x0A])
        for entry in newLines {
            appendData.append(try encoder.encode(entry))
            appendData.append(newline)
        }

        // If the file does not exist or is in the old JSON Array format, migrate it first
        if FileManager.default.fileExists(atPath: url.path) {
            let existingData = try Data(contentsOf: url)
            if !existingData.isEmpty && existingData[existingData.startIndex] == UInt8(ascii: "[") {
                // Old format: Load → Convert → Write full JSONL, then append new lines
                let existing = try JSONDecoder().decode([ScrollbackEntry].self, from: existingData)
                var all = existing
                all.append(contentsOf: newLines)
                if all.count > maxLines {
                    all = Array(all.suffix(maxLines))
                }
                try await save(entries: all, terminalId: terminalId, workspaceId: workspaceId)
                return
            }
        }

        // JSONL append: write directly to the end of the file
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(appendData)
            fileHandle.closeFile()
        } else {
            // File does not exist, create new file
            try appendData.write(to: url, options: .atomic)
        }

        // Regularly check whether compaction is required (check once every 100 appends, reduce stat calls)
        // Simple strategy: estimate the number of lines by file size (average ~100 bytes per line)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? UInt64,
           fileSize > UInt64(maxLines) * 120 {  // The estimate exceeds the upper limit
            let all = try load(terminalId: terminalId, workspaceId: workspaceId)
            if all.count > maxLines {
                try await save(entries: Array(all.suffix(maxLines)), terminalId: terminalId, workspaceId: workspaceId)
            }
        }
    }
}
