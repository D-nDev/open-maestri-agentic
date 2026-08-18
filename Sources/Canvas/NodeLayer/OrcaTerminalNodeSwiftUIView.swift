import SwiftUI

struct OrcaTerminalNodeSwiftUIView: View {
    let nodeId: UUID
    let fallbackContent: TerminalContent
    let isSelected: Bool
    let isLocked: Bool
    let zoom: CGFloat
    var onLockToggle: ((UUID, Bool) -> Void)?

    @State private var registry = OrcaTerminalRegistry.shared

    private var state: OrcaTerminalRuntimeState? { registry.state(for: nodeId) }

    var body: some View {
        NodeShellView(
            nodeId: nodeId,
            title: localizedTitle,
            isSelected: isSelected,
            isLocked: isLocked,
            isCommunicating: isActive,
            zoom: zoom,
            headerIcon: state?.environment == nil ? "network" : "cloud",
            headerColor: state?.environment == nil ? .blue : .purple,
            headerTitleAccessory: { statusBadge },
            headerAccessory: { environmentBadge },
            footer: { footer },
            onLockToggle: { onLockToggle?(nodeId, $0) }
        ) {
            outputView
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 4) {
            OrcaActivityIndicator(color: statusColor, isActive: isActive)
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
        Text(localizedEnvironment)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    private var outputView: some View {
        OrcaTerminalOutputView(nodeId: nodeId, text: outputText, isActive: isActive)
        .overlay(alignment: .topTrailing) {
            if let role = state?.role, !role.isEmpty {
                Text(localizedRole(role))
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
        return output.isEmpty ? "orca.output.waiting".localized : output
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

    private var isActive: Bool {
        switch state?.status.lowercased() {
        case "running", "active", "working", "reconnecting", "waiting": return true
        default: return false
        }
    }

    private var localizedTitle: String {
        let title = state?.title ?? fallbackContent.name
        return title.lowercased() == "coordinator" ? "orca.role.coordinator".localized : title
    }

    private var localizedEnvironment: String {
        guard let environment = state?.environment, !environment.isEmpty else {
            return "orca.environment.local".localized
        }
        return environment
    }

    private func localizedRole(_ role: String) -> String {
        role.lowercased() == "coordinator" ? "orca.role.coordinator".localized : role
    }
}

private struct OrcaActivityIndicator: View {
    let color: Color
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isActive)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let wave = isActive ? (sin(elapsed * .pi * 2 / 1.25) + 1) / 2 : 0
            ZStack {
                Circle()
                    .stroke(color.opacity(0.45 * wave), lineWidth: 1.5)
                    .frame(width: 6, height: 6)
                    .scaleEffect(1 + wave * 1.15)
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 10, height: 10)
    }
}
