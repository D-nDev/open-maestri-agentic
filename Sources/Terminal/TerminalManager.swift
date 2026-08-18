import AppKit
import Foundation
import OSLog

/// Terminal Lifecycle Manager
/// - Create/destroy PTY sessions for each Terminal node
/// - **Parallel startup**: All terminal PTY forks at the same time, benchmarking Maestri for fast and smooth startup
/// - All PTY write operations must go through this class (architectural constraint)
@MainActor
final class TerminalManager {
    static let shared = TerminalManager()
    private let logger = Logger.make(category: "TerminalManager")

    /// Active terminal UUID → terminal status (coexistence across workspaces, consistent with Maestri multi-workspace background running design)
    private(set) var terminals: [UUID: TerminalSession] = [:]
    /// Terminal UUID → Workspace ID to which it belongs (used for query by workspace)
    private(set) var terminalWorkspaceMap: [UUID: UUID] = [:]
    /// Terminal UUID → SwiftTermProvider (replaces the old TerminalProviderRegistry)
    private(set) var providers: [UUID: SwiftTermProvider] = [:]
    /// Collection of terminal IDs for which shell initialization has been completed
    private(set) var completedProviders: Set<UUID> = []

    private(set) var isShuttingDown = false

    private init() {}

    // MARK: - Terminal Creation

    func createTerminal(
        id: UUID,
        command: String,
        workingDirectory: String,
        workspaceId: UUID? = nil,
        roleName: String? = nil,
        displayName: String? = nil,
        agentType: String = "generic_shell"
    ) -> TerminalSession {
        let session = TerminalSession(
            id: id,
            command: command,
            workingDirectory: workingDirectory,
            roleName: roleName
        )
        session.agentType = agentType
        session.displayName = displayName
        terminals[id] = session
        if let wsId = workspaceId {
            terminalWorkspaceMap[id] = wsId
            Task.detached(priority: .background) {
                let store = ScrollbackStore()
                let entries = (try? store.load(terminalId: id, workspaceId: wsId)) ?? []
                if !entries.isEmpty {
                    Task { @MainActor in
                        session.bulkLoadHistory(entries.map { $0.text })
                    }
                }
            }
        }

        // Parallel startup: Create provider directly and start PTY without queuing
        startProvider(
            id: id,
            command: command,
            workingDirectory: workingDirectory,
            workspaceId: workspaceId,
            roleName: roleName
        )

        logger.debug("Terminal \(id) created and starting, command: \(command)")
        return session
    }

    /// Convenience method: Create terminal via AgentPreset (for testing and toolbars)
    @discardableResult
    func createTerminal(
        id: UUID,
        workingDirectory: String,
        preset: AgentPreset,
        workspaceId: UUID? = nil,
        roleName: String? = nil
    ) -> TerminalSession {
        createTerminal(
            id: id,
            command: preset.command,
            workingDirectory: workingDirectory,
            workspaceId: workspaceId,
            roleName: roleName,
            agentType: preset.agentType
        )
    }

    /// Fill in the workspace mapping to which the terminal belongs (used when the workspaceId is not passed in with the session when reusing the provider)
    func registerWorkspace(terminalId: UUID, workspaceId: UUID) {
        terminalWorkspaceMap[terminalId] = workspaceId
    }

    func removeTerminal(id: UUID) {
        providers[id]?.stop()
        providers.removeValue(forKey: id)
        completedProviders.remove(id)
        terminals[id]?.terminate()
        terminals.removeValue(forKey: id)
        terminalWorkspaceMap.removeValue(forKey: id)
        logger.debug("Terminal \(id) removed")
    }

    func shutdown() {
        isShuttingDown = true
        providers.values.forEach { $0.stop() }
        providers.removeAll()
        completedProviders.removeAll()
        terminals.removeAll()
    }

    // MARK: - PTY write (sole entry for all writes)

    func write(to terminalId: UUID, text: String) {
        guard let session = terminals[terminalId] else {
            logger.warning("Write to unknown terminal \(terminalId)")
            return
        }
        session.write(text)
    }

    func writeLine(to terminalId: UUID, text: String) {
        write(to: terminalId, text: text + "\n")
    }

    // MARK: - Parallel startup (each terminal starts PTY independently, without waiting for each other)

    private func startProvider(
        id: UUID,
        command: String,
        workingDirectory: String,
        workspaceId: UUID?,
        roleName: String?
    ) {
        let provider = SwiftTermProvider(
            terminalId: id,
            command: command,
            workingDirectory: workingDirectory
        )
        provider.serverPort = InterAgentServer.shared.port
        provider.workspaceId = workspaceId
        if let prefs = try? PersistenceManager.shared.loadPreferences() {
            provider.preferredFont = NSFont(name: prefs.terminalFontFamily, size: prefs.terminalFontSize)
                ?? NSFont.monospacedSystemFont(ofSize: prefs.terminalFontSize, weight: .regular)
        }
        providers[id] = provider

        // shellReadyCallback: shell initialization completed → mark → send notification (no longer blocks other terminals)
        provider.shellReadyCallback = { [weak self] in
            guard let self else { return }
            self.completedProviders.insert(id)
            if let wsId = workspaceId {
                NotificationCenter.default.post(
                    name: .terminalShellReady,
                    object: nil,
                    userInfo: ["terminalId": id, "workspaceId": wsId]
                )
            }
        }

        // Bind PTY output → session.recordOutput and establish session write channel
        if let session = terminals[id] {
            provider.onDataReceived = { [weak session] text in
                Task { @MainActor in session?.recordOutput(text) }
            }
            // Establish session → provider write path (pendingWrites needs to be able to be sent after PTY is started)
            session.onOutput = { [weak provider] text in provider?.write(text) }
        }

        // Start PTY directly (not dependent on whether TerminalEmbeddedView is attached).
        // Benchmarking Maestri: Start PTY process immediately when terminal is created, no viewport culling delay.
        // TerminalEmbeddedView then takes the re-attach branch when attaching it (there is already a terminalView).
        provider.start(in: NSRect(x: 0, y: 0, width: 600, height: 400))

        // Notify TerminalEmbeddedView (if it already exists) that the provider's terminalView can be attached
        NotificationCenter.default.post(
            name: .terminalProviderReady,
            object: nil,
            userInfo: ["terminalId": id]
        )
    }
}

/// Single terminal session state
@MainActor
final class TerminalSession {
    let id: UUID
    let command: String
    let workingDirectory: String
    let roleName: String?
    /// The node's agent type (from TerminalContent.agentType) for AskHandler to select a waiting strategy
    var agentType: String = "generic_shell"
    /// The display name set by the user in the UI for this node (from TerminalContent.name)
    var displayName: String?
    /// Agent actual assigned name (from OMAESTRI_AGENT_NAME environment variable, injected by MaestroHandlers.recruit)
    var agentName: String?
    /// Current working directory of the terminal (updated in real time by PTY OSC 7 callback)
    private(set) var currentDirectory: String?
    private(set) var isRunning: Bool = false
    private(set) var isIdle: Bool = true
    /// Is there any task triggered by IPC (omaestri ask, etc.) being executed?
    /// Only when this flag is true, the red dot notification will be triggered after the task is completed
    private(set) var hasActiveTask: Bool = false

    /// PTY write callback (set after TerminalEmbeddedView.makeNSView)
    var onOutput: ((String) -> Void)? {
        didSet {
            // Once onOutput is set, immediately flush the queue to be written (solve timing race conditions)
            if onOutput != nil && !pendingWrites.isEmpty {
                let pending = pendingWrites
                pendingWrites.removeAll()
                pending.forEach { onOutput?($0) }
            }
        }
    }

    /// onOutput temporarily stores text to be written when it is not ready
    private var pendingWrites: [String] = []

    /// Recent output ring buffer (max 500 lines, for use by omaestri check)
    /// Use circular indexes to avoid the O(n) copy overhead of removeFirst
    private var outputRing: [String] = []
    private var outputRingStart: Int = 0  // Logical start position
    private var outputRingCount: Int = 0  // Current number of valid rows
    private let bufferMaxLines = 500

    private let activityMonitor = TerminalActivityMonitor()

    init(id: UUID, command: String, workingDirectory: String, roleName: String?) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.roleName = roleName

        activityMonitor.onStatusChanged = { [weak self] isActive in
            guard let self else { return }
            if !isActive {
                self.markIdle()
            }
        }
        activityMonitor.start()
    }

    func write(_ text: String) {
        if let cb = onOutput {
            cb(text)
        } else {
            // PTY has not been initialized and is temporarily stored in the queue (up to 100 items can be cached)
            if pendingWrites.count < 100 { pendingWrites.append(text) }
        }
    }

    /// Logging PTY output to cache (called by SwiftTermProvider when output is received)
    func recordOutput(_ text: String) {
        let newLines = text.components(separatedBy: "\n")
        appendToRing(newLines)
        isIdle = false
        activityMonitor.recordOutput()
    }

    /// Batch loading history (only writes to buffer, does not trigger activityMonitor or Notification)
    /// Use scrollback to restore the scene to avoid triggering a lot of side effects line by line
    func bulkLoadHistory(_ lines: [String]) {
        appendToRing(lines)
    }

    /// Get the last N lines of output
    func recentOutput(lines: Int = 20) -> String {
        let count = min(lines, outputRingCount)
        guard count > 0 else { return "" }
        var result: [String] = []
        result.reserveCapacity(count)
        // Take count lines from the end of the ring buffer
        let startIdx = (outputRingStart + outputRingCount - count) % outputRing.count
        for i in 0..<count {
            result.append(outputRing[(startIdx + i) % outputRing.count])
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Ring Buffer internal implementation

    /// Append new row to ring buffer (O(1) amortized, no array elements moved)
    private func appendToRing(_ newLines: [String]) {
        // Initializing ring buffer (fixed capacity allocated on first write)
        if outputRing.isEmpty {
            outputRing = Array(repeating: "", count: bufferMaxLines)
        }
        for line in newLines {
            let writeIdx = (outputRingStart + outputRingCount) % bufferMaxLines
            outputRing[writeIdx] = line
            if outputRingCount < bufferMaxLines {
                outputRingCount += 1
            } else {
                // Buffer full, overwriting oldest element, moving start pointer
                outputRingStart = (outputRingStart + 1) % bufferMaxLines
            }
        }
    }

    /// Mark the presence of an active task triggered via IPC (called by AskHandler before injecting prompt)
    func markActiveTask() {
        hasActiveTask = true
    }

    /// Mark idle (triggered by activityMonitor callback)
    /// Notify only when switching from non-idle to idle and there is an active IPC task (to avoid normal shell output accidentally triggering red dots)
    func markIdle() {
        guard !isIdle else { return }
        isIdle = true
        guard hasActiveTask else { return }
        hasActiveTask = false
        NotificationCenter.default.post(
            name: .terminalBecameIdle,
            object: nil,
            userInfo: ["terminalId": id]
        )
    }

    /// Update current working directory (called by SwiftTermProvider.hostCurrentDirectoryUpdate)
    func updateCurrentDirectory(_ directory: String?) {
        guard let dir = directory, !dir.isEmpty, dir != currentDirectory else { return }
        currentDirectory = dir
        NotificationCenter.default.post(
            name: .terminalDirectoryChanged,
            object: nil,
            userInfo: ["terminalId": id, "directory": dir]
        )
    }

    func terminate() {
        isRunning = false
        activityMonitor.stop()
    }
}
