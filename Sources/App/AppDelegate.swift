import OSLog
import AppKit
import Foundation
import Sparkle

/// AppDelegate handles application life cycle events
class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger.make(category: "AppDelegate")
    weak var appState: AppState?

    // MARK: - Sparkle automatic update
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. InterAgentServer must be started before any terminal is created (eliminates port=0 race condition)
        do {
            try InterAgentServer.shared.start()
            logger.info("InterAgentServer started on port \(InterAgentServer.shared.port)")
        } catch {
            logger.error("InterAgentServer failed to start: \(error)")
        }

        // 2. Write omaestri skill to the user global ~/.claude/skills/ (idempotent, background execution to avoid blocking the main thread)
        DispatchQueue.global(qos: .userInitiated).async {
            SkillInjector.shared.installSkillsIfNeeded()
        }

        // 3. Configure the main window style (transparent title bar, let the canvas fill the window)
        DispatchQueue.main.async {
            WindowStateObserver.shared.configureMainWindow()
        }

        // 4. Sparkle automatic update
        // startingUpdater: false — Disable automatic checking at startup to avoid error pop-ups when appcast/signature is not ready.
        // Users can manually trigger checkForUpdates() in Settings → General.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        logger.debug("Application did finish launching")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        logger.debug("Application should terminate — starting graceful shutdown")
        guard let appState else { return .terminateNow }

        // 1. Immediately stop all subsystems that may block the main thread
        appState.stopAutosave()
        InterAgentServer.shared.stop()
        RoutineScheduler.shared.stopAllTimers()

        // 2. Snapshot all @Observable states in the main thread as pure value types (O(n) copy, no I/O)
        let payloads: [(id: UUID, doc: WorkspaceDocument)] = appState.workspaces.map { ws in
            (ws.id, WorkspaceDocument(payload: ws.snapshotPayload()))
        }
        let stateData: AppStateData = {
            var s = AppStateData()
            s.activeWorkspaceId = appState.activeWorkspaceId
            s.hasCompletedOnboarding = appState.hasCompletedOnboarding
            s.cleanShutdown = true
            s.recentWorkspaceIds = appState.recentWorkspaceIds
            return s
        }()
        let manifest = appState.manifest

        // 3. The background thread does I/O and calls back reply after completion.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pm = PersistenceManager.shared
            for item in payloads {
                do { try pm.saveSync(item.doc, to: pm.workspaceURL(id: item.id)) }
                catch { self?.logger.error("Failed to save workspace \(item.id) on terminate: \(error)") }
            }
            do { try pm.saveManifest(manifest) }
            catch { self?.logger.error("Failed to save manifest on terminate: \(error)") }
            do { try pm.saveAppState(stateData) }
            catch { self?.logger.error("Failed to save app state on terminate: \(error)") }
            self?.logger.debug("Graceful shutdown save completed")
            // Notify AppKit that it is safe to exit
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }

        // Tell AppKit to "reply later" without blocking the main thread
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // All cleanup completed in applicationShouldTerminate
        // Only final resource release is done here (PTY process, etc.)
        logger.debug("Application will terminate — final cleanup")
        TerminalManager.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Check for updates (called by Settings)
    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
