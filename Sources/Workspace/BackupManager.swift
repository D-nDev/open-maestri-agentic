import OSLog
import Foundation

/// Backup and Recovery Manager
/// - Automatic hourly generation of .omaestribak backups (list of file paths JSON)
/// - Supports restoring all workspace data from backup files
/// - Support exporting full backup to user-specified path/import recovery from external files
final class BackupManager {
    static let shared = BackupManager()
    private let logger = Logger.make(category: "BackupManager")
    private var timer: Timer?
    private let pm = PersistenceManager.shared

    /// Last automatic backup completion time (runtime status)
    private(set) var lastBackupTime: Date?

    private init() {}

    // MARK: - Scheduled backup

    func startHourlyBackups() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: Constants.backupInterval,
            repeats: true
        ) { [weak self] _ in
            Task.detached(priority: .background) { [weak self] in
                await self?.createBackup()
            }
        }
        logger.debug("Hourly backups started (interval: \(Constants.backupInterval)s)")
    }

    func stopBackups() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Backup created

    func createBackup() async {
        let fm = FileManager.default
        let backupDir = pm.appDataURL.appendingPathComponent("backups")
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backupURL = backupDir.appendingPathComponent("open-maestri-\(timestamp).omaestribak")

            let data = try buildBackupData()
            let tmp = backupURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: backupURL.path) {
                _ = try fm.replaceItem(at: backupURL, withItemAt: tmp, backupItemName: nil, resultingItemURL: nil)
            } else {
                try fm.moveItem(at: tmp, to: backupURL)
            }
            lastBackupTime = Date()
            logger.info("Backup created: \(backupURL.lastPathComponent)")

            await pruneOldBackups(in: backupDir, keepCount: 24)
        } catch {
            logger.error("Backup failed: \(error)")
        }
    }

    // MARK: - Export full backup (manually triggered by user, save to specified path)

    /// Export all application data to a single backup file
    /// - Parameter destinationURL: The destination path selected by the user through NSSavePanel
    func exportBackup(to destinationURL: URL) throws {
        let data = try buildBackupData()
        try data.write(to: destinationURL, options: .atomic)
        logger.info("Backup exported to: \(destinationURL.path)")
    }

    /// Import recovery from external backup file (user selection via NSOpenPanel)
    /// - Parameter sourceURL: External .omaestribak file path
    /// - Returns: Number of files successfully recovered
    @discardableResult
    func importBackup(from sourceURL: URL) throws -> Int {
        return try restoreFromBackup(url: sourceURL)
    }

    // MARK: - Backup list

    func listBackups() -> [URL] {
        let backupDir = pm.appDataURL.appendingPathComponent("backups")
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
        .filter { $0.pathExtension == "omaestribak" }
        .sorted {
            let da = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }) ?? []
    }

    /// Get the time of the last backup (read from the file system, for display on first boot)
    func lastBackupDate() -> Date? {
        if let cached = lastBackupTime { return cached }
        guard let latest = listBackups().first else { return nil }
        return (try? latest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    // MARK: - Recovery

    /// Restore data from backup file (copy the backup file contents back to the original path)
    /// - Parameter backupURL: .omaestribak file URL
    /// - Returns: Number of files successfully recovered
    @discardableResult
    func restoreFromBackup(url backupURL: URL) throws -> Int {
        let fm = FileManager.default
        let data = try Data(contentsOf: backupURL)

        // New format: {"files": {"path": "base64content", ...}}
        // Old format (path list): ["path1", "path2", ...]
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = dict["files"] as? [String: String] {
            // New format recovery
            var restoredCount = 0
            for (path, base64) in files {
                guard let fileData = Data(base64Encoded: base64) else { continue }
                let url = URL(fileURLWithPath: path)
                do {
                    try fm.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fileData.write(to: url, options: .atomic)
                    restoredCount += 1
                } catch {
                    logger.error("Restore failed for \(path): \(error)")
                }
            }
            logger.info("Restored \(restoredCount)/\(files.count) files from \(backupURL.lastPathComponent)")
            NotificationCenter.default.post(name: .backupRestored, object: nil)
            return restoredCount
        } else {
            // Old format: path list only, no real recovery
            let filePaths = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            let available = filePaths.filter { fm.fileExists(atPath: $0) }.count
            logger.warning("Backup \(backupURL.lastPathComponent) uses old format (path-only), cannot restore content")
            return available
        }
    }

    // MARK: - Storage usage calculation

    /// Calculate the total size of the entire application data directory
    func totalStorageSize() -> Int64 {
        return directorySize(at: pm.appDataURL)
    }

    /// Calculate the storage size of each workspace
    /// - Returns: [(workspaceName, workspaceId, sizeInBytes)]
    func workspaceStorageSizes() -> [(name: String, id: UUID, size: Int64)] {
        let fm = FileManager.default
        let wsDir = pm.appDataURL.appendingPathComponent("workspaces")
        guard let entries = try? fm.contentsOfDirectory(atPath: wsDir.path) else { return [] }

        var results: [(name: String, id: UUID, size: Int64)] = []
        for entry in entries {
            guard let uuid = UUID(uuidString: entry) else { continue }
            let wsPath = wsDir.appendingPathComponent(entry)
            let size = directorySize(at: wsPath)
            // Attempt to read workspace name
            let wsJsonPath = wsPath.appendingPathComponent("workspace.json")
            var name = entry
            if let data = try? Data(contentsOf: wsJsonPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let payload = json["payload"] as? [String: Any],
               let wsName = payload["name"] as? String {
                name = wsName
            }
            results.append((name: name, id: uuid, size: size))
        }
        return results.sorted { $0.size > $1.size }
    }

    /// Recursively calculate directory size
    private func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory == false,
                  let size = values.fileSize else { continue }
            totalSize += Int64(size)
        }
        return totalSize
    }

    // MARK: - Reset all data

    /// Delete all application data (dangerous operation, need to confirm before calling)
    func deleteAllData() throws {
        let fm = FileManager.default
        let appDataPath = pm.appDataURL.path
        guard fm.fileExists(atPath: appDataPath) else { return }

        // Delete subdirectories and files one by one instead of recursively deleting the root directory
        let contents = try fm.contentsOfDirectory(atPath: appDataPath)
        for item in contents {
            let itemPath = pm.appDataURL.appendingPathComponent(item).path
            try fm.removeItem(atPath: itemPath)
        }
        // Recreate the base directory structure
        try pm.ensureDirectoriesExist()
        logger.warning("All application data has been deleted and directories recreated")
    }

    // MARK: - Private Auxiliary

    /// Build backup data (collect all files and package as JSON)
    private func buildBackupData() throws -> Data {
        let fm = FileManager.default
        var filesToBackup: [URL] = []
        for candidate in [pm.manifestURL, pm.appStateURL, pm.preferencesURL, pm.routinesURL, pm.sidebarLayoutURL] {
            if fm.fileExists(atPath: candidate.path) {
                filesToBackup.append(candidate)
            }
        }
        let wsDir = pm.appDataURL.appendingPathComponent("workspaces")
        if let workspaceIds = try? fm.contentsOfDirectory(atPath: wsDir.path) {
            for wsId in workspaceIds {
                let wsFile = wsDir.appendingPathComponent("\(wsId)/workspace.json")
                if fm.fileExists(atPath: wsFile.path) {
                    filesToBackup.append(wsFile)
                }
                // Backup notes
                let notesDir = wsDir.appendingPathComponent("\(wsId)/notes")
                if let notes = try? fm.contentsOfDirectory(atPath: notesDir.path) {
                    for note in notes where note.hasSuffix(".md") {
                        filesToBackup.append(notesDir.appendingPathComponent(note))
                    }
                }
            }
        }
        // Backup roles
        let rolesDir = pm.appDataURL.appendingPathComponent("roles")
        if let roleIds = try? fm.contentsOfDirectory(atPath: rolesDir.path) {
            for roleId in roleIds {
                let roleDir = rolesDir.appendingPathComponent(roleId)
                if let roleFiles = try? fm.contentsOfDirectory(atPath: roleDir.path) {
                    for file in roleFiles {
                        filesToBackup.append(roleDir.appendingPathComponent(file))
                    }
                }
            }
        }

        // Storage file path + base64 encoded content
        var fileContents: [String: String] = [:]
        for fileURL in filesToBackup {
            if let fileData = try? Data(contentsOf: fileURL) {
                // Use relative path storage (relative to appDataURL) to facilitate restoring to a different location
                fileContents[fileURL.path] = fileData.base64EncodedString()
            }
        }
        let payload: [String: Any] = [
            "files": fileContents,
            "version": 2,
            "app": "open-maestri",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "fileCount": filesToBackup.count
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Clean old backups

    private func pruneOldBackups(in dir: URL, keepCount: Int) async {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "omaestribak" })
            .sorted(by: { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return da > db
            }) else { return }

        for file in files.dropFirst(keepCount) {
            try? fm.removeItem(at: file)
        }
    }
}

extension Notification.Name {
    static let backupRestored = Notification.Name("OpenMaestri.backupRestored")
}
