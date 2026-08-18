import Foundation

/// AppKit layer (CanvasNodesView) relays menu actions to SwiftUI layer (FileTreeNodeSwiftUIView).
/// Using NotificationCenter broadcast, the SwiftUI view modifies its own @State after listening through .onReceive.
enum NavBarMenuAction {
    static let setViewMode  = Notification.Name("NavBarMenu.setViewMode")
    static let toggleHidden = Notification.Name("NavBarMenu.toggleHidden")
    static let collapseAll  = Notification.Name("NavBarMenu.collapseAll")

    static let nodeIdKey   = "nodeId"
    static let viewModeKey = "viewMode"
}

final class NavBarMenuActionRelay {
    static let shared = NavBarMenuActionRelay()
    private init() {}

    func setViewMode(_ mode: FileTreeViewMode, for nodeId: UUID) {
        NotificationCenter.default.post(
            name: NavBarMenuAction.setViewMode,
            object: nil,
            userInfo: [NavBarMenuAction.nodeIdKey: nodeId,
                       NavBarMenuAction.viewModeKey: mode]
        )
    }

    func toggleHidden(for nodeId: UUID) {
        NotificationCenter.default.post(
            name: NavBarMenuAction.toggleHidden,
            object: nil,
            userInfo: [NavBarMenuAction.nodeIdKey: nodeId]
        )
    }

    func collapseAll(for nodeId: UUID) {
        NotificationCenter.default.post(
            name: NavBarMenuAction.collapseAll,
            object: nil,
            userInfo: [NavBarMenuAction.nodeIdKey: nodeId]
        )
    }
}
