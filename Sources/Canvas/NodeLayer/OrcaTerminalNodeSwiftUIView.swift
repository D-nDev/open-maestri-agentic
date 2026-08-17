import SwiftUI

struct OrcaTerminalNodeSwiftUIView: View {
    let nodeId: UUID
    let fallbackContent: TerminalContent
    let isSelected: Bool
    let isLocked: Bool
    let zoom: CGFloat
    var onClose: ((UUID) -> Void)?
    var onLockToggle: ((UUID, Bool) -> Void)?

    @State private var registry = OrcaTerminalRegistry.shared

    private var state: OrcaTerminalRuntimeState? { registry.state(for: nodeId) }

    var body: some View {
        NodeShellView(
            nodeId: nodeId,
            title: state?.title ?? fallbackContent.name,
            isSelected: isSelected,
            isLocked: isLocked,
            isCommunicating: false,
            zoom: zoom,
            headerIcon: state?.environment == nil ? "network" : "cloud",
            headerColor: state?.environment == nil ? .blue : .purple,
            headerTitleAccessory: { statusBadge },
            headerAccessory: { environmentBadge },
            footer: { footer },
            onClose: { onClose?(nodeId) },
            onLockToggle: { onLockToggle?(nodeId, $0) }
        ) {
            outputView
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(state?.status ?? "offline")
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(statusColor.opacity(0.12)))
    }

    @ViewBuilder
    private var environmentBadge: some View {
        Text(state?.environmentLabel ?? "local")
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    private var outputView: some View {
        ScrollView {
            Text(outputText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: .textColor))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .defaultScrollAnchor(.bottom)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.92))
        .overlay(alignment: .topTrailing) {
            if let role = state?.role, !role.isEmpty {
                Text(role)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 9))
            Text(footerText)
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let model = state?.model, !model.isEmpty {
                Text(model)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { VibrancyBackground(material: .sidebar, blendingMode: .behindWindow) }
    }

    private var outputText: String {
        if let error = state?.errorMessage, state?.output.isEmpty != false {
            return "[Orca] \(error)"
        }
        let output = state?.output.joined(separator: "\n") ?? ""
        return output.isEmpty ? "Waiting for Orca terminal output…" : output
    }

    private var footerText: String {
        state?.worktreePath ?? fallbackContent.workingDirectory
    }

    private var statusColor: Color {
        switch state?.status.lowercased() {
        case "running", "active", "working": return .green
        case "idle", "completed", "passed", "done": return .blue
        case "reconnecting", "waiting", "queued": return .orange
        case "failed", "error", "orphaned": return .red
        default: return .secondary
        }
    }
}
