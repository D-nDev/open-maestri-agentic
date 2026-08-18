import Foundation

/// app-state.json persistent data (schemaVersion: 1, type: "appState")
struct AppStateData: Codable {
    var schemaVersion: Int
    var type: String
    var activeWorkspaceId: UUID?
    var hasCompletedOnboarding: Bool
    var hasSeenFloorOnboarding: Bool
    var cleanShutdown: Bool
    var lastOpenedAt: Date?
    var recentWorkspaceIds: [UUID]

    init() {
        self.schemaVersion = 1
        self.type = "appState"
        self.activeWorkspaceId = nil
        self.hasCompletedOnboarding = false
        self.hasSeenFloorOnboarding = false
        self.cleanShutdown = true
        self.lastOpenedAt = nil
        self.recentWorkspaceIds = []
    }
}

/// manifest.json top-level format (type value is "appState", following Maestri's original design)
struct WorkspaceManifest: Codable {
    var schemaVersion: Int
    var type: String
    var app: String
    var appVersion: String
    var dataFormat: Int
    var workspaces: [WorkspaceEntry]
    var files: [String: String]     // Reserve extension fields

    init() {
        self.schemaVersion = 1
        self.type = "appState"
        self.app = "open-maestri"
        self.appVersion = "1.0.0"
        self.dataFormat = 2
        self.workspaces = []
        self.files = [:]
    }
}

/// Workspace color options
enum WorkspaceColor: String, Codable, CaseIterable {
    case blue, red, green, orange, purple, pink, cyan, yellow, rainbow
}

/// Workspace List Entry
struct WorkspaceEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var workingDirectory: String
    var icon: String
    var color: String               // Workspace color identification, such as "blue", "red", "green", etc.
    var isPinned: Bool
    var locationType: String        // "local" | "ssh"
    var createdAt: Date
    var lastOpenedAt: Date?

    init(id: UUID = UUID(), name: String, workingDirectory: String, icon: String = "folder", color: String = "blue") {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.icon = icon
        self.color = color
        self.isPinned = false
        self.locationType = "local"
        self.createdAt = Date()
        self.lastOpenedAt = nil
    }

    // Backwards Compatibility: Old JSON may not have a color field
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        icon = try container.decode(String.self, forKey: .icon)
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "blue"
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        locationType = try container.decode(String.self, forKey: .locationType)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }
}
