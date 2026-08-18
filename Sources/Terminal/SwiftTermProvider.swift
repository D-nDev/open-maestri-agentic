import Foundation
import OSLog
import SwiftTerm
import AppKit

/// Parsing terminal fonts. The "system" identifier (against the Maestri default) maps to monospacedSystemFont,
/// Other values are searched by PostScript font name and fallback to monospacedSystemFont when not found.
func resolveTerminalFont(family: String, size: CGFloat) -> NSFont {
    if family == "system" || family.isEmpty {
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    return NSFont(name: family, size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

/// SwiftTerm PTY adaptation layer - only responsible for PTY process management
/// - Detect output by subclassing dataReceived of LocalProcessTerminalView (OmLocalProcessTerminalView)
/// - shellReadyCallback: triggered once after shell is ready (100ms silent)
@MainActor
final class SwiftTermProvider: NSObject {
    private let logger = Logger.make(category: "SwiftTermProvider")

    // MARK: - Basic attributes

    let terminalId: UUID
    let command: String
    let workingDirectory: String

    private(set) var terminalView: LocalProcessTerminalView?
    private(set) var isRunning: Bool = false

    // MARK: - callback (external setting, not automatically triggered by SwiftTerm)

    var onDataReceived: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onProcessExit: ((Int32?) -> Void)?

    /// Trigger once when shell is ready (300ms silent detection)
    var shellReadyCallback: (() -> Void)?

    // MARK: - Configuration

    var serverPort: UInt16 {
        get { _serverPort > 0 ? _serverPort : InterAgentServer.shared.port }
        set { _serverPort = newValue }
    }
    private var _serverPort: UInt16 = 0

    var workspaceId: UUID?
    var preferredFont: NSFont?
    var metalRendererEnabled: Bool = false

    /// cd + custom command, injected by start(), sent uniformly after the shell is ready
    var pendingStartupCommands: [String] = []

    // startProcess parameter temporary storage: start() does not start the process immediately after creating the view.
    // Wait until MaestroTerminalView.layout() determines the correct bounds for the first time before triggering firePendingStart().
    private struct PendingStart {
        let executable: String
        let args: [String]
        let environment: [String]
        let execName: String
        let currentDirectory: String?
    }
    private var pendingStart: PendingStart?

    // MARK: - Shell Readiness Detection (Internal)

    private var lastOutputTime: ContinuousClock.Instant = .now
    private var shellReadyScheduled = false
    private(set) var shellReadyCalled = false

    // MARK: - Scrollback

    private let scrollbackStore = ScrollbackStore()
    private var scrollbackDebounceTask: Task<Void, Never>?

    // MARK: - Init

    init(terminalId: UUID, command: String, workingDirectory: String) {
        self.terminalId = terminalId
        self.command = command
        self.workingDirectory = workingDirectory
    }

    // MARK: - Start

    @discardableResult
    func start(in frame: NSRect) -> LocalProcessTerminalView {
        // Reset the shell readiness state to ensure that each start() can correctly trigger the readiness detection process.
        shellReadyCalled = false
        shellReadyScheduled = false

        let effectiveFrame = frame == .zero
            ? NSRect(x: 0, y: 0, width: 600, height: 400)
            : frame
        let view = OmLocalProcessTerminalView(frame: effectiveFrame)
        view.processDelegate = self

        // Get PTY output through subclass callback (do not override terminalDelegate, keep send link intact)
        view.onDataReceived = { [weak self] text in
            Task { @MainActor in self?.handleDataReceived(text) }
        }

        let prefs = (try? PersistenceManager.shared.loadPreferences()) ?? Preferences()
        applyThemeWithPrefs(to: view, prefs: prefs)
        applyFontWithPrefs(to: view, prefs: prefs)

        terminalView = view
        // isRunning is delayed until firePendingStart() actually starts the process before setting it

        enableMetalIfNeeded(view: view, metalEnabled: prefs.metalRendererEnabled)

        // Build environment variables
        var env = ProcessInfo.processInfo.environment
        env["MAESTRI_TERMINAL_ID"] = terminalId.uuidString
        env["OMAESTRI_TERMINAL_ID"] = terminalId.uuidString
        if let socketPath = InterAgentServer.shared.currentSocketPath {
            env["MAESTRI_SOCKET"] = socketPath
        }
        env["TERM"] = "xterm-256color"
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extraPaths = [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/current/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ].filter { FileManager.default.fileExists(atPath: $0) }
        if let resourcePath = Bundle.main.resourcePath {
            env["MAESTRI_CLI"] = "\(resourcePath)/omaestri"
            env["PATH"] = ([resourcePath] + extraPaths + [existingPath]).joined(separator: ":")
        } else {
            env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        }

        let args: [String]
        let execName: String
        if command.isEmpty || command == "zsh" || command.hasSuffix("/zsh") {
            args = ["/bin/zsh", "--login"]
            execName = "zsh"
        } else if command == "bash" || command.hasSuffix("/bash") {
            args = ["/bin/bash", "--login"]
            execName = "bash"
        } else {
            // Non-shell commands (such as claude, codex, etc.): always run in the login shell.
            // In this way, the shell still survives after the command exits, and the user can continue to interact when returning to the prompt.
            // Benchmarking Maestri behavior: Endpoints are persistent shell sessions in which agent commands run.
            args = ["/bin/zsh", "--login"]
            execName = "zsh"
            pendingStartupCommands.append(command)
        }

        // Set the working directory natively through startProcess(currentDirectory:),
        // Avoid visible cd command in shell (PTY child process starts directly in target directory)
        let startDir: String? = (!workingDirectory.isEmpty && FileManager.default.fileExists(atPath: workingDirectory))
            ? workingDirectory : nil

        // Increase scrollback buffer (default 500 lines is too small, long session resize will truncate history)
        view.getTerminal().changeScrollback(10000)

        // Temporarily store startup parameters until MaestroTerminalView.layout() completes for the first time before calling startProcess.
        // In this way, when zsh starts, it gets the correct content area size (not fallback’s 600x400).
        // terminal.cols is calculated based on the real frame from the beginning to avoid horizontal cursor offset.
        pendingStart = PendingStart(
            executable: args[0],
            args: Array(args.dropFirst()),
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: execName,
            currentDirectory: startDir
        )
        logger.debug("PTY view ready (pending layout): \(self.command) in \(self.workingDirectory), terminalId=\(self.terminalId.uuidString.prefix(8))")

        return view
    }

    /// Called by MaestroTerminalView.layout() after correct bounds are first determined, triggering real PTY startup.
    func firePendingStart() {
        guard let ps = pendingStart else { return }
        pendingStart = nil
        guard let view = terminalView else { return }
        isRunning = true
        view.startProcess(
            executable: ps.executable,
            args: ps.args,
            environment: ps.environment,
            execName: ps.execName,
            currentDirectory: ps.currentDirectory
        )
        logger.debug("PTY started (after layout): \(self.command) in \(self.workingDirectory), terminalId=\(self.terminalId.uuidString.prefix(8))")
    }

    // MARK: - Shell Readiness Detection

    /// Unified processing entry after receiving PTY output (triggered by OmLocalProcessTerminalView.dataReceived callback)
    private func handleDataReceived(_ text: String) {
        // Forward to external callback (session.recordOutput, etc.)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDataReceived?(text)
            recordOutputForScrollback(text)
        }
        // Shell readiness detection (100ms of silence is considered ready, benchmarked against Maestri quick startup)
        lastOutputTime = .now
        guard !shellReadyCalled, !shellReadyScheduled else { return }
        guard !pendingStartupCommands.isEmpty || shellReadyCallback != nil else {
            shellReadyCalled = true
            return
        }
        shellReadyScheduled = true
        Task { @MainActor [weak self] in
            // Quick detection: 100ms interval polling, wait up to 3s
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !self.shellReadyCalled else { return }
                if ContinuousClock.now - self.lastOutputTime >= .milliseconds(80) {
                    self.fireShellReady()
                    return
                }
            }
            self?.fireShellReady()
        }
    }

    private func fireShellReady() {
        guard !shellReadyCalled else { return }
        shellReadyCalled = true
        if !pendingStartupCommands.isEmpty {
            let combined = pendingStartupCommands.joined(separator: " && ")
            pendingStartupCommands.removeAll()
            write(combined + "\n")
        }
        shellReadyCallback?()
        shellReadyCallback = nil
    }

    /// External force flag shell ready (for TerminalManager timeout path call)
    /// Prevent processTerminated from triggering drainNext again after timeout
    func forceMarkShellReady() {
        shellReadyCalled = true
        shellReadyCallback = nil
        pendingStartupCommands.removeAll()
    }

    // MARK: - PTY write

    func write(_ text: String) {
        guard let view = terminalView, isRunning else { return }
        view.send(txt: text)
    }

    func writeLine(_ text: String) {
        write(text + "\n")
    }

    // MARK: - Stop

    func stop() {
        // Clean terminalView even if PTY does not complete startup (isRunning=false, pendingStart pending)
        pendingStart = nil
        scrollbackDebounceTask?.cancel()
        scrollbackDebounceTask = nil
        guard isRunning else {
            terminalView?.removeFromSuperview()
            terminalView = nil
            return
        }
        isRunning = false
        // Take the last scrollback snapshot before exiting (must be before terminalView is set to nil)
        if let view = terminalView, let wsId = workspaceId {
            let terminal = view.getTerminal()
            let data = terminal.getBufferAsData()
            if !data.isEmpty {
                let fullText = String(decoding: data, as: UTF8.self)
                var lines = fullText.components(separatedBy: "\n")
                while let last = lines.last, last.isEmpty { lines.removeLast() }
                if !lines.isEmpty {
                    let maxLines = 5000
                    let toKeep = lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
                    let entries = toKeep.map { ScrollbackEntry(attributes: [], text: $0) }
                    Task.detached { [scrollbackStore, terminalId] in
                        try? await scrollbackStore.save(entries: entries, terminalId: terminalId, workspaceId: wsId)
                    }
                }
            }
        }
        terminalView?.terminate()
        terminalView = nil
    }

    // MARK: - scroll lock

    private(set) var isAutoScrollLocked: Bool = false

    func setAutoScrollLocked(_ locked: Bool) {
        isAutoScrollLocked = locked
        logger.debug("Terminal \(self.terminalId.uuidString.prefix(8)) autoScrollLocked=\(locked)")
    }

    // MARK: - Process restart

    func restartProcess(command: String, workingDirectory: String) {
        write("exit\n")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            let escapedPath = workingDirectory.replacingOccurrences(of: "'", with: "'\\''")
            let launchCmd = command.isEmpty ? "zsh --login" : command
            self.write("cd '\(escapedPath)' && \(launchCmd)\n")
            self.logger.debug("Terminal \(self.terminalId.uuidString.prefix(8)) restarted in \(workingDirectory)")
        }
    }

    // MARK: - Metal Renderer

    private func enableMetalIfNeeded(view: LocalProcessTerminalView, metalEnabled: Bool) {
        guard metalEnabled else { return }
        // SwiftTerm's Metal renderer relies on Bundle.module (SwiftTerm_SwiftTerm.bundle) to load and compile the
        // metallib. Bundle.module's one-time init will trigger an assertionFailure crash when the bundle does not exist.
        // Therefore verify that the bundle is available before enabling Metal, and safely downgrade to CPU rendering if missing.
        guard SwiftTermProvider.isMetalBundleAvailable() else {
            logger.warning("SwiftTerm Metal bundle not found — Metal renderer disabled for terminal \(self.terminalId.uuidString.prefix(8))")
            return
        }
        Task { @MainActor in
            do {
                try view.setUseMetal(true)
                self.logger.debug("Metal renderer enabled for terminal \(self.terminalId.uuidString.prefix(8))")
            } catch {
                self.logger.warning("Failed to enable Metal renderer: \(error.localizedDescription)")
            }
        }
    }

    /// Check if SwiftTerm's Metal shader bundle exists.
    /// swift build puts SwiftTerm_SwiftTerm.bundle in the same directory as the executable file;
    /// When packaging as .app, you need to copy the bundle to Contents/Resources/.
    /// Otherwise Bundle.module (automatically generated by swift build) cannot find the bundle and trigger a fatalError crash.
    private static func isMetalBundleAvailable() -> Bool {
        let bundleName = "SwiftTerm_SwiftTerm.bundle"
        // 1. Resources directory of app bundle (normal packaging path)
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent(bundleName).path) {
            return true
        }
        // 2. The executable file is in the same directory (when swift build is run directly)
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let execDir,
           FileManager.default.fileExists(atPath: execDir.appendingPathComponent(bundleName).path) {
            return true
        }
        return false
    }

    func applyMetalRenderer(enabled: Bool) {
        guard let view = terminalView else { return }
        // Also do bundle checking when enabled to avoid crashes triggered by setting UI
        if enabled, !SwiftTermProvider.isMetalBundleAvailable() {
            logger.warning("SwiftTerm Metal bundle not found — ignoring Metal enable request for terminal \(self.terminalId.uuidString.prefix(8))")
            return
        }
        do {
            try view.setUseMetal(enabled)
            logger.debug("Metal renderer \(enabled ? "enabled" : "disabled") for terminal \(self.terminalId.uuidString.prefix(8))")
        } catch {
            logger.warning("Failed to toggle Metal renderer: \(error.localizedDescription)")
        }
    }

    // MARK: - Theme application

    private func applyThemeWithPrefs(to view: LocalProcessTerminalView, prefs: Preferences) {
        let themeId = TerminalThemeRegistry.resolveThemeId(from: prefs.terminalTheme)
        TerminalThemeRegistry.shared.apply(themeId: themeId, to: view)
    }

    func applyCurrentTheme(to view: LocalProcessTerminalView) {
        let preference: String
        if let prefs = try? PersistenceManager.shared.loadPreferences() {
            preference = prefs.terminalTheme
        } else {
            preference = "dark"
        }
        let themeId = TerminalThemeRegistry.resolveThemeId(from: preference)
        TerminalThemeRegistry.shared.apply(themeId: themeId, to: view)
    }

    func applyTheme(_ themeId: String) {
        guard let view = terminalView else { return }
        TerminalThemeRegistry.shared.apply(themeId: themeId, to: view)
    }

    // MARK: - Font application

    private func applyFontWithPrefs(to view: LocalProcessTerminalView, prefs: Preferences) {
        view.font = resolveTerminalFont(family: prefs.terminalFontFamily, size: prefs.terminalFontSize)
    }

    func applyCurrentFont(to view: LocalProcessTerminalView) {
        if let prefs = try? PersistenceManager.shared.loadPreferences() {
            view.font = resolveTerminalFont(family: prefs.terminalFontFamily, size: prefs.terminalFontSize)
            view.setFrameSize(view.frame.size)
        }
    }

    func applyFont(family: String, size: CGFloat) {
        guard let view = terminalView else { return }
        view.font = resolveTerminalFont(family: family, size: size)
        view.setFrameSize(view.frame.size)
        logger.debug("Font updated to \(family) \(size)pt for terminal \(self.terminalId.uuidString.prefix(8))")
    }

    // MARK: - Scrollback recovery (feed history to terminal view on startup)

    /// Feed saved scrollback data to terminal view before PTY startProcess.
    /// reflow when resize may cause display misalignment, but disk snapshot passes snapshotScrollbackBeforeResize
    /// Protection without losing history.
    private func feedScrollbackBeforeStart(view: LocalProcessTerminalView, workspaceId: UUID) {
        let store = ScrollbackStore()
        guard let entries = try? store.load(terminalId: terminalId, workspaceId: workspaceId),
              !entries.isEmpty else { return }

        // Detect old format data (including CSI sequences such as cursor movement): skip recovery if found
        let sampleEntries = entries.suffix(min(20, entries.count))
        let hasCursorMovement = sampleEntries.contains { entry in
            entry.text.range(of: "\u{1b}\\[[0-9;]*[ABCDHJKf]", options: .regularExpression) != nil
        }
        if hasCursorMovement {
            logger.debug("Scrollback contains legacy PTY data with cursor sequences, skipping restore for terminal \(self.terminalId.uuidString.prefix(8))")
            return
        }

        // Get the last 2000 rows
        let maxRestoreLines = 2000
        let toRestore = entries.count > maxRestoreLines
            ? Array(entries.suffix(maxRestoreLines))
            : entries

        let text = toRestore.map { $0.text }.joined(separator: "\r\n")
        guard !text.isEmpty else { return }

        view.feed(text: text + "\r\n")
        logger.debug("Scrollback restored: \(toRestore.count) lines for terminal \(self.terminalId.uuidString.prefix(8))")
    }

    // MARK: - Scrollback persistence (extracts rendered screen lines from terminal buffer)

    /// Extract all lines (scrollback + visual area) from SwiftTerm terminal buffer and save as JSONL.
    /// Each line is the plain text output of translateToString, without control sequences such as cursor movement/clearing the screen.
    /// Safely feed to any size terminal without misalignment when restoring.
    func recordOutputForScrollback(_ text: String) {
        // resize is skipped during the freezing period to prevent buffers damaged by reflow from being persisted
        guard !scrollbackFrozen else { return }
        // Mark new data arrival, trigger debounce snapshot saving
        scrollbackDirty = true
        if scrollbackDebounceTask == nil {
            scrollbackDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await self?.flushScrollback()
                self?.scrollbackDebounceTask = nil
            }
        }
    }

    /// Is there new data that requires a snapshot?
    private var scrollbackDirty = false

    /// Briefly freeze scrollback writing after resize to prevent the buffer from overwriting the disk snapshot after reflow.
    private var scrollbackFrozen = false

    /// Extract all lines from terminal buffer and persist
    func flushScrollback() async {
        guard scrollbackDirty, let wsId = workspaceId, let view = terminalView else { return }
        scrollbackDirty = false

        // Get the entire buffer content (including scrollback + visual area) through SwiftTerm public API
        // getBufferAsData internally iterates over buffer.lines and calls translateToString(trimRight: true) for each line
        // The result is plain text (no cursor movement sequence) with each line separated by \n
        let terminal = view.getTerminal()
        let data = terminal.getBufferAsData()
        guard !data.isEmpty else { return }

        let fullText = String(decoding: data, as: UTF8.self)
        var lines = fullText.components(separatedBy: "\n")

        // Remove trailing blank lines
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }

        guard !lines.isEmpty else { return }

        // Convert to ScrollbackEntry and persist
        let maxLines = 5000
        let toKeep = lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
        let entries = toKeep.map { ScrollbackEntry(attributes: [], text: $0) }
        try? await scrollbackStore.save(entries: entries, terminalId: terminalId, workspaceId: wsId)
    }

    func flushScrollbackNow() {
        Task { await flushScrollback() }
    }

    /// Resize pre-synchronous call: write the current buffer content to disk immediately without debounce.
    /// Must be called before terminalView.frame changes (triggering SwiftTerm reflow),
    /// Otherwise, reflow will destroy the buffer content, causing the history record to be lost.
    func snapshotScrollbackBeforeResize() {
        guard let wsId = workspaceId, let view = terminalView else { return }
        let terminal = view.getTerminal()
        let data = terminal.getBufferAsData()
        guard !data.isEmpty else { return }

        let fullText = String(decoding: data, as: UTF8.self)
        var lines = fullText.components(separatedBy: "\n")
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return }

        let maxLines = 5000
        let toKeep = lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
        let entries = toKeep.map { ScrollbackEntry(attributes: [], text: $0) }

        // Cancel the ongoing debounce task to avoid damaging the buffer after resize and overwriting this snapshot.
        scrollbackDebounceTask?.cancel()
        scrollbackDebounceTask = nil
        scrollbackDirty = false

        // Freeze scrollback writing for 2 seconds: PTY may have output (SIGWINCH response) immediately after resize completes,
        // At this time, the buffer has been destroyed by reflow, and these outputs cannot be allowed to trigger a new flush.
        scrollbackFrozen = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.scrollbackFrozen = false
        }

        let store = scrollbackStore
        let termId = terminalId
        Task.detached(priority: .utility) {
            try? await store.save(entries: entries, terminalId: termId, workspaceId: wsId)
        }
        logger.debug("Pre-resize snapshot: \(toKeep.count) lines for terminal \(self.terminalId.uuidString.prefix(8))")
    }
}


// MARK: - LocalProcessTerminalViewDelegate

extension SwiftTermProvider: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        let tid = terminalId
        Task { @MainActor in
            Logger.make(category: "SwiftTermProvider").debug("Terminal \(tid.uuidString.prefix(8)) resized: \(newCols)x\(newRows)")
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            self.onTitleChange?(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        let tid = terminalId
        Task { @MainActor in
            TerminalManager.shared.terminals[tid]?.updateCurrentDirectory(directory)
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.isRunning = false
            await self.flushScrollback()
            self.onProcessExit?(exitCode)
            Logger.make(category: "SwiftTermProvider").info("Terminal \(self.terminalId.uuidString.prefix(8)) terminated with code \(exitCode ?? -1)")
            // Force trigger to advance serial boot queue if shell was never ready (e.g. command does not exist) when PTY exits
            if !self.shellReadyCalled {
                self.fireShellReady()
            }
        }
    }
}

// MARK: - OmLocalProcessTerminalView (subclassed to get PTY output without breaking the send link)

/// Subclass LocalProcessTerminalView, overriding dataReceived to get PTY output text.
/// Leave terminalDelegate = self unchanged (LocalProcessTerminalView set in setup),
/// Thus send(source:data:) is still handled by LocalProcessTerminalView itself → process.send.
final class OmLocalProcessTerminalView: LocalProcessTerminalView {
    /// Callback when PTY has new output (original text)
    var onDataReceived: ((String) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if let text = String(bytes: slice, encoding: .utf8) {
            onDataReceived?(text)
        }
    }
}
