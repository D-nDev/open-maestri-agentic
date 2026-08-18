import Foundation
import OSLog

/// SSH connection configuration
struct SSHConfig: Codable {
    var host: String
    var user: String
    var port: Int
    var scriptPath: String  // Path to install omaestri on remote server
    var tunnelPort: Int     // Reverse tunnel local port (default 7433)
    var addToPath: Bool     // Whether to add script directories to shell profile PATH
}

/// Remote SSH Manager (FR59-60, Epic 11)
/// - Establish an SSH connection and install the omaestri script remotely
/// - Route remote omaestri ask back to local InterAgentServer via reverse tunnel (-R)
final class SSHManager {
    static let shared = SSHManager()
    private let logger = Logger.make(category: "SSHManager")
    private var sshProcess: Process?
    private var isConnected: Bool = false
    private init() {}

    // MARK: - Connect

    func connect(config: SSHConfig) throws {
        guard !isConnected else {
            logger.warning("SSH already connected")
            return
        }

        // Establishing reverse tunnel: remote tunnelPort → local InterAgentServer
        let localPort = InterAgentServer.shared.port
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N",                           // Remote command not executed
            "-o", "StrictHostKeyChecking=accept-new",
            "-R", "\(config.tunnelPort):127.0.0.1:\(localPort)",  // Reverse tunnel (NFR8)
            "-p", "\(config.port)",
            "\(config.user)@\(config.host)"
        ]
        try process.run()
        sshProcess = process
        isConnected = true
        logger.info("SSH tunnel established to \(config.host):\(config.port), tunnelPort=\(config.tunnelPort)")

        // Installing the omaestri script remotely
        Task { try await installOmaestri(config: config) }
    }

    func disconnect() {
        sshProcess?.terminate()
        sshProcess = nil
        isConnected = false
        logger.debug("SSH disconnected")
    }

    // MARK: - Install omaestri script

    /// Generate omaestri shell script content (for installation to remote server)
    private func buildRemoteScript(host: String) -> String {
        """
        #!/usr/bin/env bash
        export OMAESTRI_HOST="\(host)"
        export MAESTRI_HOST="\(host)"
        json_array() {
          if command -v jq >/dev/null 2>&1; then
            printf '%s\\n' "$@" | jq -R . | jq -s .
          else
            printf '['
            local first=true
            for arg in "$@"; do
              $first || printf ','
              first=false
              printf '"%s"' "$(printf '%s' "$arg" | \\
                sed 's/\\\\/\\\\\\\\/g' | sed 's/"/\\\\"/g' | \\
                sed ':a;N;$!ba;s/\\n/\\\\n/g' | \\
                sed 's/\\t/\\\\t/g' | sed 's/\\r/\\\\r/g')"
            done
            printf ']'
          fi
        }
        omaestri() {
          curl -sf --max-time 30 \\
            -H "Content-Type:application/json" \\
            -d "{\\"args\\":$(json_array "$@")}" \\
            "http://$OMAESTRI_HOST/cli"
        }
        maestri() { omaestri "$@"; }
        """
    }

    private func installOmaestri(config: SSHConfig) async throws {
        let tunnelHost = "127.0.0.1:\(config.tunnelPort)"
        let scriptContent = buildRemoteScript(host: tunnelHost)

        // Use base64 encoding to avoid quote/variable expansion escaping issues
        guard let scriptData = scriptContent.data(using: .utf8) else { return }
        let base64Script = scriptData.base64EncodedString()
        let scriptDir = (config.scriptPath as NSString).deletingLastPathComponent
        let scriptFile = (config.scriptPath as NSString).lastPathComponent

        let remoteCmd = [
            "mkdir -p \(scriptDir)",
            "echo \(base64Script) | base64 -d > \(config.scriptPath)",
            "chmod +x \(config.scriptPath)",
        ].joined(separator: " && ")

        // If the user selects addToPath, append to the shell profile
        let addToPathCmd = config.addToPath
            ? " && echo 'export PATH=\"\(scriptDir):$PATH\"' >> ~/.zshrc 2>/dev/null; echo 'export PATH=\"\(scriptDir):$PATH\"' >> ~/.bashrc 2>/dev/null; true"
            : ""

        let sshCmd = Process()
        sshCmd.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        sshCmd.arguments = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "\(config.port)",
            "\(config.user)@\(config.host)",
            remoteCmd + addToPathCmd
        ]
        try sshCmd.run()
        sshCmd.waitUntilExit()
        logger.info("omaestri script installed at \(config.host):\(config.scriptPath) (file: \(scriptFile))")
    }
}
