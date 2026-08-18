import AppKit
import OSLog
import SwiftTerm

/// Direct subclass of NSView, corresponding to Maestri's MaestroTerminalView.
/// canvas's layout() directly sets its frame, SwiftTerm internal setFrameSize → processSizeChange
/// Automatically handle resize + SIGWINCH, completely bypassing SwiftUI diff.
@MainActor
final class MaestroTerminalView: NSView {
    private let logger = Logger.make(category: "MaestroTerminalView")
    private(set) var terminalView: LocalProcessTerminalView?
    let terminalId: UUID
    private(set) var isRunning: Bool = false
    var canvasZoom: CGFloat = 1.0
    var onDataReceived: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onProcessExit: ((Int32?) -> Void)?

    /// resize anti-shake: temporarily store target bounds, tv.frame is actually updated after 200ms of silence
    private var pendingBounds: CGRect = .zero
    private var resizeDebounceTask: Task<Void, Never>?
    /// true = terminalView appears in layout for the first time, skips anti-shake and synchronizes directly
    private var isInitialLayout: Bool = true

    /// Freeze layout during canvas scaling to prevent scaleEffect's CALayer transform from changing
    /// Triggering a Metal drawable rebuild causes terminal content to flicker.
    /// layout() skips all terminalView.frame modifications during freeze;
    /// unfreezeAfterZoom() synchronizes the frame immediately after unfreezing.
    private(set) var isFrozenForZoom: Bool = false

    init(terminalId: UUID, frame: NSRect = .zero) {
        self.terminalId = terminalId
        super.init(frame: frame)
        wantsLayer = true
        updateBackgroundFromTheme()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

// MARK: - attach / detach

extension MaestroTerminalView {
    /// First call starts PTY and addSubview; second call only re-attach (does not restart PTY).
    func attach(provider: SwiftTermProvider) {
        if let existing = provider.terminalView {
            if existing.superview != self {
                // re-attach/restart: Remove the old terminalView (if any) first, and then mount the new one
                let isRestart = terminalView != nil && terminalView !== existing
                if let old = terminalView, old !== existing {
                    old.removeFromSuperview()
                }
                layer?.backgroundColor = nil
                existing.removeFromSuperview()
                existing.frame = bounds
                existing.autoresizingMask = [.width, .height]
                addSubview(existing)
                // Restart scenario: The new terminalView needs to trigger firePendingStart() through layout()
                if isRestart { isInitialLayout = true }
            }
            terminalView = existing
            isRunning = provider.isRunning
            applyThemeAndFont(to: existing, provider: provider)
            return
        }

        let tv = provider.start(in: bounds)
        tv.autoresizingMask = [.width, .height]
        addSubview(tv)
        terminalView = tv
        isRunning = false  // PTY is not actually started until after firePendingStart()

        provider.onTitleChange = { [weak self] title in
            self?.onTitleChange?(title)
        }
        logger.debug("Attached terminal \(self.terminalId.uuidString.prefix(8))")
    }

    /// removeFromSuperview, does not stop PTY (for workspace switching).
    func detach() {
        terminalView?.removeFromSuperview()
        // terminalView already has the correct frame when re-attaching isInitialLayout without resetting it.
        // There is no need to go through the firePendingStart path of the first layout to avoid unnecessary frame reset.
        logger.debug("Detached terminal \(self.terminalId.uuidString.prefix(8))")
    }

    private func applyThemeAndFont(to tv: LocalProcessTerminalView, provider: SwiftTermProvider) {
        let prefs = (try? PersistenceManager.shared.loadPreferences()) ?? Preferences()
        let themeId = TerminalThemeRegistry.resolveThemeId(from: prefs.terminalTheme)
        TerminalThemeRegistry.shared.apply(themeId: themeId, to: tv)
        let font = NSFont(name: prefs.terminalFontFamily, size: prefs.terminalFontSize)
            ?? NSFont.monospacedSystemFont(ofSize: prefs.terminalFontSize, weight: .regular)
        tv.font = font
        // resetFont() computes cols from frame.width without subtracting scrollerWidth;
        // re-trigger setFrameSize so processSizeChange corrects cols and cursor position.
        tv.setFrameSize(tv.frame.size)
        // Clear the placeholder background after attach is completed to avoid covering SwiftTerm’s own layer
        layer?.backgroundColor = nil
    }

    /// Fill the layer with the background color of the current theme as a placeholder color before PTY attach to prevent flickering.
    /// Only called when the provider is not ready yet (created for the first time), the re-attach scenario is skipped.
    func updateBackgroundFromTheme() {
        let prefs = (try? PersistenceManager.shared.loadPreferences()) ?? Preferences()
        let themeId = TerminalThemeRegistry.resolveThemeId(from: prefs.terminalTheme)
        if let theme = TerminalThemeRegistry.shared.theme(for: themeId),
           let color = NSColor(hex: theme.background) {
            layer?.backgroundColor = color.cgColor
        } else {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
}

// MARK: - Layout

extension MaestroTerminalView {
    override func layout() {
        super.layout()
        guard let tv = terminalView else {
            isInitialLayout = true
            return
        }

        let newBounds = bounds

        // The first layout (the first time to get the real size after attach): takes precedence over the size equality check,
        // Ensure firePendingStart() is not skipped by the "size == .zero equal" case.
        // bounds == .zero indicates that the view has not been laid out yet and is skipped to prevent the PTY from starting with zero size.
        if isInitialLayout {
            guard newBounds.size != .zero else { return }
            isInitialLayout = false
            tv.frame = newBounds
            // PTY startup is delayed here to ensure terminal.cols is calculated based on real frame
            TerminalManager.shared.providers[terminalId]?.firePendingStart()
            return
        }

        // bounds has not changed, only origin is synchronized (panning canvas and other scenes)
        if tv.frame.size == newBounds.size {
            tv.frame = newBounds
            return
        }

        // During canvas scaling: freeze terminalView.frame and let scaleEffect do purely visual stretching.
        // Metal layer does not sense bounds changes, does not trigger drawable reconstruction, and eliminates flickering.
        // unfreezeAfterZoom() will synchronize the correct frame once after the zoom is completed.
        if isFrozenForZoom {
            pendingBounds = newBounds
            return
        }

        // bounds are changing (resize dragging): Use anti-shake to avoid triggering SwiftTerm reflow every frame.
        // First lock the terminal subview at the old size (the content is stable and does not flicker), and then wait for 200ms of silence before actually resizing.
        pendingBounds = newBounds
        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.commitResize()
        }
    }

    private func commitResize() {
        guard let tv = terminalView, tv.frame.size != pendingBounds.size else {
            terminalView?.frame = pendingBounds
            return
        }
        // Snapshot the scrollback before resize is actually implemented to prevent reflow from destroying the buffer.
        TerminalManager.shared.providers[terminalId]?.snapshotScrollbackBeforeResize()
        tv.frame = pendingBounds
    }

    // MARK: - Zoom Freeze/Unfreeze

    /// Called when canvas pinch zoom starts: freezes terminalView frame, preventing Metal drawable from rebuilding.
    func freezeForZoom() {
        guard !isFrozenForZoom else { return }
        isFrozenForZoom = true
        // Cancel the resize anti-shake task, and unfreezeAfterZoom will handle it after zooming.
        resizeDebounceTask?.cancel()
        resizeDebounceTask = nil
    }

    /// Called when the canvas pinch zoom ends: unfreeze and immediately synchronize the correct frame (with anti-shake to avoid reflow).
    func unfreezeAfterZoom() {
        guard isFrozenForZoom else { return }
        isFrozenForZoom = false
        guard pendingBounds.size != .zero else { return }
        // Use 200ms for anti-shake landing final frame (consistent with resize drag end behavior)
        resizeDebounceTask?.cancel()
        resizeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.commitResize()
        }
    }
}

// MARK: - Scrollback (feed recovery disabled)

extension MaestroTerminalView {
    /// Scrollback recovery disabled: refeed old PTY output (with ANSI escapes) into terminal buffer
    /// It will cause rendering problems such as disordered wrapping of lines after resize and offset of cursor position.
    /// History is maintained in memory via TerminalSession.bulkLoadHistory,
    /// Used by APIs such as omaestri check, but no longer echoed to the terminal interface.
    func loadScrollback(workspaceId: UUID) {
        // no-op: No longer feed historical text back to the terminal view
    }
}
