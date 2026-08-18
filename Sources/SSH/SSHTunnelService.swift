import Foundation
import OSLog

/// SSH reverse tunnel service (FR59-60, with SSHManager)
final class SSHTunnelService {
    static let shared = SSHTunnelService()
    private let logger = Logger.make(category: "SSHTunnelService")
    private(set) var isActive: Bool = false
    private(set) var tunnelPort: Int = 7433
    private init() {}

    func startTunnel(config: SSHConfig) throws {
        try SSHManager.shared.connect(config: config)
        tunnelPort = config.tunnelPort
        isActive = true
        logger.info("SSH tunnel active on port \(self.tunnelPort)")
    }

    func stopTunnel() {
        SSHManager.shared.disconnect()
        isActive = false
        logger.info("SSH tunnel stopped")
    }
}
