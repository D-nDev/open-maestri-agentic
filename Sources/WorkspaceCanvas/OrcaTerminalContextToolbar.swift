import SwiftUI

struct OrcaTerminalContextToolbar: View {
    let onConnect: () -> Void
    let onRefresh: () -> Void
    let onSendQueued: () -> Void
    let onInterrupt: () -> Void
    let onDelete: () -> Void
    var connections: [ToolbarConnectionItem] = []
    var onDeleteConnection: (UUID) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 2) {
            ContextToolbarButton(
                icon: "arrow.trianglehead.branch",
                tooltip: "Connect",
                action: onConnect
            )
            if !connections.isEmpty {
                ConnectionBadgeButton(connections: connections, onDelete: onDeleteConnection)
            }
            ContextToolbarButton(icon: "arrow.clockwise", tooltip: "Refresh from Orca", action: onRefresh)
            ContextToolbarButton(icon: "paperplane", tooltip: "Queue message", action: onSendQueued)
            ContextToolbarButton(icon: "exclamationmark.octagon", tooltip: "Interrupt and send", action: onInterrupt)
            ContextToolbarButton(icon: "trash", tooltip: "Delete mirror", action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(white: 0.9), lineWidth: 0.5)
        )
    }
}
struct OrcaSendTarget: Identifiable {
    let id: UUID
    let mode: OrcaDeliveryMode
}

struct OrcaSendSheet: View {
    let target: OrcaSendTarget
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target.mode == .queue ? "Queue message to Orca" : "Interrupt Orca terminal")
                .font(.headline)
            if target.mode == .interrupt {
                Label(
                    "This explicitly interrupts the current model turn.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            } else {
                Text("The message will be delivered after Orca reports tui-idle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $message)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.mode == .queue ? "Queue" : "Interrupt and send") {
                    send()
                }
                .buttonStyle(.borderedProminent)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func send() {
        isSending = true
        errorMessage = nil
        Task {
            do {
                try await OrcaTerminalRegistry.shared.send(
                    nodeId: target.id,
                    text: message,
                    mode: target.mode
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSending = false
            }
        }
    }
}
