import SwiftUI

/// Assign Role Sheet (triggered from the right-click menu "Assign Role")
/// Display list of available roles, support assignment and unassignment
struct AssignRoleSheet: View {
    let roles: [RolePreset]
    let currentRoleId: UUID?
    let onAssign: (RolePreset) -> Void
    let onUnassign: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("menu.assign_role").font(.headline)
                Spacer()
                Button("button.cancel") {
                    dismiss()
                    onDismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            if roles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("role.no_custom_roles")
                        .foregroundStyle(.secondary)
                    Text("role.assign.no_roles_hint")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // Unassign option (shown only if role already exists)
                        if currentRoleId != nil {
                            Button {
                                onUnassign()
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, height: 24)

                                    Text("terminal.unassign_role")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)

                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        }

                        // Role list
                        ForEach(roles) { role in
                            let isCurrentRole = role.id == currentRoleId
                            Button {
                                if !isCurrentRole {
                                    onAssign(role)
                                }
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: role.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color(hex: role.color) ?? .primary)
                                        .frame(width: 24, height: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(role.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                        if !role.prompt.isEmpty {
                                            Text(role.prompt)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    // Tags are currently assigned
                                    if isCurrentRole {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isCurrentRole ? Color.accentColor.opacity(0.08) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
            }
        }
        .frame(width: 340, height: 360)
    }
}
