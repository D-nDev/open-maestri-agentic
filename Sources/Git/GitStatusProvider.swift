import Foundation
import OSLog

/// git status and operations provider
/// Call system git command through Process
final class GitStatusProvider {
    private let logger = Logger.make(category: "GitStatusProvider")

    let workingDirectory: String

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
    }

    // MARK: - git warehouse detection

    var isGitRepository: Bool {
        let gitDir = URL(fileURLWithPath: workingDirectory).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitDir.path)
    }

    // MARK: - Current branch

    func currentBranch() throws -> String {
        try run(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Status

    func status() throws -> [(path: String, status: GitFileStatus)] {
        let output = try run(["status", "--porcelain"])
        return output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line -> (String, GitFileStatus)? in
                guard line.count >= 4 else { return nil }
                let code = String(line.prefix(2))
                let path = String(line.dropFirst(3))
                let status: GitFileStatus
                switch code.trimmingCharacters(in: .whitespaces) {
                case "M":  status = .modified
                case "A":  status = .added
                case "D":  status = .deleted
                case "R":  status = .renamed
                case "??": status = .untracked
                default:   status = .unmodified
                }
                return (path, status)
            }
    }

    // MARK: - git operations

    func commit(message: String, files: [String]) throws {
        if !files.isEmpty {
            try run(["add"] + files)
        }
        try run(["commit", "-m", message])
    }

    func pull() throws {
        try run(["pull"])
    }

    func push() throws {
        try run(["push"])
    }

    func fetch() throws {
        try run(["fetch", "--all", "--prune"])
    }

    func diff() throws -> String {
        try run(["diff"])
    }

    // MARK: - internal git execution

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
