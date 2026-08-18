import Foundation
import OSLog

/// Floor configuration (git worktree isolation environment)
struct Floor: Codable, Identifiable {
    var id: UUID
    var name: String
    var branchName: String
    var worktreePath: String    // .open-maestri/floors/{name}
    var hooks: FloorHooks
    var createdAt: Date

    init(id: UUID = UUID(), name: String, branchName: String, workspaceDir: String) {
        self.id = id
        self.name = name
        self.branchName = branchName
        self.worktreePath = "\(workspaceDir)/.open-maestri/floors/\(name)"
        self.hooks = FloorHooks()
        self.createdAt = Date()
    }
}

struct FloorHooks: Codable {
    var setup: [String] = []
    var run: [String] = []
    var teardown: [String] = []
    var autoRunSetup: Bool = false
}

/// Floor Lifecycle Manager (git worktree operation, FR53-55)
final class FloorManager {
    static let shared = FloorManager()
    private let logger = Logger.make(category: "FloorManager")
    private init() {}

    // MARK: - Floor creation

    func createFloor(name: String, branchName: String, workingDirectory: String) throws -> Floor {
        // Verify working directory is git repo
        let gitDir = workingDirectory + "/.git"
        guard FileManager.default.fileExists(atPath: gitDir) else {
            let fmt = Bundle.main.localizedString(forKey: "floor.error.not_git_repo", value: nil, table: nil)
            throw MaestriError.terminalConnectionFailed(String(format: fmt, workingDirectory))
        }

        let floor = Floor(name: name, branchName: branchName, workspaceDir: workingDirectory)
        try runGit(["worktree", "add", "-b", branchName, floor.worktreePath], in: workingDirectory)
        logger.info("Floor '\(name)' created at \(floor.worktreePath)")
        return floor
    }

    // MARK: - Floor Delete

    func removeFloor(_ floor: Floor, workingDirectory: String) throws {
        try runGit(["worktree", "remove", "--force", floor.worktreePath], in: workingDirectory)
        logger.info("Floor '\(floor.name)' removed")
    }

    // MARK: - Landing (merge commit to target branch)

    func land(floor: Floor, targetBranch: String, workingDirectory: String) throws {
        // Get the Floor branch to submit to the main warehouse
        try runGit([
            "fetch",
            floor.worktreePath,
            "\(floor.branchName):\(floor.branchName)"
        ], in: workingDirectory)
        try runGit(["merge", floor.branchName, "--no-ff", "-m", "Landing: \(floor.name)"], in: workingDirectory)
        logger.info("Floor '\(floor.name)' landed onto '\(targetBranch)'")
    }

    // MARK: - Hooks execution

    func runHooks(_ hooks: [String], floor: Floor, workingDirectory: String) async throws {
        for hook in hooks {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", hook]
            process.currentDirectoryURL = URL(fileURLWithPath: floor.worktreePath)
            process.environment = ProcessInfo.processInfo.environment.merging([
                "OMAESTRI_FLOOR_NAME":    floor.name,
                "OMAESTRI_BRANCH_NAME":   floor.branchName,
                "OMAESTRI_FLOOR_PATH":    floor.worktreePath,
                "OMAESTRI_ROOT_PATH":     workingDirectory,
                "OMAESTRI_PROJECT_NAME":  URL(fileURLWithPath: workingDirectory).lastPathComponent,
            ]) { _, new in new }
            try process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Internal git call

    @discardableResult
    private func runGit(_ args: [String], in directory: String) throws -> String {
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
