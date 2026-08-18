import OSLog
import SwiftUI
import AppKit

/// Identifiable wrapper for Sheet rendering
struct EditTerminalItem: Identifiable {
    let id: UUID
    let content: TerminalContent
}

// MARK: - Edit terminal Sheet (three tabs: details, appearance, role)

struct EditTerminalSheet: View {
    let nodeId: UUID
    let content: TerminalContent
    let workspace: WorkspaceManager
    let onDismiss: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable {
        case details
        case appearance
        case role
    }

    @State private var selectedTab: Tab = .details

    // Detailed information Tab
    @State private var name: String
    @State private var command: String
    @State private var monitorActivity: Bool
    @State private var isManager: Bool
    @State private var shortcutMode: ShortcutMode
    @State private var workingDirectory: String

    // Appearance Tab
    @State private var icon: String
    @State private var iconColor: String
    @State private var themeId: String
    @State private var fontFamily: String
    @State private var fontSize: CGFloat

    // Role Tab
    @State private var selectedRoleId: UUID?

    enum Field: Hashable { case name, command }
    @FocusState private var focusedField: Field?

    init(nodeId: UUID, content: TerminalContent, workspace: WorkspaceManager, onDismiss: @escaping () -> Void) {
        self.nodeId = nodeId
        self.content = content
        self.workspace = workspace
        self.onDismiss = onDismiss
        _name = State(initialValue: content.name)
        _command = State(initialValue: content.command)
        _monitorActivity = State(initialValue: content.monitorWithOmbro)
        _isManager = State(initialValue: content.isManager)
        _shortcutMode = State(initialValue: content.shortcutMode)
        _workingDirectory = State(initialValue: content.workingDirectory)
        _icon = State(initialValue: content.icon)
        _iconColor = State(initialValue: content.color)
        _themeId = State(initialValue: content.themeId ?? "system")
        _fontFamily = State(initialValue: content.fontFamily ?? "SF Mono")
        _fontSize = State(initialValue: content.fontSize ?? 13)
        _selectedRoleId = State(initialValue: content.assignedRoleId)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("terminal.edit.title")
                .font(.system(size: 16, weight: .bold))
                .padding(.top, 20)
                .padding(.bottom, 14)

            // Tab Selector — Capsule Style
            EditTerminalTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

            // Tab content
            Group {
                switch selectedTab {
                case .details:
                    detailsTabView
                case .appearance:
                    appearanceTabView
                case .role:
                    roleTabView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .padding(.horizontal, 20)

            // Bottom Button - Centered
            HStack(spacing: 12) {
                Button("button.cancel") { dismiss(); onDismiss() }
                    .keyboardShortcut(.escape)
                    .controlSize(.large)
                Button("button.save") { save(); dismiss(); onDismiss() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.vertical, 16)
        }
        .frame(width: 460, height: 520)
        .task { activateFirstTextField() }
    }

    // MARK: - Details Tab

    @ViewBuilder
    private var detailsTabView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Name (light gray background input box)
            TextField("terminal.name_placeholder", text: $name)
                .focused($focusedField, equals: .name)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            // Command
            HStack(spacing: 10) {
                Text("terminal.command")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                TextField("terminal.command_placeholder", text: $command)
                    .focused($focusedField, equals: .command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            // Monitoring activities
            Toggle(isOn: $monitorActivity) {
                HStack(spacing: 5) {
                    Text("terminal.monitor")
                        .font(.system(size: 12))
                    InfoTooltipView(text: "terminal.edit.monitor_help".localized)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            // Maestro
            Toggle(isOn: $isManager) {
                HStack(spacing: 5) {
                    Text("terminal.maestro_mode")
                        .font(.system(size: 12))
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                    InfoTooltipView(text: "terminal.edit.maestro_help".localized)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            // Shortcut keys
            HStack(spacing: 10) {
                Text("terminal.shortcut")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: $shortcutMode.kind) {
                    ForEach(ShortcutMode.Kind.allCases, id: \.self) { kind in
                        Text(ShortcutMode(kind: kind).displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            // Working directory
            VStack(alignment: .leading, spacing: 6) {
                Text("terminal.working_directory")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(abbreviatedWorkingDir)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("terminal.browse") {
                        browseWorkingDirectory()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Appearance Tab

    @ViewBuilder
    private var appearanceTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // icon
                VStack(alignment: .leading, spacing: 8) {
                    Text("terminal.edit.icon")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    IconPickerView(selectedIcon: $icon)
                }

                // Color
                VStack(alignment: .leading, spacing: 8) {
                    Text("terminal.edit.color")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    ColorPickerGridView(selectedColor: $iconColor)
                }

                // Topic
                VStack(alignment: .leading, spacing: 8) {
                    Text("terminal.edit.theme")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    ThemePickerView(selectedThemeId: $themeId)
                }

                // Font
                VStack(alignment: .leading, spacing: 8) {
                    Text("terminal.edit.font")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    FontPickerView(fontFamily: $fontFamily, fontSize: $fontSize)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Character Tab

    @ViewBuilder
    private var roleTabView: some View {
        ScrollView {
            RolePickerView(
                roles: appState.preferences.rolePresets,
                selectedRoleId: $selectedRoleId,
                onCreateRole: { newRole in
                    appState.preferences.rolePresets.append(newRole)
                    savePreferences()
                },
                onEditRole: { updated in
                    if let idx = appState.preferences.rolePresets.firstIndex(where: { $0.id == updated.id }) {
                        appState.preferences.rolePresets[idx] = updated
                        savePreferences()
                    }
                },
                onUnassign: {
                    selectedRoleId = nil
                },
                onDiscover: {
                    NotificationCenter.default.post(name: .openSettingsAgents, object: nil)
                }
            )
            .padding(.top, 8)
        }
    }

    private func savePreferences() {
        do {
            try PersistenceManager.shared.savePreferences(appState.preferences)
        } catch {
            Logger.make(category: "EditTerminalSheet").error("savePreferences failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private var abbreviatedWorkingDir: String {
        let home = NSHomeDirectory()
        if workingDirectory.hasPrefix(home) {
            return "~" + workingDirectory.dropFirst(home.count)
        }
        return workingDirectory.isEmpty ? "~" : workingDirectory
    }

    private func browseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory.isEmpty ? NSHomeDirectory() : workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func save() {
        guard let idx = workspace.nodes.firstIndex(where: { $0.id == nodeId }),
              case .terminal(var tc) = workspace.nodes[idx].content else { return }
        tc.name = name
        tc.command = command
        tc.monitorWithOmbro = monitorActivity
        tc.isManager = isManager
        tc.shortcutMode = shortcutMode
        tc.workingDirectory = workingDirectory
        tc.icon = icon
        tc.color = iconColor
        tc.themeId = themeId
        tc.fontFamily = fontFamily
        tc.fontSize = fontSize
        tc.assignedRoleId = selectedRoleId
        let newContent = NodeContent.terminal(tc)
        workspace.nodes[idx].content = newContent
        NotificationCenter.default.post(
            name: .canvasNodeContentChanged,
            object: nil,
            userInfo: ["nodeId": nodeId, "content": newContent]
        )
        Task { try? await workspace.save() }
    }
}

// MARK: - Custom Tab bar (capsule style, matches Maestri UI)

struct EditTerminalTabBar: View {
    @Binding var selectedTab: EditTerminalSheet.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(EditTerminalSheet.Tab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tabTitle(tab))
                        .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .white : .primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule()
                                .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule()
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func tabTitle(_ tab: EditTerminalSheet.Tab) -> String {
        switch tab {
        case .details: return "terminal.edit.tab.details".localized
        case .appearance: return "terminal.edit.tab.appearance".localized
        case .role: return "terminal.edit.tab.role".localized
        }
    }
}

// MARK: - Info Tooltip View

struct InfoTooltipView: View {
    let text: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .help(text)
    }
}

// MARK: - Icon Picker View

struct IconPickerView: View {
    @Binding var selectedIcon: String

    private let icons: [String] = [
        "face.smiling", "terminal", "star", "hare",
        "sparkle", "bubble.left.and.bubble.right", "gearshape", "rectangle",
        "server.rack", "globe", "hammer", "wrench",
        "bolt", "tray.full", "desktopcomputer", "rectangle.inset.filled",
        "display", "paintbrush", "folder", "doc",
        "shield", "cube", "eye", "wand.and.stars"
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 9), spacing: 4) {
            ForEach(icons, id: \.self) { iconName in
                Button {
                    selectedIcon = iconName
                } label: {
                    Image(systemName: iconName)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedIcon == iconName ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selectedIcon == iconName ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: selectedIcon == iconName ? 1.5 : 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Color Picker Grid View

struct ColorPickerGridView: View {
    @Binding var selectedColor: String

    private let colors: [(String, Color)] = [
        ("#007AFF", .blue),
        ("#FF3B30", .red),
        ("#34C759", .green),
        ("#FF9500", .orange),
        ("#AF52DE", .purple),
        ("#FF2D55", .pink),
        ("#5AC8FA", .cyan),
        ("#FFCC00", .yellow),
        ("#8E8E93", .gray),
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(colors, id: \.0) { hex, color in
                Button {
                    selectedColor = hex
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(selectedColor == hex ? 0.9 : 0), lineWidth: 2.5)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Theme Picker View

struct ThemePickerView: View {
    @Binding var selectedThemeId: String
    @State private var showCustomThemePicker = false

    private let themes: [(id: String, name: String, bg: Color, fg: Color)] = [
        ("system", "terminal.theme.system".localized, Color(white: 0.97), .blue),
        ("maestri-dark", "terminal.theme.dark".localized, Color(white: 0.12), .green),
        ("maestri-light", "terminal.theme.light".localized, .white, .blue),
    ]

    /// Determine whether the currently selected theme is a custom theme (not system/maestri-dark/maestri-light)
    private var isCustomThemeSelected: Bool {
        !["system", "maestri-dark", "maestri-light"].contains(selectedThemeId)
    }

    /// Obtain the display information of a custom theme
    private var customThemeDisplay: (bg: Color, fg: Color, name: String)? {
        guard isCustomThemeSelected else { return nil }
        let registry = TerminalThemeRegistry.shared
        guard let theme = registry.theme(for: selectedThemeId) else { return nil }
        return (
            bg: Color(nsColor: NSColor(hex: theme.background) ?? .black),
            fg: Color(nsColor: NSColor(hex: theme.cursor) ?? .white),
            name: theme.name
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(themes, id: \.id) { theme in
                Button {
                    selectedThemeId = theme.id
                } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.bg)
                            .frame(width: 86, height: 54)
                            .overlay(
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("~/dev")
                                        .font(.system(size: 9, design: .monospaced))
                                    HStack(spacing: 2) {
                                        Text("$")
                                            .font(.system(size: 9, design: .monospaced))
                                        Rectangle()
                                            .fill(theme.fg)
                                            .frame(width: 5, height: 11)
                                    }
                                }
                                .foregroundStyle(theme.id == "maestri-dark" ? .white : .primary)
                                .padding(8)
                                , alignment: .topLeading
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedThemeId == theme.id ? Color.accentColor : Color(white: 0.8), lineWidth: selectedThemeId == theme.id ? 2 : 0.5)
                            )
                        Text(theme.name)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            // Custom theme button
            Button {
                showCustomThemePicker = true
            } label: {
                VStack(spacing: 4) {
                    if let display = customThemeDisplay {
                        // Custom theme selected: Show preview of this theme
                        RoundedRectangle(cornerRadius: 8)
                            .fill(display.bg)
                            .frame(width: 86, height: 54)
                            .overlay(
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("~/dev")
                                        .font(.system(size: 9, design: .monospaced))
                                    HStack(spacing: 2) {
                                        Text("$")
                                            .font(.system(size: 9, design: .monospaced))
                                        Rectangle()
                                            .fill(display.fg)
                                            .frame(width: 5, height: 11)
                                    }
                                }
                                .foregroundStyle(.white)
                                .padding(8)
                                , alignment: .topLeading
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isCustomThemeSelected ? Color.accentColor : Color(white: 0.8), lineWidth: isCustomThemeSelected ? 2 : 0.5)
                            )
                    } else {
                        // Custom theme not selected: Show dotted line placeholder
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .frame(width: 86, height: 54)
                            .overlay(
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("~/dev")
                                        .font(.system(size: 9, design: .monospaced))
                                    HStack(spacing: 2) {
                                        Text("$")
                                            .font(.system(size: 9, design: .monospaced))
                                        Rectangle()
                                            .fill(Color.blue)
                                            .frame(width: 5, height: 11)
                                    }
                                }
                                .foregroundStyle(.primary)
                                .padding(8)
                                , alignment: .topLeading
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isCustomThemeSelected ? Color.accentColor : Color(white: 0.8), lineWidth: isCustomThemeSelected ? 2 : 0.5)
                            )
                    }
                    Text("terminal.theme.custom".localized)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showCustomThemePicker) {
            CustomThemePickerSheet(selectedThemeId: $selectedThemeId)
        }
    }
}

// MARK: - Custom Theme Picker Sheet

struct CustomThemePickerSheet: View {
    @Binding var selectedThemeId: String
    @Environment(\.dismiss) private var dismiss

    @State private var previewThemeId: String = ""

    private var allThemes: [TerminalTheme] {
        TerminalThemeRegistry.shared.themes
    }

    private var previewTheme: TerminalTheme? {
        TerminalThemeRegistry.shared.theme(for: previewThemeId)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("terminal.theme.custom_title")
                .font(.system(size: 18, weight: .bold))
                .padding(.top, 28)
                .padding(.bottom, 24)

            // Topic grid (scrollable)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 5), spacing: 20) {
                    ForEach(allThemes) { theme in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                previewThemeId = theme.id
                            }
                        } label: {
                            themeGridItem(theme: theme)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 32)
            }
            .frame(maxHeight: .infinity)

            // Preview area
            previewSection
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()
                .padding(.horizontal, 24)

            // Bottom button
            HStack {
                Button("button.cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                .controlSize(.large)

                Spacer()

                Button("button.done") {
                    selectedThemeId = previewThemeId
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(previewThemeId.isEmpty)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(width: 680, height: 680)
        .onAppear {
            // If a custom theme is currently selected, it is selected by default
            if allThemes.contains(where: { $0.id == selectedThemeId }) {
                previewThemeId = selectedThemeId
            } else {
                previewThemeId = ""
            }
        }
    }

    // MARK: - Preview area (including placeholder)

    @ViewBuilder
    private var previewSection: some View {
        if let theme = previewTheme {
            themePreviewView(theme: theme)
        } else {
            // Show placeholder when not selected
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                .frame(height: 150)
                .overlay(
                    Text("terminal.theme.preview_placeholder")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                )
        }
    }

    // MARK: - Topic grid items

    @ViewBuilder
    private func themeGridItem(theme: TerminalTheme) -> some View {
        let isSelected = previewThemeId == theme.id
        let bgColor = Color(nsColor: NSColor(hex: theme.background) ?? .black)
        let fgColor = Color(nsColor: NSColor(hex: theme.foreground) ?? .white)
        let cursorColor = Color(nsColor: NSColor(hex: theme.cursor) ?? .green)

        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(bgColor)
                .frame(height: 70)
                .overlay(
                    VStack(alignment: .leading, spacing: 3) {
                        // ANSI color bar
                        HStack(spacing: 2) {
                            ForEach(ansiColors(for: theme), id: \.self) { color in
                                Rectangle()
                                    .fill(color)
                                    .frame(width: 6, height: 4)
                            }
                        }
                        Spacer()
                        Text("~/dev")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(fgColor)
                        HStack(spacing: 2) {
                            Text("$")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(fgColor)
                            Rectangle()
                                .fill(cursorColor)
                                .frame(width: 5, height: 11)
                        }
                    }
                    .padding(8)
                    , alignment: .topLeading
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.6),
                                lineWidth: isSelected ? 2.5 : 0.5)
                )

            Text(theme.name)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28)
        }
    }

    // MARK: - Preview view

    @ViewBuilder
    private func themePreviewView(theme: TerminalTheme) -> some View {
        let bgColor = Color(nsColor: NSColor(hex: theme.background) ?? .black)
        let fgColor = Color(nsColor: NSColor(hex: theme.foreground) ?? .white)
        let greenColor = Color(nsColor: NSColor(hex: theme.ansiGreen) ?? .green)
        let yellowColor = Color(nsColor: NSColor(hex: theme.ansiYellow) ?? .yellow)
        let blueColor = Color(nsColor: NSColor(hex: theme.ansiBlue) ?? .blue)
        let redColor = Color(nsColor: NSColor(hex: theme.ansiRed) ?? .red)
        let cursorColor = Color(nsColor: NSColor(hex: theme.cursor) ?? .white)

        RoundedRectangle(cornerRadius: 12)
            .fill(bgColor)
            .frame(height: 150)
            .overlay(
                VStack(alignment: .leading, spacing: 5) {
                    // Simulate terminal output
                    HStack(spacing: 0) {
                        Text("ev@maestri")
                            .foregroundStyle(greenColor)
                        Text(":")
                            .foregroundStyle(fgColor)
                        Text("~/dev/maestro")
                            .foregroundStyle(blueColor)
                        Text("$ ")
                            .foregroundStyle(fgColor)
                        Text("git status")
                            .foregroundStyle(fgColor)
                    }
                    .font(.system(size: 12, design: .monospaced))

                    HStack(spacing: 0) {
                        Text("On branch ")
                            .foregroundStyle(fgColor)
                        Text("dev")
                            .foregroundStyle(yellowColor)
                    }
                    .font(.system(size: 12, design: .monospaced))

                    HStack(spacing: 0) {
                        Text("  modified:   ")
                            .foregroundStyle(redColor)
                        Text("Terminal/Theme/ThemePicker.swift")
                            .foregroundStyle(fgColor)
                    }
                    .font(.system(size: 12, design: .monospaced))

                    HStack(spacing: 0) {
                        Text("  added:      ")
                            .foregroundStyle(greenColor)
                        Text("Terminal/Theme/TerminalThemeRegistry.swift")
                            .foregroundStyle(fgColor)
                    }
                    .font(.system(size: 12, design: .monospaced))

                    HStack(spacing: 0) {
                        Text("$ ")
                            .foregroundStyle(fgColor)
                        Rectangle()
                            .fill(cursorColor)
                            .frame(width: 8, height: 15)
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
                .padding(16)
                , alignment: .topLeading
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
            )
    }

    // MARK: - Helpers

    private func ansiColors(for theme: TerminalTheme) -> [Color] {
        [
            Color(nsColor: NSColor(hex: theme.ansiRed) ?? .red),
            Color(nsColor: NSColor(hex: theme.ansiGreen) ?? .green),
            Color(nsColor: NSColor(hex: theme.ansiYellow) ?? .yellow),
            Color(nsColor: NSColor(hex: theme.ansiBlue) ?? .blue),
            Color(nsColor: NSColor(hex: theme.ansiMagenta) ?? .purple),
            Color(nsColor: NSColor(hex: theme.ansiCyan) ?? .cyan),
            Color(nsColor: NSColor(hex: theme.ansiBrightRed) ?? .red),
            Color(nsColor: NSColor(hex: theme.ansiBrightGreen) ?? .green),
        ]
    }
}

// MARK: - Font Picker View

struct FontPickerView: View {
    @Binding var fontFamily: String
    @Binding var fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(fontFamily)  \(Int(fontSize))pt")
                    .font(.system(size: 13))
                Spacer()
                Button("terminal.edit.font_choose") {
                    showFontPanel()
                }
                .controlSize(.small)
            }

            // Preview - gray background box, left aligned
            HStack {
                Text("abc 012 →|←")
                    .font(.custom(fontFamily, size: fontSize))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func showFontPanel() {
        let panel = NSFontPanel.shared
        let manager = NSFontManager.shared
        let font = NSFont(name: fontFamily, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        manager.setSelectedFont(font, isMultiple: false)
        panel.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Sheet TextField activation (common to all Sheets with TextField)

/// Activate the first TextField in the sheet and deactivate all the main window
/// input context of NSTextInputClient (SwiftTerm TerminalView),
/// Prevent TSM from routing keyboard events to background terminals.
func activateFirstTextField() {
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))

        guard let sheetWin = NSApp.windows.first(where: { $0.isSheet }) else { return }
        guard let parentWin = sheetWin.sheetParent else { return }

        // ──Core Repair──────────────────────────────────────────────────────
        // SwiftTerm's TerminalView implements NSTextInputClient.
        // Even if it is not the first responder, TSM (Text Services Manager) may still
        // Holding its NSTextInputContext in the active state causes keyboard events to be routed to it
        // Instead of the TextField in the sheet, the local event monitor cannot receive events at all.
        //
        // Fix: Find all NSTextInputClient views in the main window,
        // Force a call to NSTextInputContext.deactivate() to let TSM release these contexts.
        // ─────────────────────────────────────────────────────────────────────
        deactivateAllTextInputClients(in: parentWin)

        // Activate the field editor of the first NSTextField in the sheet
        if let tf = firstEditableTextField(in: sheetWin.contentView) {
            sheetWin.makeFirstResponder(tf)
            tf.selectText(nil)
        }
    }
}

/// Traverse all NSViews in the window, and view the view that implements NSTextInputClient
/// Call deactivate() of its inputContext to release the active context held by TSM.
private func deactivateAllTextInputClients(in window: NSWindow) {
    func walk(_ view: NSView) {
        if view is NSTextInputClient {
            view.inputContext?.deactivate()
        }
        for sub in view.subviews { walk(sub) }
    }
    if let root = window.contentView { walk(root) }
}

private func firstEditableTextField(in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let tf = view as? NSTextField, tf.isEditable, !tf.isHidden, tf.alphaValue > 0 {
        return tf
    }
    for sub in view.subviews {
        if let found = firstEditableTextField(in: sub) { return found }
    }
    return nil
}
