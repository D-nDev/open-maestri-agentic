import SwiftUI
import AppKit
import SwiftTerm

/// Terminal embedded view (NSViewRepresentable wrapper MaestroTerminalView)
/// makeNSView returns MaestroTerminalView (direct subclass of NSView), Coordinator holds provider
struct TerminalEmbeddedView: NSViewRepresentable {
    let terminalId: UUID
    let command: String
    let workingDirectory: String
    var serverPort: UInt16 = 0
    var workspaceId: UUID?
    /// Node-level theme/font overrides (nil means follow global Preferences)
    var nodeThemeId: String?
    var nodeFontFamily: String?
    var nodeFontSize: CGFloat?

    // MARK: - Coordinator
    @MainActor
    final class Coordinator: NSObject {
        var provider: SwiftTermProvider?
        var isAttached: Bool = false
        var lastTheme: String = ""
        var lastFontName: String = ""
        var lastFontSize: CGFloat = 0

        private var providerReadyObserver: NSObjectProtocol?
        private var shellReadyObserver: NSObjectProtocol?

        func setupObservers(terminalId: UUID, maestroView: MaestroTerminalView) {
            teardownObservers()
            providerReadyObserver = NotificationCenter.default.addObserver(
                forName: .terminalProviderReady, object: nil, queue: .main
            ) { [weak self, weak maestroView] notif in
                guard let tid = notif.userInfo?["terminalId"] as? UUID, tid == terminalId,
                      let self, let maestroView else { return }
                Task { @MainActor in
                    self.attachIfNeeded(to: maestroView, terminalId: terminalId)
                }
            }
            shellReadyObserver = NotificationCenter.default.addObserver(
                forName: .terminalShellReady, object: nil, queue: .main
            ) { [weak maestroView] notif in
                guard let tid = notif.userInfo?["terminalId"] as? UUID, tid == terminalId,
                      let wsId = notif.userInfo?["workspaceId"] as? UUID else { return }
                Task { @MainActor in
                    maestroView?.loadScrollback(workspaceId: wsId)
                }
            }
        }

        func teardownObservers() {
            if let obs = providerReadyObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = shellReadyObserver { NotificationCenter.default.removeObserver(obs) }
            providerReadyObserver = nil
            shellReadyObserver = nil
        }

        @MainActor
        func attachIfNeeded(to maestroView: MaestroTerminalView, terminalId: UUID) {
            guard let provider = TerminalManager.shared.providers[terminalId] else { return }
            // If it has been attached and the provider has not changed, skip (normal situation)
            // If the provider is replaced (terminal restart), force reattach
            if isAttached && self.provider === provider { return }
            self.provider = provider
            maestroView.attach(provider: provider)
            isAttached = true
        }

        deinit {
            // deinit is nonisolated, copy the observer reference and clean it asynchronously
            let obs1 = providerReadyObserver
            let obs2 = shellReadyObserver
            if let obs1 { NotificationCenter.default.removeObserver(obs1) }
            if let obs2 { NotificationCenter.default.removeObserver(obs2) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    func makeNSView(context: Context) -> MaestroTerminalView {
        let maestroView = MaestroTerminalView(terminalId: terminalId)
        maestroView.autoresizingMask = [.width, .height]
        context.coordinator.setupObservers(terminalId: terminalId, maestroView: maestroView)

        // If the provider is ready (the workspace is switched back), attach directly;
        // Skip the placeholder background color setting at this time, because attach() will clear layer.backgroundColor internally immediately.
        // Avoid one-frame flickering of "Background Color → Terminal Content".
        let providerReady = TerminalManager.shared.providers[terminalId] != nil
        if !providerReady {
            maestroView.updateBackgroundFromTheme()
        }
        context.coordinator.attachIfNeeded(to: maestroView, terminalId: terminalId)
        return maestroView
    }

    @MainActor
    func updateNSView(_ nsView: MaestroTerminalView, context: Context) {
        // Only theme/font delta update (resize is handled by MaestroTerminalView.layout())
        guard context.coordinator.isAttached, let tv = nsView.terminalView else { return }
        let prefs = (try? PersistenceManager.shared.loadPreferences()) ?? Preferences()

        // Prioritize the node's own settings and fall back to global Preferences
        let effectiveThemePref = nodeThemeId ?? prefs.terminalTheme
        let themeId = TerminalThemeRegistry.resolveThemeId(from: effectiveThemePref)
        if context.coordinator.lastTheme != themeId {
            TerminalThemeRegistry.shared.apply(themeId: themeId, to: tv)
            context.coordinator.lastTheme = themeId
        }

        let effectiveFamily = nodeFontFamily ?? prefs.terminalFontFamily
        let effectiveSize = nodeFontSize ?? prefs.terminalFontSize
        if context.coordinator.lastFontName != effectiveFamily
            || context.coordinator.lastFontSize != effectiveSize {
            tv.font = resolveTerminalFont(family: effectiveFamily, size: effectiveSize)
            context.coordinator.lastFontName = effectiveFamily
            context.coordinator.lastFontSize = effectiveSize
            // SwiftTerm's resetFont() calculates cols as frame.width / cellWidth, omitting
            // scrollerWidth. Re-trigger setFrameSize so processSizeChange corrects cols
            // (cols = (width - scrollerWidth) / cellWidth), fixing cursor x offset.
            tv.setFrameSize(tv.frame.size)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: MaestroTerminalView, coordinator: Coordinator) {
        coordinator.teardownObservers()
        nsView.detach()
        coordinator.isAttached = false
        coordinator.provider = nil
    }
}
