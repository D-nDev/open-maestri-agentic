import AppKit
import SwiftUI

// MARK: - File Drop Handling

extension WorkspaceCanvasView {

    /// Process .md/.markdown/.txt files dragged from Finder and create Note nodes (storageMode = .custom)
    func handleFilesDropped(paths: [String], at canvasOriginPoint: CGPoint) {
        var offsetY: CGFloat = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent
            var nc = StickyNoteContent(name: name)
            nc.fileName = url.lastPathComponent
            nc.storageMode = .custom(path: path)
            let frame = CGRect(
                x: canvasOriginPoint.x,
                y: canvasOriginPoint.y - offsetY,
                width: 320,
                height: 240
            )
            let node = CanvasNode(frame: frame, content: .stickyNote(nc))
            NoteRegistry.shared.register(name: name, filePath: path, nodeId: node.id)
            workspace.addNode(node)
            offsetY += 260
        }
        Task { try? await workspace.save() }
    }

    /// Processing when files are dragged into nodes
    func handleFilesDroppedOnNode(paths: [String], nodeId: UUID) {
        guard let node = workspace.nodes.first(where: { $0.id == nodeId }) else { return }
        switch node.content {
        case .terminal(let tc):
            if let provider = TerminalManager.shared.providers[tc.id] {
                let escaped = paths.map { shellEscape($0) }
                provider.write(escaped.joined(separator: " "))
            }
        default:
            break
        }
    }

    /// Shell path escaping: Single quotes for paths containing spaces or special characters
    func shellEscape(_ path: String) -> String {
        let special = CharacterSet(charactersIn: " '\"\\$`!#&|;(){}[]<>?*~")
        if path.unicodeScalars.contains(where: { special.contains($0) }) {
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return path
    }
}
