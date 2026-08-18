import Foundation
import CoreSpotlight
import OSLog

/// Spotlight Indexer - Supports system-level search in workspace, Note, Terminal
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    private let index = CSSearchableIndex.default()
    private let logger = Logger.make(category: "SpotlightIndexer")
    private init() {}

    // MARK: - workspace index

    func indexWorkspace(id: UUID, name: String, workingDirectory: String) {
        let attr = CSSearchableItemAttributeSet(contentType: .content)
        attr.title = name
        attr.contentDescription = workingDirectory
        attr.keywords = ["workspace", "maestri", name]
        let item = CSSearchableItem(
            uniqueIdentifier: "workspace-\(id.uuidString)",
            domainIdentifier: "com.open-maestri.workspace",
            attributeSet: attr
        )
        index.indexSearchableItems([item]) { [weak self] error in
            if let error { self?.logger.error("Workspace index error: \(error)") }
        }
    }

    func deindexWorkspace(id: UUID) {
        index.deleteSearchableItems(
            withIdentifiers: ["workspace-\(id.uuidString)"]
        ) { _ in }
    }

    // MARK: - Note index

    func indexNote(workspaceId: UUID, noteId: UUID, name: String, content: String) {
        let attr = CSSearchableItemAttributeSet(contentType: .text)
        attr.title = name
        attr.textContent = content
        attr.contentDescription = String(content.prefix(200))
        attr.keywords = ["note", "markdown", name]
        let item = CSSearchableItem(
            uniqueIdentifier: "note-\(workspaceId.uuidString)-\(noteId.uuidString)",
            domainIdentifier: "com.open-maestri.note",
            attributeSet: attr
        )
        index.indexSearchableItems([item]) { [weak self] error in
            if let error { self?.logger.error("Note index error: \(error)") }
        }
    }

    func deindexNote(workspaceId: UUID, noteId: UUID) {
        index.deleteSearchableItems(
            withIdentifiers: ["note-\(workspaceId.uuidString)-\(noteId.uuidString)"]
        ) { _ in }
    }

    // MARK: - Terminal index

    func indexTerminal(workspaceId: UUID, terminalId: UUID, name: String, agentType: String) {
        let attr = CSSearchableItemAttributeSet(contentType: .content)
        attr.title = name
        attr.contentDescription = agentType
        attr.keywords = ["terminal", "agent", agentType, name]
        let item = CSSearchableItem(
            uniqueIdentifier: "terminal-\(workspaceId.uuidString)-\(terminalId.uuidString)",
            domainIdentifier: "com.open-maestri.terminal",
            attributeSet: attr
        )
        index.indexSearchableItems([item]) { [weak self] error in
            if let error { self?.logger.error("Terminal index error: \(error)") }
        }
    }

    func deindexTerminal(workspaceId: UUID, terminalId: UUID) {
        index.deleteSearchableItems(
            withIdentifiers: ["terminal-\(workspaceId.uuidString)-\(terminalId.uuidString)"]
        ) { _ in }
    }

    // MARK: - Batch operation

    /// Index the entire workspace (all nodes)
    func indexWorkspaceNodes(workspaceId: UUID, nodes: [CanvasNode], workingDirectory: String) {
        var items: [CSSearchableItem] = []
        for node in nodes {
            switch node.content {
            case .terminal(let tc):
                let attr = CSSearchableItemAttributeSet(contentType: .content)
                attr.title = tc.name
                attr.contentDescription = "\(tc.agentType) • \(workingDirectory)"
                attr.keywords = ["terminal", tc.agentType, tc.name]
                items.append(CSSearchableItem(
                    uniqueIdentifier: "terminal-\(workspaceId.uuidString)-\(node.id.uuidString)",
                    domainIdentifier: "com.open-maestri.terminal",
                    attributeSet: attr
                ))
            case .stickyNote(let nc):
                let attr = CSSearchableItemAttributeSet(contentType: .text)
                attr.title = nc.fileName ?? "Note"
                attr.keywords = ["note", nc.fileName ?? ""]
                items.append(CSSearchableItem(
                    uniqueIdentifier: "note-\(workspaceId.uuidString)-\(node.id.uuidString)",
                    domainIdentifier: "com.open-maestri.note",
                    attributeSet: attr
                ))
            default:
                break
            }
        }
        if !items.isEmpty {
            index.indexSearchableItems(items) { [weak self] error in
                if let error { self?.logger.error("Batch index error: \(error)") }
            }
        }
    }

    /// Delete all index items in the workspace
    func deindexAll(workspaceId: UUID) {
        index.deleteSearchableItems(
            withDomainIdentifiers: [
                "com.open-maestri.workspace",
                "com.open-maestri.note",
                "com.open-maestri.terminal",
            ]
        ) { _ in }
    }

    /// Full rebuild (called during first startup or recovery)
    func rebuildIndex(workspaces: [WorkspaceEntry], nodes: [UUID: [CanvasNode]]) {
        index.deleteAllSearchableItems { [weak self] _ in
            guard let self else { return }
            for entry in workspaces {
                self.indexWorkspace(id: entry.id, name: entry.name, workingDirectory: entry.workingDirectory)
                if let wsNodes = nodes[entry.id] {
                    self.indexWorkspaceNodes(workspaceId: entry.id, nodes: wsNodes, workingDirectory: entry.workingDirectory)
                }
            }
        }
    }
}
