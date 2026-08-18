import SwiftUI

/// Edit Workspace Sheet (Name/Icon/Color/Working Directory)
struct EditWorkspaceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: WorkspaceEntry
    let onSave: (WorkspaceEntry) -> Void

    @State private var name: String
    @State private var workingDirectory: String
    @State private var selectedIcon: String
    @State private var selectedColor: String

    // Expanded icon list (corresponds to the 9×3 grid in the screenshot)
    private let iconOptions: [String] = [
        // Row 1
        "photo.on.rectangle.angled", "face.smiling", "terminal.fill", "star.fill",
        "theatermasks", "gear", "bubble.left.and.bubble.right", "cpu",
        // Row 2
        "rectangle", "list.bullet.rectangle", "globe", "hammer.fill",
        "wrench.and.screwdriver", "bolt.fill", "square.on.square", "folder",
        // Row 3
        "laptopcomputer", "desktopcomputer", "paintbrush.fill", "folder.fill",
        "doc.text", "shippingbox", "cube", "eye"
    ]

    // Color options (corresponding to the 9 color circles in the screenshot)
    private let colorOptions: [(id: String, color: Color)] = [
        ("blue", .blue),
        ("red", .red),
        ("green", .green),
        ("orange", .orange),
        ("purple", .purple),
        ("pink", .pink),
        ("cyan", .cyan),
        ("yellow", .yellow),
        ("rainbow", .clear) // rainbow with special rendering
    ]

    init(entry: WorkspaceEntry, onSave: @escaping (WorkspaceEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _name = State(initialValue: entry.name)
        _workingDirectory = State(initialValue: entry.workingDirectory)
        _selectedIcon = State(initialValue: entry.icon)
        _selectedColor = State(initialValue: entry.color)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text("workspace.edit.title")
                .font(.title2.weight(.semibold))
                .padding(.top, 24)
                .padding(.bottom, 16)

            // Content area
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name input box
                    TextField("workspace.name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .padding(.horizontal)

                    // Icon selection
                    VStack(alignment: .leading, spacing: 10) {
                        Text("workspace.section.icon")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                            ForEach(iconOptions, id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon)
                                        .font(.title3)
                                        .frame(width: 36, height: 36)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(selectedIcon == icon ? Color.accentColor.opacity(0.15) : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(selectedIcon == icon ? Color.accentColor : Color.clear, lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Color selection
                    VStack(alignment: .leading, spacing: 10) {
                        Text("workspace.section.color")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        HStack(spacing: 12) {
                            ForEach(colorOptions, id: \.id) { option in
                                Button {
                                    selectedColor = option.id
                                } label: {
                                    ZStack {
                                        if option.id == "rainbow" {
                                            // Gradient circles for rainbow colors
                                            Circle()
                                                .fill(
                                                    AngularGradient(
                                                        colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                                                        center: .center
                                                    )
                                                )
                                                .frame(width: 28, height: 28)
                                        } else {
                                            Circle()
                                                .fill(option.color)
                                                .frame(width: 28, height: 28)
                                        }
                                        // Check indicator
                                        if selectedColor == option.id {
                                            Circle()
                                                .stroke(Color.primary, lineWidth: 2.5)
                                                .frame(width: 34, height: 34)
                                        }
                                    }
                                    .frame(width: 36, height: 36)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Working directory
                    VStack(alignment: .leading, spacing: 10) {
                        Text("workspace.section.working_dir")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)

                        HStack(spacing: 8) {
                            Text(abbreviatedPath(workingDirectory))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )

                            Button("button.browse") {
                                pickDirectory()
                            }
                            .controlSize(.regular)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()
                .padding(.top, 8)

            // Bottom button
            HStack(spacing: 12) {
                Button("button.cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                    .controlSize(.large)

                Button("button.save") { save() }
                    .keyboardShortcut(.return)
                    .disabled(name.isEmpty || workingDirectory.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.vertical, 16)
        }
        .frame(width: 500, height: 560)
    }

    // MARK: - Private

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            workingDirectory = url.path
        }
    }

    private func save() {
        var updated = entry
        updated.name = name
        updated.workingDirectory = workingDirectory
        updated.icon = selectedIcon
        updated.color = selectedColor
        onSave(updated)
        dismiss()
    }
}
