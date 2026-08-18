import OSLog
import SwiftUI

private let settingsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "open-maestri", category: "Settings")


struct AgentsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedSubTab: AgentsSubTab = .roles

    enum AgentsSubTab: String, CaseIterable {
        case roles
        case skills
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sub-Tab switching (Segmented Picker)
            Picker("", selection: $selectedSubTab) {
                Text("agents.subtab.roles").tag(AgentsSubTab.roles)
                Text("agents.subtab.skills").tag(AgentsSubTab.skills)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Content area
            switch selectedSubTab {
            case .roles:
                AgentsRolesSubView()
                    .environment(appState)
            case .skills:
                AgentsSkillsSubView()
                    .environment(appState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Character subview

struct AgentsRolesSubView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var showAddRole = false
    @State private var roleToEdit: RolePreset?

    private var filteredRoles: [RolePreset] {
        if searchText.isEmpty {
            return appState.preferences.rolePresets
        }
        return appState.preferences.rolePresets.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.prompt.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title + Description
            VStack(alignment: .leading, spacing: 4) {
                Text("agents.roles.title")
                    .font(.system(size: 13, weight: .medium))
                Text("agents.roles.description")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            // Search box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("agents.roles.search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .padding(.horizontal, 20)

            // Role list
            ScrollView {
                VStack(spacing: 0) {
                    if filteredRoles.isEmpty {
                        VStack(spacing: 8) {
                            Text("role.no_roles")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(Array(filteredRoles.enumerated()), id: \.element.id) { index, role in
                            AgentsRoleRow(role: role) {
                                roleToEdit = role
                            } onDelete: {
                                deleteRole(role)
                            }
                            if index < filteredRoles.count - 1 {
                                Divider()
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .padding(.horizontal, 20)

            // Add role button
            Button {
                showAddRole = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text("agents.roles.add")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showAddRole) {
            RoleEditSheet(role: nil) { newRole in
                appState.preferences.rolePresets.append(newRole)
                save()
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(item: $roleToEdit) { role in
            RoleEditSheet(role: role) { updated in
                if let idx = appState.preferences.rolePresets.firstIndex(where: { $0.id == updated.id }) {
                    appState.preferences.rolePresets[idx] = updated
                    RoleInjector.shared.prepareRoleDirectory(
                        roleId: updated.id,
                        rolePrompt: updated.prompt,
                        workingDirectory: ""
                    )
                }
                save()
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
    }

    private func deleteRole(_ role: RolePreset) {
        appState.preferences.rolePresets.removeAll { $0.id == role.id }
        RoleInjector.shared.removeRoleDirectory(roleId: role.id)
        save()
    }

    private func save() {
        do {
                try PersistenceManager.shared.savePreferences(appState.preferences)
            } catch {
                settingsLogger.error("Failed to save preferences: \(error.localizedDescription)")
            }
    }
}

// MARK: - Character Row (Match Reference UI)

struct AgentsRoleRow: View {
    let role: RolePreset
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Character Color Icon Badge
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: role.color) ?? .blue)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: role.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                )

            // Name + Description
            VStack(alignment: .leading, spacing: 2) {
                Text(role.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(role.prompt.prefix(50) + (role.prompt.count > 50 ? "…" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Skill subview

struct AgentsSkillsSubView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddPath = false
    @State private var pathToEdit: SkillPath?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title + Description
            VStack(alignment: .leading, spacing: 4) {
                Text("agents.skills.title")
                    .font(.system(size: 13, weight: .medium))
                Text("agents.skills.description")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            // Skill path list
            ScrollView {
                VStack(spacing: 0) {
                    if appState.preferences.skillPaths.isEmpty {
                        VStack(spacing: 8) {
                            Text("agents.skills.empty")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(Array(appState.preferences.skillPaths.enumerated()), id: \.element.id) { index, skillPath in
                            SkillPathRow(
                                skillPath: skillPath,
                                onToggle: { toggleSkillPath(skillPath) },
                                onEdit: { pathToEdit = skillPath },
                                onDelete: { deleteSkillPath(skillPath) }
                            )
                            if index < appState.preferences.skillPaths.count - 1 {
                                Divider()
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .padding(.horizontal, 20)

            // Bottom button row
            HStack {
                Button {
                    showAddPath = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11))
                        Text("agents.skills.add_path")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("agents.skills.reset") {
                    resetToDefaults()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)

            // Bottom tip
            Text("agents.skills.footer")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showAddPath) {
            SkillPathEditSheet(skillPath: nil) { newPath in
                appState.preferences.skillPaths.append(newPath)
                save()
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(item: $pathToEdit) { skillPath in
            SkillPathEditSheet(skillPath: skillPath) { updated in
                if let idx = appState.preferences.skillPaths.firstIndex(where: { $0.id == updated.id }) {
                    appState.preferences.skillPaths[idx] = updated
                }
                save()
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
    }

    private func toggleSkillPath(_ skillPath: SkillPath) {
        guard let idx = appState.preferences.skillPaths.firstIndex(where: { $0.id == skillPath.id }) else { return }
        appState.preferences.skillPaths[idx].isActive.toggle()
        save()
    }

    private func deleteSkillPath(_ skillPath: SkillPath) {
        appState.preferences.skillPaths.removeAll { $0.id == skillPath.id }
        save()
    }

    private func resetToDefaults() {
        appState.preferences.skillPaths = SkillPath.defaults
        save()
    }

    private func save() {
        try? PersistenceManager.shared.savePreferences(appState.preferences)
    }
}

// MARK: - Skill Path Line

struct SkillPathRow: View {
    let skillPath: SkillPath
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Enable/disable circular tick
            Button(action: onToggle) {
                Image(systemName: skillPath.isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(skillPath.isActive ? Color.blue : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            // icon
            Image(systemName: skillPath.icon)
                .font(.system(size: 14))
                .frame(width: 20)
                .foregroundStyle(.primary)

            // name + path
            VStack(alignment: .leading, spacing: 2) {
                Text(skillPath.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(skillPath.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(skillPath.isBuiltIn ? .clear : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(skillPath.isBuiltIn)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(skillPath.isActive ? 1.0 : 0.6)
        .contentShape(Rectangle())
    }
}

// MARK: - Skill path editing Sheet

struct SkillPathEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skillPath: SkillPath?
    let onSave: (SkillPath) -> Void

    @State private var name: String
    @State private var path: String
    @State private var icon: String

    private let iconOptions = [
        "gearshape", "doc.text", "paperplane", "sparkle",
        "terminal", "folder", "tray.full", "wrench",
        "hammer", "bolt", "brain", "cpu"
    ]

    init(skillPath: SkillPath?, onSave: @escaping (SkillPath) -> Void) {
        self.skillPath = skillPath
        self.onSave = onSave
        _name = State(initialValue: skillPath?.name ?? "")
        _path = State(initialValue: skillPath?.path ?? "~/")
        _icon = State(initialValue: skillPath?.icon ?? "folder")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(skillPath == nil ? "agents.skills.new_path" : "agents.skills.edit_path")
                    .font(.headline)
                Spacer()
                Button("button.cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("button.save") { save() }
                    .disabled(name.isEmpty || path.isEmpty)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }.padding()
            Divider()

            Form {
                TextField("agents.skills.path_name", text: $name)
                TextField("agents.skills.path_location", text: $path)
                    .font(.system(.body, design: .monospaced))

                Section("agent.icon") {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 6), spacing: 6) {
                        ForEach(iconOptions, id: \.self) { i in
                            Button { icon = i } label: {
                                Image(systemName: i)
                                    .font(.system(size: 13))
                                    .frame(width: 28, height: 28)
                                    .background(icon == i ? Color.accentColor.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 4)
        }
        .frame(width: 420, height: 340)
    }

    private func save() {
        let updated = SkillPath(
            id: skillPath?.id ?? UUID(),
            name: name,
            path: path,
            icon: icon,
            isActive: skillPath?.isActive ?? true,
            isBuiltIn: skillPath?.isBuiltIn ?? false
        )
        onSave(updated)
        dismiss()
    }
}

// MARK: - Create a new Agent default Sheet (for use by TerminalSettingsView)

struct AddAgentPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (AgentPreset) -> Void

    @State private var name = ""
    @State private var command = ""
    @State private var icon = "terminal"
    @State private var agentType = "generic_shell"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("agent.new_preset").font(.headline)
                Spacer()
                Button("button.cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("button.create") { create() }
                    .disabled(name.isEmpty || command.isEmpty)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }.padding()
            Divider()
            Form {
                TextField("agent.name", text: $name)
                TextField("terminal.command", text: $command)
                    .help("agent.command.help".localized)
                Picker("agent.type", selection: $agentType) {
                    Text("Claude Code").tag("claude_code")
                    Text("Codex").tag("codex")
                    Text("Gemini CLI").tag("gemini_cli")
                    Text("OpenCode").tag("open_code")
                    Text("Shell").tag("generic_shell")
                }
            }
            .formStyle(.grouped).padding()
        }
        .frame(width: 380, height: 280)
    }

    private func create() {
        let preset = AgentPreset(
            id: UUID(), name: name, command: command,
            icon: "terminal", agentType: agentType,
            color: "#007AFF", isActive: true, isBuiltIn: false
        )
        onSave(preset)
        dismiss()
    }
}

// MARK: - Character Editing Sheet

struct RoleEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let role: RolePreset?
    let onSave: (RolePreset) -> Void

    @State private var name: String
    @State private var prompt: String
    @State private var color: String
    @State private var icon: String
    @State private var selectedTab: Int = 0

    private let colorOptions = [
        "#007AFF", "#34C759", "#FF9500", "#FF3B30", "#AF52DE", "#5856D6",
        "#FF2D55", "#5AC8FA", "#FFCC00", "#4CD964", "#8E8E93", "#FF6482"
    ]
    private let iconOptions = [
        "person.fill", "wrench.fill", "magnifyingglass", "pencil",
        "doc.text.fill", "shield.fill", "hammer.fill", "lightbulb.fill",
        "brain", "eye.fill", "checkmark.seal.fill", "ant.fill",
        "terminal", "gear", "paintbrush.fill", "scissors",
        "flag.fill", "bolt.fill", "leaf.fill", "star.fill",
        "heart.fill", "hand.raised.fill", "scope", "chart.bar.fill"
    ]

    init(role: RolePreset?, onSave: @escaping (RolePreset) -> Void) {
        self.role = role
        self.onSave = onSave
        _name   = State(initialValue: role?.name ?? "")
        _prompt = State(initialValue: role?.prompt ?? "")
        _color  = State(initialValue: role?.color ?? "#007AFF")
        _icon   = State(initialValue: role?.icon ?? "person.fill")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(role == nil ? "role.new" : "role.edit").font(.headline)
                Spacer()
                Button("button.cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("button.save") { save() }
                    .disabled(name.isEmpty || prompt.isEmpty)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }.padding()
            Divider()

            // Tab switching
            Picker("", selection: $selectedTab) {
                Text("agent.tab.basic_info").tag(0)
                Text("agent.tab.instructions_preview").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Tab content
            if selectedTab == 0 {
                roleBasicInfoTab
            } else {
                roleInstructionPreviewTab
            }
        }
        .frame(width: 500, height: 560)
    }

    // MARK: - Basic information Tab

    @ViewBuilder
    private var roleBasicInfoTab: some View {
        Form {
            TextField("role.name", text: $name)
                .help("role.name_placeholder.help".localized)

            Section("agent.section.role_instructions") {
                TextEditor(text: $prompt)
                    .frame(height: 120)
                    .font(.system(.body, design: .monospaced))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            Section("agent.color") {
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 6), spacing: 8) {
                    ForEach(colorOptions, id: \.self) { c in
                        Button { color = c } label: {
                            Circle()
                                .fill(Color(hex: c) ?? .blue)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle().stroke(Color.white, lineWidth: color == c ? 2.5 : 0)
                                )
                                .shadow(color: color == c ? (Color(hex: c) ?? .blue).opacity(0.4) : .clear, radius: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("agent.icon") {
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 8), spacing: 6) {
                    ForEach(iconOptions, id: \.self) { i in
                        Button { icon = i } label: {
                            Image(systemName: i)
                                .font(.system(size: 13))
                                .frame(width: 28, height: 28)
                                .background(icon == i ? Color.accentColor.opacity(0.2) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }

    // MARK: - Command preview Tab (CLAUDE.md / AGENTS.md preview)

    @ViewBuilder
    private var roleInstructionPreviewTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Preview description
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("agent.role.inject_hint")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // File preview
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                    Text(verbatim: "CLAUDE.md / AGENTS.md")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

                ScrollView {
                    Text(generatedFileContent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .padding(.horizontal, 16)
            }

            // Storage path prompt
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(roleDirectoryPath)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Generated file content preview
    private var generatedFileContent: String {
        let rolePrompt = prompt.isEmpty ? "agent.role_prompt.placeholder".localized : prompt
        return """
        <your_assigned_role>
        \(rolePrompt)
        </your_assigned_role>

        <working_directory>
        IMPORTANT: You were started in this directory to receive the above role assignment. The actual project you should be working on is located at:
        {工作区目录}
        </working_directory>
        """
    }

    /// Role file storage path
    private var roleDirectoryPath: String {
        let id = role?.id ?? UUID()
        return "~/.open-maestri/roles/\(id.uuidString.prefix(8))…/"
    }

    private func save() {
        let updated = RolePreset(
            id: role?.id ?? UUID(),
            name: name, prompt: prompt,
            color: color, icon: icon
        )
        onSave(updated)
        dismiss()
    }
}
