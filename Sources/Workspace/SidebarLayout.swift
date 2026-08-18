import Foundation

/// sidebar-layout.json persistence model (schemaVersion:2, benchmarking maestri-tech-analysis.md line 247)
struct SidebarLayout: Codable {
    var schemaVersion: Int = 2
    var topLevelItems: [UUID]   // Display order of workspace IDs
    var groups: [SidebarGroup]  // Collapse grouping

    init() {
        topLevelItems = []
        groups = []
    }
}

struct SidebarGroup: Codable, Identifiable {
    var id: UUID
    var name: String
    var isCollapsed: Bool
    var items: [UUID]   // Workspace ID

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.isCollapsed = false
        self.items = []
    }
}
