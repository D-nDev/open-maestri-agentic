import Foundation
// SSH Remote Terminal Provider (Terminal for SSH connections, fully implemented in Epic 11)
// Reuse the connection established by SSHTunnelService
final class SSHTerminalProvider {
    let terminalId: UUID
    let config: SSHConfig

    init(terminalId: UUID, config: SSHConfig) {
        self.terminalId = terminalId
        self.config = config
    }
}
