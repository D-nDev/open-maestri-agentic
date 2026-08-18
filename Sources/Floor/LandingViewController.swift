import SwiftUI
import OSLog

/// Landing (merge into target branch) confirmation interface
struct LandingView: View {
    let floor: Floor
    let workingDirectory: String
    @State private var targetBranch = "main"
    @State private var diffText = ""
    @State private var isLanding = false
    @State private var landError: String?
    @State private var landSuccess = false
    var onLanded: (() -> Void)?
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "airplane")
                Text(verbatim: "Landing: \(floor.name)").font(.headline)
            }

            HStack {
                Text("floor.target_branch_label").foregroundStyle(.secondary)
                TextField("floor.target_branch", text: $targetBranch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }

            if !diffText.isEmpty {
                ScrollView {
                    Text(diffText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let err = landError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            if landSuccess {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("floor.merge_success").foregroundStyle(.green)
                }
            }

            HStack {
                Button("button.cancel", action: onCancel).keyboardShortcut(.escape)
                Spacer()
                Button("button.merge") { performLand() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(isLanding || landSuccess)
                if isLanding { ProgressView().scaleEffect(0.7) }
            }
        }
        .padding()
        .frame(width: 520)
        .onAppear { loadDiff() }
    }

    private func loadDiff() {
        // Capture values on @MainActor ahead of time to avoid cross-actor access within Task.detached
        let branchName = floor.branchName
        let dir = workingDirectory
        Task.detached(priority: .userInitiated) {
            let result = (try? runGit(["diff", "--stat", branchName], in: dir)) ?? ""
            let noDiff = await "git.no_diff".localized  // @MainActor property requires await
            await MainActor.run { diffText = result.isEmpty ? noDiff : result }
        }
    }

    private func performLand() {
        isLanding = true
        landError = nil
        // Capture values on @MainActor ahead of time to avoid cross-actor access within Task.detached
        let capturedFloor = floor
        let branch = targetBranch
        let dir = workingDirectory
        Task.detached(priority: .userInitiated) {
            do {
                try FloorManager.shared.land(floor: capturedFloor, targetBranch: branch, workingDirectory: dir)
                await MainActor.run {
                    isLanding = false
                    landSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        onLanded?()
                    }
                }
            } catch {
                await MainActor.run {
                    isLanding = false
                    landError = error.localizedDescription
                }
            }
        }
    }

    // nonisolated: This method does not access any self properties and does not need to be run on @MainActor
    // Allow direct calls from Task.detached without blocking the main thread
    @discardableResult
    nonisolated private func runGit(_ args: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
