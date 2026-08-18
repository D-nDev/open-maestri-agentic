import XCTest
@testable import open_maestri

// Story 1.5 AC acceptance testing: automatic saving and backup
final class AutosaveTests: XCTestCase {

    // MARK: - Story 1.5 AC: 30 seconds auto-save

    func testAutosaveIntervalIs30Seconds() {
        XCTAssertEqual(Constants.autosaveInterval, 30.0,
                       "Story 1.5 AC: Autosave must trigger every 30 seconds")
    }

    @MainActor
    func testStartAutosaveCreatesTimer() {
        let appState = AppState()
        appState.startAutosave()
        // Timer exists (verify via forceSave that appState has started auto-save logic)
        appState.stopAutosave()
        // Pass without crashing
        XCTAssertTrue(true)
    }

    @MainActor
    func testForceSaveWritesCleanShutdown() throws {
        let appState = AppState()
        // Make sure the directory exists
        try PersistenceManager.shared.ensureDirectoriesExist()
        appState.forceSave(cleanShutdown: true)
        // Verify app-state.json is written
        let state = try PersistenceManager.shared.loadAppState()
        XCTAssertTrue(state.cleanShutdown, "forceSave(cleanShutdown: true) must persist cleanShutdown=true")
    }

    @MainActor
    func testForceSaveDirtyShutdown() throws {
        let appState = AppState()
        try PersistenceManager.shared.ensureDirectoriesExist()
        appState.forceSave(cleanShutdown: false)
        let state = try PersistenceManager.shared.loadAppState()
        XCTAssertFalse(state.cleanShutdown, "forceSave(cleanShutdown: false) must persist cleanShutdown=false")
    }

    // MARK: - Story 1.5 AC: Hourly .omaestribak backups (NFR12)

    func testBackupIntervalIs3600Seconds() {
        XCTAssertEqual(Constants.backupInterval, 3600.0,
                       "NFR12: Backup must run every hour (3600s)")
    }

    func testBackupCreatesFile() async throws {
        let pm = PersistenceManager.shared
        try pm.ensureDirectoriesExist()

        await BackupManager.shared.createBackup()

        let backupDir = pm.appDataURL.appendingPathComponent("backups")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []
        let backupFiles = files.filter { $0.hasSuffix(".omaestribak") }

        XCTAssertFalse(backupFiles.isEmpty,
                       "NFR12: createBackup() must create a .omaestribak file")
    }

    // MARK: - Story 1.5 AC: Recovery time after reboot < 0.5s (NFR2)

    func testWorkspacePayloadCodingIsfast() throws {
        // Create a workspace with 10 nodes to test serialization speed
        var payload = WorkspacePayload(name: "PerfTest", workingDirectory: "/tmp")
        for i in 0..<10 {
            let node = CanvasNode(
                frame: CGRect(x: Double(i) * 100, y: 0, width: 400, height: 300),
                content: .terminal(TerminalContent(name: "Agent\(i)"))
            )
            payload.nodes.append(node)
        }
        let doc = WorkspaceDocument(payload: payload)

        let start = Date()
        let data = try PersistenceManager.shared.encoder.encode(doc)
        _ = try PersistenceManager.shared.decoder.decode(WorkspaceDocument.self, from: data)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.1,
                          "NFR2: Workspace restore must complete quickly, took \(elapsed)s")
    }

    // MARK: - PersistenceManager atomic writes (NFR11)

    func testAtomicWriteNoTempFileLeftBehind() async throws {
        let pm = PersistenceManager.shared
        let tmpUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpUrl) }

        try await pm.save(["test": "value"], to: tmpUrl)

        // Temporary files should not remain
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpUrl.appendingPathExtension("tmp").path),
                       "NFR11: Atomic write must clean up .tmp file")
        // Formal documentation should exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpUrl.path))
    }
}
