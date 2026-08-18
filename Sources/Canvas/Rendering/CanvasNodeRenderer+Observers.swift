import AppKit
import SwiftUI

// MARK: - Notification Observers

extension CanvasNodeRenderer {

    func setupActivationObserver() {
        let obs = NotificationCenter.default.addObserver(
            forName: .canvasNodeActivated, object: nil, queue: .main
        ) { [weak self] notif in
            guard let id = notif.userInfo?["nodeId"] as? UUID else { return }
            if let provider = TerminalManager.shared.providers[id],
               let tv = provider.terminalView {
                tv.window?.makeFirstResponder(tv)
            }
            // Portal node is not focused here - accurately determined by CanvasInteractionHandler based on click location
        }
        notificationObservers.append(obs)
    }

    func setupSelectionObserver() {
        let obs = NotificationCenter.default.addObserver(
            forName: .canvasSelectionChanged, object: nil, queue: .main
        ) { [weak self] notif in
            guard let self,
                  let canvas = self.canvas,
                  let ids = notif.userInfo?["selectedIds"] as? Set<UUID> else { return }
            guard let current = self.nodesHostingView?.rootView else { return }
            // Note: You cannot skip just because selectedNodeIds remain unchanged - the node sorting has been updated when zIndex changes.
            // The rootView must be rebuilt with the latest viewportCulledNodes() in order for the render layers to reflect the new hierarchy order
            let lockedIds = Set(canvas.currentNodes.filter { $0.isLocked }.map { $0.id })
            self.nodesHostingView?.rootView = CanvasNodesSwiftUIView(
                nodes: canvas.viewportCulledNodes(),
                canvasOrigin: canvas.canvasOrigin,
                zoom: canvas.zoom,
                selectedNodeIds: ids,
                lockedNodeIds: lockedIds,
                workspace: current.workspace,
                dropTargetNodeId: current.dropTargetNodeId,
                onActivated: current.onActivated,
                onClose: current.onClose,
                onRename: current.onRename,
                onDuplicate: current.onDuplicate,
                onLockToggle: current.onLockToggle
            )
        }
        notificationObservers.append(obs)
    }

    func setupDropTargetObserver() {
        let obs = NotificationCenter.default.addObserver(
            forName: .canvasDropTargetChanged, object: nil, queue: .main
        ) { [weak self] notif in
            guard let self,
                  let canvas = self.canvas else { return }
            let dropTargetId = notif.userInfo?["dropTargetNodeId"] as? UUID
            guard let current = self.nodesHostingView?.rootView,
                  current.dropTargetNodeId != dropTargetId else { return }
            self.nodesHostingView?.rootView = CanvasNodesSwiftUIView(
                nodes: canvas.viewportCulledNodes(),
                canvasOrigin: canvas.canvasOrigin,
                zoom: canvas.zoom,
                selectedNodeIds: current.selectedNodeIds,
                lockedNodeIds: current.lockedNodeIds,
                workspace: current.workspace,
                dropTargetNodeId: dropTargetId,
                onActivated: current.onActivated,
                onClose: current.onClose,
                onRename: current.onRename,
                onDuplicate: current.onDuplicate,
                onLockToggle: current.onLockToggle
            )
        }
        notificationObservers.append(obs)
    }

    func setupNodeStateObservers() {
        // Node isLocked change: synchronized to canvas.currentNodes
        let lockObs = NotificationCenter.default.addObserver(
            forName: .canvasNodeLockChanged, object: nil, queue: .main
        ) { [weak self] notif in
            guard let id = notif.userInfo?["nodeId"] as? UUID,
                  let locked = notif.userInfo?["isLocked"] as? Bool else { return }
            self?.canvas?.updateNodeLockedInPlace(id: id, isLocked: locked)
        }
        notificationObservers.append(lockObs)

        // Node content change: synchronized to canvas.currentNodes
        let contentObs = NotificationCenter.default.addObserver(
            forName: .canvasNodeContentChanged, object: nil, queue: .main
        ) { [weak self] notif in
            guard let self,
                  let id = notif.userInfo?["nodeId"] as? UUID,
                  let content = notif.userInfo?["content"] as? NodeContent else { return }
            canvas?.updateNodeContentInPlace(id: id, content: content)
            // If a new frame is carried (automatically measured when the text node content/style changes), the canvas frame is updated synchronously
            if let newFrame = notif.userInfo?["frame"] as? CGRect {
                canvas?.updateNodeFrameInPlace(id: id, frame: newFrame)
                canvas?.nodeCanvasFrames[id] = newFrame
            }
            // displayName synchronization
            if case .terminal(let tc) = content {
                TerminalManager.shared.terminals[id]?.displayName = tc.name
            }
            // Refresh SwiftUI node layer
            guard let canvas, let current = nodesHostingView?.rootView else { return }
            let lockedIds = Set(canvas.currentNodes.filter { $0.isLocked }.map { $0.id })
            nodesHostingView?.rootView = CanvasNodesSwiftUIView(
                nodes: canvas.viewportCulledNodes(),
                canvasOrigin: canvas.canvasOrigin,
                zoom: canvas.zoom,
                selectedNodeIds: canvas.selectedNodeIds,
                lockedNodeIds: lockedIds,
                workspace: current.workspace,
                dropTargetNodeId: current.dropTargetNodeId,
                onActivated: current.onActivated,
                onClose: current.onClose,
                onRename: current.onRename,
                onDuplicate: current.onDuplicate,
                onLockToggle: current.onLockToggle
            )
        }
        notificationObservers.append(contentObs)

        // Connection status changes (ask communication starts/ends): Immediately rebuild the status cache and re-render the connection line
        let connStatusObs = NotificationCenter.default.addObserver(
            forName: .connectionStatusChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildConnectionStatusCache()
            self?.rerenderConnections()
        }
        notificationObservers.append(connStatusObs)
    }
}
