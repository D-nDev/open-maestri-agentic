import AppKit
import OSLog

extension CanvasViewportView {

    // MARK: - Keyboard events

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""

        // ⌘W - Delete selected node
        if flags == .command && key == "w" {
            onDeleteSelectedNodes?()
            return
        }

        // \ - Focus/center selected node to viewport
        if key == "\\" && flags.isEmpty {
            focusSelectedNodeInViewport()
            return
        }

        // ⌘P - Filter/Search
        if flags == .command && key == "p" {
            NotificationCenter.default.post(name: .showCanvasFilter, object: nil)
            return
        }

        // L - Start the connection tool (official shortcut key, not ⌘L)
        if key == "l" && flags.isEmpty {
            if let firstSelected = selectedNodeIds.first {
                connectingFromNodeId = firstSelected
                isInConnectingMode = true
            }
            return
        }

        // H - Switch pan mode (Pan)
        if key == "h" && flags.isEmpty {
            togglePanMode()
            return
        }

        // ⌃Tab - Switch to the next terminal node
        if event.keyCode == CanvasKeyCode.tab && flags == .control {
            cycleTerminalFocus(forward: true)
            return
        }

        // ⌃⇧Tab - switch to the previous terminal node
        if event.keyCode == CanvasKeyCode.tab && flags == [.control, .shift] {
            cycleTerminalFocus(forward: false)
            return
        }

        // ⌘⇧B - Toggles the scroll lock of the currently selected terminal node
        if flags == [.command, .shift] && key == "b" {
            toggleAutoScrollLock()
            return
        }

        // Space - Enter panning mode
        if event.keyCode == CanvasKeyCode.space && !isSpaceHeld {
            isSpaceHeld = true
            NSCursor.openHand.set()
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        // Space Release - Exit Panning Mode
        if event.keyCode == CanvasKeyCode.space {
            isSpaceHeld = false
            if case .panCanvas = interaction { interaction = .idle }
            NSCursor.arrow.set()
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdHeld = flags.contains(.command)
        onNodeJumpNumbersRequested?(cmdHeld)
        assignJumpNumbers(visible: cmdHeld)

        // Space key detection (for Space+drag pan)
        // NSEvent.ModifierFlags does not contain Space, tracked via keyDown/keyUp
        super.flagsChanged(with: event)
    }

    /// ⌘ Assign jump numbers (1~9) to all Terminal nodes when pressed and clear when released
    private func assignJumpNumbers(visible: Bool) {
        // nodeViews is empty after NSHostingView migration; jump number is passed to SwiftUI layer through notification
        let terminalIds = currentNodes
            .filter { if case .terminal = $0.content { return true }; return false }
            .sorted { lhs, rhs in
                let lf = lhs.frame, rf = rhs.frame
                return lf.minX < rf.minX || (lf.minX == rf.minX && lf.minY < rf.minY)
            }
            .map { $0.id }
        var mapping: [UUID: Int] = [:]
        if visible {
            for (i, id) in terminalIds.enumerated() where i < 9 {
                mapping[id] = i + 1
            }
        }
        NotificationCenter.default.post(
            name: .canvasJumpNumbersAssigned,
            object: nil,
            userInfo: ["mapping": mapping]
        )
    }

    // MARK: - ⌘+number terminal jump

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘= / ⌘+ — Zoom in (center of viewport as anchor)
        if flags == .command,
           let key = event.charactersIgnoringModifiers,
           key == "=" || key == "+" {
            zoomCanvas(delta: +Constants.canvasZoomStep)
            return true
        }

        // ⌘- — Zoom out
        if flags == .command,
           let key = event.charactersIgnoringModifiers,
           key == "-" {
            zoomCanvas(delta: -Constants.canvasZoomStep)
            return true
        }

        // ⌘0 — Reset zoom to 100%
        if flags == .command,
           let key = event.charactersIgnoringModifiers,
           key == "0" {
            zoomCanvas(toAbsolute: 1.0)
            return true
        }

        // ⌘1…9 — Terminal jump
        if flags == .command, let key = event.charactersIgnoringModifiers,
           let num = Int(key), num >= 1 && num <= 9 {
            jumpToTerminal(number: num)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Keyboard zoom assist

    /// Using the center of the viewport as the anchor point, adjust the zoom in increments
    func zoomCanvas(delta: CGFloat) {
        applyZoom((zoom + delta).clamped(to: Constants.canvasMinZoom...Constants.canvasMaxZoom))
    }

    /// Using the center of the viewport as the anchor point, set the absolute zoom value (such as reset to 100%)
    func zoomCanvas(toAbsolute target: CGFloat) {
        applyZoom(target.clamped(to: Constants.canvasMinZoom...Constants.canvasMaxZoom))
    }

    /// Apply scale value with viewport center as anchor point (internal implementation)
    private func applyZoom(_ newZoom: CGFloat) {
        guard newZoom != zoom else { return }
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let canvasCenter = screenToCanvas(viewCenter)
        zoom = newZoom
        canvasOrigin = CGPoint(
            x: canvasCenter.x - viewCenter.x / zoom,
            y: canvasCenter.y - viewCenter.y / zoom
        )
        needsLayout = true
        needsDisplay = true
        notifyViewportChanged()
        onViewportPanned?()
    }

    private func jumpToTerminal(number: Int) {
        // NSHostingView uses currentNodes + nodeCanvasFrames after migration
        let sorted = currentNodes
            .filter { if case .terminal = $0.content { return true }; return false }
            .sorted { lhs, rhs in
                let lf = lhs.frame, rf = rhs.frame
                return lf.minX < rf.minX || (lf.minX == rf.minX && lf.minY < rf.minY)
            }
        guard number - 1 < sorted.count else { return }
        let targetNode = sorted[number - 1]
        // Focus on the corresponding TerminalView
        if let provider = TerminalManager.shared.providers[targetNode.id],
           let tv = provider.terminalView {
            window?.makeFirstResponder(tv)
        }
        selectedNodeIds = [targetNode.id]
        // Smoothly scroll viewport to center target
        scrollToCanvasFrame(targetNode.frame)
    }

    // MARK: - ⌃Tab terminal cycle switching

    /// Sort by the abscissa coordinate of the canvas and cycle to the next/previous terminal node
    func cycleTerminalFocus(forward: Bool) {
        let sorted = sortedTerminalNodes()
        guard !sorted.isEmpty else { return }

        // Find the currently focused terminal index
        let currentIndex: Int
        if let firstId = selectedNodeIds.first,
           let idx = sorted.firstIndex(where: { $0.id == firstId }) {
            currentIndex = idx
        } else {
            currentIndex = forward ? sorted.count - 1 : 0
        }

        let nextIndex: Int
        if forward {
            nextIndex = (currentIndex + 1) % sorted.count
        } else {
            nextIndex = (currentIndex - 1 + sorted.count) % sorted.count
        }

        let target = sorted[nextIndex]
        selectedNodeIds = [target.id]
        if let provider = TerminalManager.shared.providers[target.id],
           let tv = provider.terminalView {
            window?.makeFirstResponder(tv)
        }
        scrollToCanvasFrame(target.frame)
    }

    /// List of terminal nodes sorted by canvas x coordinate
    private func sortedTerminalNodes() -> [CanvasNode] {
        currentNodes
            .filter { if case .terminal = $0.content { return true }; return false }
            .sorted { lhs, rhs in
                let lf = lhs.frame, rf = rhs.frame
                return lf.minX < rf.minX || (lf.minX == rf.minX && lf.minY < rf.minY)
            }
    }

    /// Check back the UUID corresponding to the node view (for internal loop use, compatible with old code)
    func nodeId(forView view: NSView) -> UUID? {
        nodeId(for: view)
    }

    // MARK: - ⌘⇧B scroll lock

    /// Toggle the automatic scroll lock state of the currently selected terminal node
    private func toggleAutoScrollLock() {
        // NSHostingView operates through TerminalManager.providers after migration and does not rely on TerminalNodeView
        let targetIds: [UUID] = selectedNodeIds.isEmpty
            ? currentNodes.filter { if case .terminal = $0.content { return true }; return false }.map { $0.id }
            : Array(selectedNodeIds)

        for id in targetIds {
            guard let provider = TerminalManager.shared.providers[id] else { continue }
            let newLocked = !provider.isAutoScrollLocked
            provider.setAutoScrollLocked(newLocked)
        }
    }

    // MARK: - Focus on viewport

    func focusSelectedNodeInViewport() {
        guard let firstId = selectedNodeIds.first,
              let frame = nodeCanvasFrames[firstId] else { return }
        scrollToCanvasFrame(frame)
        onFocusSelectedNode?()
    }

    /// Immediately (without animation) jump to the specified canvas frame (used internally for synchronization)
    func scrollToCanvasFrame(_ canvasFrame: CGRect) {
        let newOriginX = canvasFrame.midX - (bounds.width / 2) / zoom
        let newOriginY = canvasFrame.midY - (bounds.height / 2) / zoom
        canvasOrigin = CGPoint(x: newOriginX, y: newOriginY)
        notifyViewportChanged()
        onViewportPanned?()
    }

    /// Smooth animation jumps to the specified canvas frame (duration=0.35s easeInOut)
    func scrollToCanvasFrameAnimated(_ canvasFrame: CGRect, duration: TimeInterval = 0.35) {
        let targetOriginX = canvasFrame.midX - (bounds.width / 2) / zoom
        let targetOriginY = canvasFrame.midY - (bounds.height / 2) / zoom
        let targetOrigin = CGPoint(x: targetOriginX, y: targetOriginY)
        let startTime = CACurrentMediaTime()
        animateOrigin(from: canvasOrigin, to: targetOrigin, startTime: startTime, duration: duration)
    }

    /// Smooth animation jumps to the specified view (compatible with old calls: pass NSView)
    func scrollToViewAnimated(_ view: NSView, duration: TimeInterval = 0.35) {
        // Check canvasFrame through viewToNodeId to avoid relying on nodeViews
        if let id = viewToNodeId[ObjectIdentifier(view)],
           let frame = nodeCanvasFrames[id] {
            scrollToCanvasFrameAnimated(frame, duration: duration)
        } else {
            // Downgrade: Backcalculate canvas coordinates using view.frame (screen coordinates)
            let screenCenter = CGPoint(x: view.frame.midX, y: view.frame.midY)
            let canvasCenter = screenToCanvas(screenCenter)
            let targetOriginX = canvasCenter.x - (bounds.width / 2) / zoom
            let targetOriginY = canvasCenter.y - (bounds.height / 2) / zoom
            let startTime = CACurrentMediaTime()
            animateOrigin(from: canvasOrigin, to: CGPoint(x: targetOriginX, y: targetOriginY),
                          startTime: startTime, duration: duration)
        }
    }

    /// Frame-by-frame interpolation canvasOrigin (easeInOut easing), using Timer 60fps driver
    func animateOrigin(from: CGPoint, to: CGPoint, startTime: CFTimeInterval, duration: TimeInterval) {
        animationTimer?.invalidate()
        animationTimer = nil

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(elapsed / duration, 1.0)
            let eased = Self.easeInOut(progress)
            self.canvasOrigin = CGPoint(
                x: from.x + (to.x - from.x) * eased,
                y: from.y + (to.y - from.y) * eased
            )
            self.notifyViewportChanged()
            self.onViewportPanned?()
            if progress >= 1.0 {
                t.invalidate()
                self.animationTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// easeInOut easing function
    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
    }

    // MARK: - Panning mode

    func togglePanMode() {
        isPanMode = !isPanMode
        NSCursor.closedHand.set()
    }

    // MARK: - Gestures (trackpad pan and zoom)

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘+wheel zoom (with mouse position as anchor point)
            let delta = event.scrollingDeltaY * 0.01
            let newZoom = (zoom + delta).clamped(to: Constants.canvasMinZoom...Constants.canvasMaxZoom)
            let mouseScreen = convert(event.locationInWindow, from: nil)
            let mouseCanvas = screenToCanvas(mouseScreen)
            zoom = newZoom
            canvasOrigin = CGPoint(
                x: mouseCanvas.x - mouseScreen.x / zoom,
                y: mouseCanvas.y - mouseScreen.y / zoom
            )
        } else {
            // Touchpad two-finger pan: natural scrolling (finger direction = content movement direction)
            canvasOrigin = CGPoint(
                x: canvasOrigin.x - event.scrollingDeltaX / zoom,
                y: canvasOrigin.y - event.scrollingDeltaY / zoom
            )
        }
        needsLayout = true
        // draw is only triggered when there are temporary connections (draw() is only responsible for drawing temporary connections, needsDisplay is wasted when there are no temporary connections)
        if connectingFromNodeId != nil {
            needsDisplay = true
        }
        notifyViewportChanged()
        // Immediately re-render the connection (without waiting for SwiftUI updateNSView loop)
        onViewportPanned?()
    }

    override func magnify(with event: NSEvent) {
        // Pinch start: Freeze all terminal layouts to prevent scaleEffect's CALayer transform from changing
        // Triggering Metal drawable rebuild causes flickering (terminalView.frame maintains old size during frozen)
        if event.phase == .began {
            setTerminalZoomFreeze(true)
        }

        let newZoom = (zoom * (1 + event.magnification))
            .clamped(to: Constants.canvasMinZoom...Constants.canvasMaxZoom)
        let mouseScreen = convert(event.locationInWindow, from: nil)
        let mouseCanvas = screenToCanvas(mouseScreen)
        zoom = newZoom
        canvasOrigin = CGPoint(
            x: mouseCanvas.x - mouseScreen.x / zoom,
            y: mouseCanvas.y - mouseScreen.y / zoom
        )
        needsLayout = true
        // draw is only triggered when there are temporary connections
        if connectingFromNodeId != nil {
            needsDisplay = true
        }
        notifyViewportChanged()
        // Immediately re-render the connection (without waiting for SwiftUI updateNSView loop)
        onViewportPanned?()

        // End of pinching: Unfreeze the terminal, trigger anti-shake once, resize the final size after landing
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            setTerminalZoomFreeze(false)
        }
    }

    /// Traverse all current terminal nodes and freeze or unfreeze the layout of their MaestroTerminalView.
    private func setTerminalZoomFreeze(_ freeze: Bool) {
        for node in currentNodes {
            guard case .terminal = node.content,
                  let provider = TerminalManager.shared.providers[node.id],
                  let maestroView = provider.terminalView?.superview as? MaestroTerminalView
            else { continue }
            if freeze {
                maestroView.freezeForZoom()
            } else {
                maestroView.unfreezeAfterZoom()
            }
        }
    }
}
