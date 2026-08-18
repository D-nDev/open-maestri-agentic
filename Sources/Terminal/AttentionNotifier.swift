import Foundation
import OSLog

/// Terminal attention notification manager
/// When the unselected terminal has important output (Agent completes tasks, etc.), mark a red attention point
/// Alignment with Maestri's AttentionNotifier
///
/// Trigger conditions (must all be met):
/// 1. Terminal shell is ready (exists in completedProviders)
/// 2. The terminal changes from "Running" to "Idle" (indicating that a section of output is completed)
/// 3. The terminal is not the selected node of the current canvas
@MainActor
final class AttentionNotifier {
    static let shared = AttentionNotifier()
    private let logger = Logger.make(category: "AttentionNotifier")

    /// Collection of terminals requiring attention
    private(set) var attentionTerminals: Set<UUID> = []

    /// Collection of node IDs selected in the current canvas (CanvasNode.id == TerminalContent.id)
    private var selectedNodeIds: Set<UUID> = []

    /// Attention state change callback (terminalId, needsAttention)
    var onAttentionChanged: ((UUID, Bool) -> Void)?

    private init() {
        // Listen for terminal idle notification (Agent output is completed and changes from running state to idle state)
        NotificationCenter.default.addObserver(
            forName: .terminalBecameIdle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let terminalId = notification.userInfo?["terminalId"] as? UUID else { return }
            Task { @MainActor in
                self.markNeedsAttention(terminalId: terminalId)
            }
        }

        // Listen for canvas node activation notification and track the currently selected node
        NotificationCenter.default.addObserver(
            forName: .canvasNodeActivated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let nodeId = notification.userInfo?["nodeId"] as? UUID else { return }
            Task { @MainActor in
                self.selectedNodeIds = [nodeId]
                // Automatically clear the red dot of this node when selected
                self.clearAttention(terminalId: nodeId)
            }
        }
    }

    // MARK: - Mark requires attention

    /// Marking terminal requires attention (only triggered by terminalBecameIdle notification after IPC task completion)
    func markNeedsAttention(terminalId: UUID) {
        // The currently selected terminal is not marked
        if selectedNodeIds.contains(terminalId) { return }

        guard !attentionTerminals.contains(terminalId) else { return }
        attentionTerminals.insert(terminalId)
        onAttentionChanged?(terminalId, true)
        NotificationCenter.default.post(
            name: .terminalAttentionChanged,
            object: nil,
            userInfo: ["terminalId": terminalId, "needsAttention": true]
        )
        logger.debug("Terminal \(terminalId.uuidString.prefix(8)) needs attention")
    }

    // MARK: - Clear attention

    /// Clear terminal attention mark (called when user selects/focuses on the terminal)
    func clearAttention(terminalId: UUID) {
        guard attentionTerminals.contains(terminalId) else { return }
        attentionTerminals.remove(terminalId)
        onAttentionChanged?(terminalId, false)
        NotificationCenter.default.post(
            name: .terminalAttentionChanged,
            object: nil,
            userInfo: ["terminalId": terminalId, "needsAttention": false]
        )
        logger.debug("Terminal \(terminalId.uuidString.prefix(8)) attention cleared")
    }

    /// Clear all attention markers
    func clearAll() {
        let ids = attentionTerminals
        attentionTerminals.removeAll()
        for id in ids {
            onAttentionChanged?(id, false)
            NotificationCenter.default.post(
                name: .terminalAttentionChanged,
                object: nil,
                userInfo: ["terminalId": id, "needsAttention": false]
            )
        }
    }

    // MARK: - Query

    func needsAttention(terminalId: UUID) -> Bool {
        attentionTerminals.contains(terminalId)
    }
}
