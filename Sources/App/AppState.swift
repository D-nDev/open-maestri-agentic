import OSLog
import Foundation

/// Global application state, using @Observable (macOS 14+)
@Observable
final class AppState {
    var activeWorkspaceId: UUID?
    var workspaces: [WorkspaceManager] = []
    var preferences: Preferences = Preferences()
    var hasCompletedOnboarding: Bool = false
    var needsRecovery: Bool = false
    var loadErrors: [String] = []
    var manifest: WorkspaceManifest = WorkspaceManifest()
    /// Recently visited workspace ID (up to 5, used for ⌘⌘numeric jump)
    var recentWorkspaceIds: [UUID] = []
    /// Last autosave time (runtime state, not persisted)
    var lastAutosaveTime: Date?

    private let logger = Logger.make(category: "AppState")
    private let pm = PersistenceManager.shared
    private var idleObserver: NSObjectProtocol?

    init() {
        idleObserver = NotificationCenter.default.addObserver(
            forName: .terminalBecameIdle,
            object: nil,
            queue: nil  // Receive in the post thread and then jump back to MainActor through Task
        ) { [weak self] notif in
            guard let terminalId = notif.userInfo?["terminalId"] as? UUID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wsId = TerminalManager.shared.terminalWorkspaceMap[terminalId]
                guard let wsId,
                      let ws = self.workspaces.first(where: { $0.id == wsId }) else { return }
                if wsId != self.activeWorkspaceId {
                    ws.unreadActivityCount += 1
                }
            }
        }
    }

    deinit {
        if let obs = idleObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Called when switching to a certain workspace, clearing the unread count of the workspace
    func clearUnread(workspaceId: UUID) {
        workspaces.first(where: { $0.id == workspaceId })?.unreadActivityCount = 0
    }

    /// Activate specified workspace: update activeWorkspaceId, clear unread count
    /// Unix socket is a global fixed path and will not be rebuilt with workspace switching.
    func selectWorkspace(id: UUID?) {
        activeWorkspaceId = id
        if let id {
            clearUnread(workspaceId: id)
        }
    }

    // MARK: - Bootloading (NFR1: Cold start < 1.5s)

    /// Loads all persisted state on cold launch.
    /// - The three root JSON files are read concurrently via `async let`.
    /// - Workspace documents are still loaded sequentially to surface per-workspace errors clearly.
    func loadOnLaunch() async {
        do {
            try pm.ensureDirectoriesExist()

            // Parallel read of the three independent root files
            async let stateTask = Task.detached(priority: .userInitiated) { try self.pm.loadAppState() }.value
            async let prefsTask = Task.detached(priority: .userInitiated) { try self.pm.loadPreferences() }.value
            async let manTask   = Task.detached(priority: .userInitiated) { try self.pm.loadManifest() }.value

            let (stateData, prefs, man) = try await (stateTask, prefsTask, manTask)

            await MainActor.run {
                activeWorkspaceId = stateData.activeWorkspaceId
                hasCompletedOnboarding = stateData.hasCompletedOnboarding
                needsRecovery = !stateData.cleanShutdown
                recentWorkspaceIds = stateData.recentWorkspaceIds
                preferences = prefs
                manifest = man
            }

            // Load all workspaces (serial to facilitate catching errors one by one)
            let loadFailedFormat = await MainActor.run { "workspace.load_failed".localized }
            var loadedWorkspaces: [WorkspaceManager] = []
            var errors: [String] = []
            for entry in man.workspaces {
                let ws = WorkspaceManager(entry: entry)
                do {
                    try ws.load()
                } catch {
                    errors.append(String(format: loadFailedFormat, entry.name, error.localizedDescription))
                    logger.error("Workspace \(entry.id) load error: \(error)")
                }
                loadedWorkspaces.append(ws)
            }
            await MainActor.run {
                workspaces = loadedWorkspaces
                loadErrors = errors
                // Start global Unix socket (created only once during application life cycle)
                InterAgentServer.shared.startUnixSocketIfNeeded()
            }

            // Mark this time as incomplete closing
            var dirty = stateData
            dirty.cleanShutdown = false
            try pm.saveAppState(dirty)
            logger.debug("App state loaded — workspaces: \(man.workspaces.count)")
        } catch {
            logger.error("Failed to load app state: \(error)")
        }
    }

    // MARK: - Autosave (NFR5: non-blocking UI, Story 1.5)

    private var autosaveTimer: Timer?

    func startAutosave() {
        autosaveTimer?.invalidate()
        let interval = TimeInterval(preferences.autosaveIntervalSeconds)
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task.detached(priority: .background) { [weak self] in
                await self?.autosave()
            }
        }
    }

    /// Called when the user modifies the auto-save interval in the settings, restart the timer
    func restartAutosave() {
        startAutosave()
    }

    func stopAutosave() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }

    private func autosave() async {
        do {
            // Snapshot all main thread variable data at once on the MainActor to eliminate race conditions with background threads.
            // Copy the manifest, preferences, and payload of each dirty workspace into value type snapshots.
            // All subsequent I/O operations are snapshot copies and no longer touch any @Observable properties.
            let (manifestSnapshot, prefsSnapshot, dirtySnapshots):
                (WorkspaceManifest, Preferences, [(WorkspaceManager, WorkspacePayload)]) =
                    await MainActor.run {
                        let dirty = workspaces.filter { $0.isDirty }
                        return (manifest, preferences, dirty.map { ($0, $0.snapshotPayload()) })
                    }

            // The following is pure serialized I/O, no main thread variable state is read anymore
            try pm.saveManifest(manifestSnapshot)
            try pm.savePreferences(prefsSnapshot)
            for (ws, payload) in dirtySnapshots {
                let doc = WorkspaceDocument(payload: payload)
                try await pm.saveWorkspace(doc)
                // isDirty writeback must be performed on MainActor
                await MainActor.run { ws.isDirty = false }
            }
            await MainActor.run { lastAutosaveTime = Date() }
            if !dirtySnapshots.isEmpty {
                logger.debug("Autosave completed (\(dirtySnapshots.count) dirty workspaces saved)")
            }
        } catch {
            logger.error("Autosave failed: \(error)")
        }
    }

    /// Forced synchronous save (called when the application exits)
    func forceSave(cleanShutdown: Bool) {
        do {
            try pm.saveManifest(manifest)
            try pm.savePreferences(preferences)
            var state = AppStateData()
            state.activeWorkspaceId = activeWorkspaceId
            state.hasCompletedOnboarding = hasCompletedOnboarding
            state.cleanShutdown = cleanShutdown
            try pm.saveAppState(state)
        } catch {
            logger.error("Force save failed: \(error)")
        }
    }
}
