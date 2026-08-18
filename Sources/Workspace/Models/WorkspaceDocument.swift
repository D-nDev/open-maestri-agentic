import Foundation

/// workspace.json top-level container
/// Fully compatible with Maestri v0.25.4 format (schemaVersion: 2)
struct WorkspaceDocument: Codable {
    let payload: WorkspacePayload
    let schemaVersion: Int
    let type: String

    init(payload: WorkspacePayload) {
        self.payload = payload
        self.schemaVersion = Constants.schemaVersion
        self.type = "workspace"
    }
}
