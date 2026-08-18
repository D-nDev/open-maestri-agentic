import SwiftUI
import OSLog

/// Floor overview view (⌘⇧\ to open, button in the lower right corner to open)
struct FloorOverviewView: View {
    @Bindable var workspace: WorkspaceManager
    @State private var selectedFloorId: UUID? = nil
    @State private var showCreateFloor = false
    @State private var showLanding = false
    @State private var landingFloor: Floor? = nil
    @State private var errorMessage: String? = nil
    @State private var hooksFloor: Floor? = nil
    @State private var showHooksSheet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("floor.work_branches").font(.headline)
                Spacer()
                Button("button.close") { dismiss() }.keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    // Ground layer (always present)
                    FloorRowView(
                        name: "Ground",
                        branchName: currentBranch(),
                        isSelected: selectedFloorId == nil,
                        isGround: true
                    ) {
                        selectedFloorId = nil
                    } onHooks: {} onLand: {}

                    ForEach(floors) { floor in
                        FloorRowView(
                            name: floor.name,
                            branchName: floor.branchName,
                            isSelected: selectedFloorId == floor.id,
                            isGround: false
                        ) {
                            selectedFloorId = floor.id
                        } onHooks: {
                            hooksFloor = floor
                            showHooksSheet = true
                        } onLand: {
                            landingFloor = floor
                            showLanding = true
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if let err = errorMessage {
                Text(err).foregroundStyle(.red).font(.caption).padding(.horizontal)
            }

            Divider()

            HStack {
                Button("floor.new_button") { showCreateFloor = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.workingDirectory.isEmpty)
                Spacer()
            }
            .padding()
        }
        .frame(width: 340, height: 400)
        .sheet(isPresented: $showCreateFloor) {
            CreateFloorSheet(workingDirectory: workspace.workingDirectory) { name, branch in
                createFloor(name: name, branchName: branch)
            }
            .environment(\.locale, LocalizationManager.shared.locale)
        }
        .sheet(isPresented: $showLanding) {
            if let floor = landingFloor {
                LandingView(floor: floor, workingDirectory: workspace.workingDirectory) {
                    // Delete floor after successful Landing
                    removeFloor(floor)
                    showLanding = false
                } onCancel: {
                    showLanding = false
                }
                .environment(\.locale, LocalizationManager.shared.locale)
            }
        }
        .sheet(isPresented: $showHooksSheet) {
            if let floor = hooksFloor,
               let entryIdx = workspace.floors.firstIndex(where: { $0.id == floor.id }) {
                HooksConfigSheet(hooks: Binding(
                    get: { workspace.floors[entryIdx].hooks },
                    set: { newHooks in
                        workspace.floors[entryIdx].hooks = newHooks
                        Task { try? await workspace.save() }
                    }
                ), floorName: floor.name)
                .environment(\.locale, LocalizationManager.shared.locale)
            }
        }
    }

    private var floors: [Floor] {
        workspace.floors.compactMap { entry in
            // Use entry.worktreePath to ensure consistent paths (no recalculation)
            var floor = Floor(id: entry.id, name: entry.name,
                              branchName: entry.branchName,
                              workspaceDir: workspace.workingDirectory)
            floor.worktreePath = entry.worktreePath
            floor.hooks = entry.hooks
            return floor
        }
    }

    private func currentBranch() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        proc.currentDirectoryURL = URL(fileURLWithPath: workspace.workingDirectory)
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run(); proc.waitUntilExit()
        return (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "main")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createFloor(name: String, branchName: String) {
        Task.detached(priority: .userInitiated) {
            do {
                let floor = try FloorManager.shared.createFloor(
                    name: name, branchName: branchName,
                    workingDirectory: workspace.workingDirectory
                )
                let entry = FloorEntry(
                    id: floor.id, name: floor.name,
                    branchName: floor.branchName,
                    worktreePath: floor.worktreePath,
                    hooks: floor.hooks,
                    createdAt: floor.createdAt
                )
                await MainActor.run {
                    workspace.floors.append(entry)
                    Task { try? await workspace.save() }
                }
                try await HooksManager.shared.runSetupHooks(floor: floor, workingDirectory: workspace.workingDirectory)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func removeFloor(_ floor: Floor) {
        // Update the UI status in the main thread first, and then perform file system operations in the background
        let dir = workspace.workingDirectory
        workspace.floors.removeAll { $0.id == floor.id }
        Task { try? await workspace.save() }
        // Background execution hooks + worktree removal (no need for @MainActor)
        Task.detached(priority: .utility) {
            try? await HooksManager.shared.runTeardownHooks(floor: floor, workingDirectory: dir)
            try? FloorManager.shared.removeFloor(floor, workingDirectory: dir)
        }
    }
}

// MARK: - Floor OK

struct FloorRowView: View {
    let name: String
    let branchName: String
    let isSelected: Bool
    let isGround: Bool
    let onSelect: () -> Void
    let onHooks: () -> Void
    let onLand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(branchName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isGround {
                Button("floor.land") { onLand() }
                    .buttonStyle(.bordered).controlSize(.small)
                Button {
                    onHooks()
                } label: {
                    Image(systemName: "bolt.fill")
                }
                .buttonStyle(.plain)
                .help("tooltip.config_hooks".localized)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Hooks Configuration Sheet

/// Edit Floor's Setup/Run/Teardown Hooks (shell command list)
struct HooksConfigSheet: View {
    @Binding var hooks: FloorHooks
    let floorName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Hooks — \(floorName)", comment: "floor.hooks_title")
                    .font(.headline)
                Spacer()
                Button("button.close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    HooksPhaseSection(
                        title: "Setup",
                        subtitle: "floor.hook.post_create".localized,
                        systemImage: "play.circle",
                        commands: $hooks.setup
                    )

                    Toggle("routine.auto_run_hooks", isOn: $hooks.autoRunSetup)
                        .padding(.horizontal)

                    Divider()

                    HooksPhaseSection(
                        title: "Run",
                        subtitle: "floor.hook.manual".localized,
                        systemImage: "bolt.circle",
                        commands: $hooks.run
                    )

                    Divider()

                    HooksPhaseSection(
                        title: "Teardown",
                        subtitle: "floor.hook.teardown".localized,
                        systemImage: "stop.circle",
                        commands: $hooks.teardown
                    )
                }
                .padding(.vertical, 12)
            }
        }
        .frame(width: 480, height: 520)
    }
}

// MARK: - Single stage Hooks editing area

struct HooksPhaseSection: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var commands: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    commands.append("")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            if commands.isEmpty {
                Text("terminal.no_command")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
            } else {
                ForEach(commands.indices, id: \.self) { idx in
                    HStack(spacing: 6) {
                        TextField("routine.shell_command_placeholder", text: $commands[idx])
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                        Button {
                            commands.remove(at: idx)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

// MARK: - Create Floor Sheet

struct CreateFloorSheet: View {
    let workingDirectory: String
    let onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var floorName = ""
    @State private var branchName = ""
    @State private var useExistingBranch = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("floor.new").font(.headline)
                Spacer()
                Button("button.cancel") { dismiss() }.keyboardShortcut(.escape)
                Button("button.create") { onCreate(floorName, branchName); dismiss() }
                    .disabled(floorName.isEmpty || branchName.isEmpty)
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }.padding()
            Divider()
            Form {
                TextField("floor.name", text: $floorName)
                    .onChange(of: floorName) { _, v in
                        if !useExistingBranch {
                            branchName = v.lowercased().replacingOccurrences(of: " ", with: "-")
                        }
                    }
                TextField("floor.branch_name", text: $branchName)
                Toggle("floor.use_existing_branch", isOn: $useExistingBranch)
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(width: 360, height: 220)
    }
}
