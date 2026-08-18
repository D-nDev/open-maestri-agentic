import SwiftUI

struct NoteNodeSwiftUIView: View {
    let nodeId: UUID
    let content: StickyNoteContent
    let isSelected: Bool
    let isLocked: Bool
    let zoom: CGFloat
    let workspace: WorkspaceManager?
    var onActivated: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onDuplicate: ((UUID) -> Void)?
    var onLockToggle: ((UUID, Bool) -> Void)?

    @State private var orcaRegistry = OrcaTerminalRegistry.shared

    private var deliveryState: OrcaNoteDeliveryState? {
        orcaRegistry.noteDeliveryState(for: nodeId)
    }

    var body: some View {
        NodeShellView(
            nodeId: nodeId,
            title: content.fileName ?? "Note",
            isSelected: isSelected,
            isLocked: isLocked,
            zoom: zoom,
            headerIcon: "note.text",
            headerColor: noteColor(content.color),
            themeColor: noteColor(content.color),
            headerTitleAccessory: { deliveryBadge },
            onClose: { onClose?(nodeId) },
            onRename: { onRename?(nodeId, $0) },
            onDuplicate: { onDuplicate?(nodeId) },
            onLockToggle: { onLockToggle?(nodeId, $0) }
        ) {
            if let workspace {
                NoteEditorRepresentable(nodeId: nodeId, content: content, workspace: workspace)
            } else {
                Color.clear
            }
        }
    }

    private func noteColor(_ str: String) -> Color {
        NoteColorPickerPopover.colorFromString(str)
    }

    @ViewBuilder
    private var deliveryBadge: some View {
        if let deliveryState {
            HStack(spacing: 3) {
                Image(systemName: deliveryIcon(for: deliveryState.phase))
                    .font(.system(size: 8, weight: .semibold))
                Text(deliveryKey(for: deliveryState.phase).localized)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(deliveryColor(for: deliveryState.phase))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(deliveryColor(for: deliveryState.phase).opacity(0.13))
            )
            .help(deliveryHelp(deliveryState))
        }
    }

    private func deliveryKey(for phase: OrcaNoteDeliveryPhase) -> String {
        switch phase {
        case .waiting: return "note.delivery.waiting"
        case .sent: return "note.delivery.sent"
        case .failed: return "note.delivery.failed"
        }
    }

    private func deliveryIcon(for phase: OrcaNoteDeliveryPhase) -> String {
        switch phase {
        case .waiting: return "clock.arrow.circlepath"
        case .sent: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func deliveryColor(for phase: OrcaNoteDeliveryPhase) -> Color {
        switch phase {
        case .waiting: return .orange
        case .sent: return .green
        case .failed: return .red
        }
    }

    private func deliveryHelp(_ state: OrcaNoteDeliveryState) -> String {
        if let errorMessage = state.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return deliveryKey(for: state.phase).localized
    }
}

/// NSViewControllerRepresentable wraps an existing NoteNodeViewController
struct NoteEditorRepresentable: NSViewControllerRepresentable {
    let nodeId: UUID
    let content: StickyNoteContent
    let workspace: WorkspaceManager

    func makeNSViewController(context: Context) -> NoteNodeViewController {
        let filePath = resolvedFilePath()
        return NoteNodeViewController(noteId: nodeId, filePath: filePath)
    }

    func updateNSViewController(_ nsViewController: NoteNodeViewController, context: Context) {}

    private func resolvedFilePath() -> String {
        switch content.storageMode {
        case .managed:
            let notesDir = PersistenceManager.shared.notesDirURL(workspaceId: workspace.id)
            return notesDir.appendingPathComponent(content.fileName ?? "\(nodeId).md").path
        case .custom(path: let customPath):
            return customPath
        }
    }
}
