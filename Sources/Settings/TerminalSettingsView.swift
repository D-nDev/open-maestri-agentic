import OSLog
import SwiftUI
import SwiftTerm

private let settingsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "open-maestri", category: "Settings")

struct TerminalSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddPreset = false
    @State private var presetToEdit: AgentPreset?

    private let fontFamilies = ["system", "Menlo", "Monaco", "Courier New", "JetBrains Mono", "Fira Code"]
    private let fontSizes: [CGFloat] = [11, 12, 13, 14, 15, 16, 18, 20]

    var body: some View {
        @Bindable var state = appState
        Form {
            // MARK: - Quick start preset
            Section {
                Text("settings.terminal.presets.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(appState.preferences.agentPresets) { preset in
                    TerminalPresetRow(
                        preset: preset,
                        onToggle: { togglePreset(preset) },
                        onEdit: { presetToEdit = preset },
                        onDelete: { deletePreset(preset) }
                    )
                }

                HStack {
                    Button("settings.terminal.presets.add") { showAddPreset = true }
                    Spacer()
                    Button("settings.terminal.presets.reset") { resetPresetsToDefaults() }
                }
            } header: {
                Text("settings.terminal.presets")
            }

            // MARK: - Topic
            Section("settings.terminal.theme") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("settings.terminal.theme")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    ThemePickerView(selectedThemeId: $state.preferences.terminalTheme)
                }
            }

            // MARK: - Font
            Section("settings.terminal.font") {
                Picker("settings.terminal.font", selection: $state.preferences.terminalFontFamily) {
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                }
                Picker("settings.terminal.font_size", selection: $state.preferences.terminalFontSize) {
                    ForEach(fontSizes, id: \.self) { Text("\(Int($0))pt").tag($0) }
                }
                // Font preview
                Text("abc 012 →|←")
                    .font(.custom(appState.preferences.terminalFontFamily, size: appState.preferences.terminalFontSize))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }

            // MARK: - Performance
            Section("settings.terminal.performance") {
                Toggle("settings.terminal.metal", isOn: $state.preferences.metalRendererEnabled)
                    .help("settings.terminal.metal.help".localized)
                Toggle("settings.terminal.memory_limit", isOn: $state.preferences.scrollbackMemoryLimit)
                    .help("settings.terminal.memory_limit.help".localized)
            }

            // MARK: - Keyboard
            Section("settings.terminal.keyboard") {
                Toggle("settings.terminal.option_as_meta", isOn: $state.preferences.optionAsMeta)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440)
        .onChange(of: appState.preferences.terminalTheme) { _, newTheme in
            applyThemeToAll(newTheme)
            save()
        }
        .onChange(of: appState.preferences.terminalFontFamily) { _, newFamily in
            applyFontToAll(family: newFamily, size: appState.preferences.terminalFontSize)
            save()
        }
        .onChange(of: appState.preferences.terminalFontSize) { _, newSize in
            applyFontToAll(family: appState.preferences.terminalFontFamily, size: newSize)
            save()
        }
        .onChange(of: appState.preferences.metalRendererEnabled) { _, _ in save() }
        .onChange(of: appState.preferences.scrollbackMemoryLimit) { _, _ in save() }
        .onChange(of: appState.preferences.optionAsMeta) { _, _ in save() }
        .sheet(isPresented: $showAddPreset) {
            AddAgentPresetSheet { newPreset in
                appState.preferences.agentPresets.append(newPreset)
                save()
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(item: $presetToEdit) { preset in
            EditAgentPresetSheet(preset: preset) { updated in
                if let idx = appState.preferences.agentPresets.firstIndex(where: { $0.id == updated.id }) {
                    appState.preferences.agentPresets[idx] = updated
                }
                save()
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
    }

    // MARK: - Actions

    private func togglePreset(_ preset: AgentPreset) {
        guard let idx = appState.preferences.agentPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        appState.preferences.agentPresets[idx].isActive.toggle()
        save()
    }

    private func deletePreset(_ preset: AgentPreset) {
        appState.preferences.agentPresets.removeAll { $0.id == preset.id }
        save()
    }

    private func resetPresetsToDefaults() {
        appState.preferences.agentPresets = AgentPreset.defaults
        save()
    }

    private func save() {
        try? PersistenceManager.shared.savePreferences(appState.preferences)
    }

    /// Instantly apply themes to all open terminals
    private func applyThemeToAll(_ preference: String) {
        let themeId = TerminalThemeRegistry.resolveThemeId(from: preference)
        Task { @MainActor in
            for provider in allProviders() {
                provider.applyTheme(themeId)
            }
        }
    }

    /// Instantly apply fonts to all open terminals (no reboot required)
    private func applyFontToAll(family: String, size: CGFloat) {
        Task { @MainActor in
            for provider in allProviders() {
                provider.applyFont(family: family, size: size)
            }
        }
    }

    private func allProviders() -> [SwiftTermProvider] {
        Array(TerminalManager.shared.providers.values)
    }
}

// MARK: - Terminal default line (new version, matching UI reference picture)

struct TerminalPresetRow: View {
    let preset: AgentPreset
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Enable/disable tick circle
            Button(action: onToggle) {
                Image(systemName: preset.isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(preset.isActive ? Color.green : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            // Agent icon
            Image(systemName: preset.icon)
                .font(.system(size: 14))
                .frame(width: 20)
                .foregroundStyle(Color(hex: preset.color) ?? .accentColor)

            // name + command
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.body)
                Text(preset.command.isEmpty ? "shell" : preset.command)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // Delete button (only custom presets can be deleted)
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(preset.isBuiltIn ? .clear : .secondary)
            .disabled(preset.isBuiltIn)
        }
        .opacity(preset.isActive ? 1.0 : 0.6)
    }
}

// MARK: - Edit Preset Sheet

struct EditAgentPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let preset: AgentPreset
    let onSave: (AgentPreset) -> Void

    @State private var name: String
    @State private var command: String
    @State private var agentType: String

    init(preset: AgentPreset, onSave: @escaping (AgentPreset) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _name = State(initialValue: preset.name)
        _command = State(initialValue: preset.command)
        _agentType = State(initialValue: preset.agentType)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("settings.terminal.presets.edit").font(.headline)
                Spacer()
                Button("button.cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("button.save") { save() }
                    .disabled(name.isEmpty)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }.padding()
            Divider()
            Form {
                TextField("agent.name", text: $name)
                TextField("terminal.command", text: $command)
                    .help("agent.command.help".localized)
                    .disabled(preset.isBuiltIn)
                Picker("agent.type", selection: $agentType) {
                    Text("Claude Code").tag("claude_code")
                    Text("Codex").tag("codex")
                    Text("Gemini CLI").tag("gemini_cli")
                    Text("OpenCode").tag("open_code")
                    Text("Shell").tag("generic_shell")
                }
                .disabled(preset.isBuiltIn)
            }
            .formStyle(.grouped).padding()
        }
        .frame(width: 380, height: 280)
    }

    private func save() {
        var updated = preset
        updated.name = name
        updated.command = command
        updated.agentType = agentType
        onSave(updated)
        dismiss()
    }
}
