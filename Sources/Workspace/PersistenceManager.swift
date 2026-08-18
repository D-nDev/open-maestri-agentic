import Foundation
import OSLog

/// Data persistence manager
/// All file I/O must go through this class (except ScrollbackStore, for performance reasons)
final class PersistenceManager {
    static let shared = PersistenceManager()

    private let logger = Logger.make(category: "PersistenceManager")

    /// Application data root directory ~/.open-maestri/
    var appDataURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Constants.appDataDirectoryName)
    }

    var appStateURL: URL { appDataURL.appendingPathComponent("app-state.json") }
    var preferencesURL: URL { appDataURL.appendingPathComponent("preferences.json") }
    var manifestURL: URL { appDataURL.appendingPathComponent("manifest.json") }
    var routinesURL: URL { appDataURL.appendingPathComponent("routines.json") }
    var sidebarLayoutURL: URL { appDataURL.appendingPathComponent("sidebar-layout.json") }

    func workspaceURL(id: UUID) -> URL {
        appDataURL.appendingPathComponent("workspaces/\(id.uuidString)/workspace.json")
    }

    func workspaceDirURL(id: UUID) -> URL {
        appDataURL.appendingPathComponent("workspaces/\(id.uuidString)")
    }

    func notesDirURL(workspaceId: UUID) -> URL {
        workspaceDirURL(id: workspaceId).appendingPathComponent("notes")
    }

    func orcaBindingsURL(workspaceId: UUID) -> URL {
        workspaceDirURL(id: workspaceId).appendingPathComponent("orca-bindings.json")
    }

    func scrollbackURL(terminalId: UUID, workspaceId: UUID) -> URL {
        workspaceDirURL(id: workspaceId).appendingPathComponent("terminals/\(terminalId.uuidString).scrollback")
    }

    let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        #if DEBUG
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        #endif
        return enc
    }()

    let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    private init() {}

    // MARK: - Directory initialization

    func ensureDirectoriesExist() throws {
        let dirs: [URL] = [
            appDataURL,
            appDataURL.appendingPathComponent("workspaces"),
            appDataURL.appendingPathComponent("roles"),
        ]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func ensureWorkspaceDirectoryExists(id: UUID) throws {
        let dirs: [URL] = [
            workspaceDirURL(id: id),
            notesDirURL(workspaceId: id),
            workspaceDirURL(id: id).appendingPathComponent("terminals"),
            workspaceDirURL(id: id).appendingPathComponent("snapshots"),
        ]
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Universal Atomic Codable I/O

    /// Encodes `value` to JSON and writes it atomically to `url` on a background task.
    func save<T: Encodable>(_ value: T, to url: URL) async throws {
        let data = try encoder.encode(value)
        try await Task.detached(priority: .background) {
            try self.atomicWrite(data, to: url)
        }.value
    }

    func saveSync<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try atomicWrite(data, to: url)
    }

    /// Decodes and returns a value of `type` from the JSON file at `url`, applying schema migrations.
    func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try migrating(data: data, type: type)
    }

    func loadIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try load(type, from: url)
    }

    // MARK: - Version migration hook

    private func migrating<T: Decodable>(data: Data, type: T.Type) throws -> T {
        // In case of WorkspaceDocument, check schemaVersion
        if type == WorkspaceDocument.self {
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = raw["schemaVersion"] as? Int,
               version < Constants.schemaVersion {
                let migrated = try Migration_v1_to_v2.migrate(data: data)
                return try decoder.decode(type, from: migrated)
            }
        }
        return try decoder.decode(type, from: data)
    }

    // MARK: - Atomic write

    private func atomicWrite(_ data: Data, to url: URL) throws {
        // Make sure the parent directory exists
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)

        if FileManager.default.fileExists(atPath: url.path) {
            // Target file already exists: use replaceItem to ensure atomicity (including crash recovery semantics)
            _ = try FileManager.default.replaceItem(
                at: url,
                withItemAt: tmp,
                backupItemName: nil,
                resultingItemURL: nil
            )
        } else {
            // The target file does not exist (created for the first time): directly move tmp to the target path
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    // MARK: - High-level workspace API (used by Story 1.3/1.5)

    func loadWorkspace(id: UUID) throws -> WorkspaceDocument {
        let url = workspaceURL(id: id)
        return try load(WorkspaceDocument.self, from: url)
    }

    func saveWorkspace(_ doc: WorkspaceDocument) async throws {
        let url = workspaceURL(id: doc.payload.id)
        try await save(doc, to: url)
    }

    func loadOrcaBindings(workspaceId: UUID) throws -> OrcaTerminalBindingDocument {
        (try loadIfExists(
            OrcaTerminalBindingDocument.self,
            from: orcaBindingsURL(workspaceId: workspaceId)
        )) ?? OrcaTerminalBindingDocument(workspaceId: workspaceId)
    }

    func saveOrcaBindings(_ document: OrcaTerminalBindingDocument) async throws {
        try await save(document, to: orcaBindingsURL(workspaceId: document.workspaceId))
    }

    func loadAppState() throws -> AppStateData {
        (try loadIfExists(AppStateData.self, from: appStateURL)) ?? AppStateData()
    }

    func saveAppState(_ state: AppStateData) throws {
        try saveSync(state, to: appStateURL)
    }

    // MARK: - Prefer memory cache (avoid duplicate disk I/O)

    /// Memory cache: retained after first read to avoid triggering synchronous disk read every time a terminal is created
    private var _cachedPreferences: Preferences?
    private let _prefLock = NSLock()

    func loadPreferences() throws -> Preferences {
        _prefLock.lock()
        if let cached = _cachedPreferences {
            _prefLock.unlock()
            return cached
        }
        _prefLock.unlock()
        let prefs = (try loadIfExists(Preferences.self, from: preferencesURL)) ?? Preferences()
        _prefLock.lock()
        _cachedPreferences = prefs
        _prefLock.unlock()
        return prefs
    }

    /// Synchronous no-throw version for calls from HTTP threads (returns default instead of crashing)
    func loadPreferencesSync() -> Preferences {
        (try? loadPreferences()) ?? Preferences()
    }

    func savePreferences(_ prefs: Preferences) throws {
        try saveSync(prefs, to: preferencesURL)
        // Synchronously update the memory cache after writing to ensure that subsequent reads get the latest value
        _prefLock.lock()
        _cachedPreferences = prefs
        _prefLock.unlock()
    }

    func loadManifest() throws -> WorkspaceManifest {
        (try loadIfExists(WorkspaceManifest.self, from: manifestURL)) ?? WorkspaceManifest()
    }

    func saveManifest(_ manifest: WorkspaceManifest) throws {
        try saveSync(manifest, to: manifestURL)
    }

    func loadSidebarLayout() throws -> SidebarLayout {
        (try loadIfExists(SidebarLayout.self, from: sidebarLayoutURL)) ?? SidebarLayout()
    }

    func saveSidebarLayout(_ layout: SidebarLayout) throws {
        try saveSync(layout, to: sidebarLayoutURL)
    }
}
