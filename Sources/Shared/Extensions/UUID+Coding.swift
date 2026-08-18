import Foundation

extension UUID {
    /// Create UUID from string (facilitates Codable decoding)
    init?(uuidString: String?) {
        guard let str = uuidString else { return nil }
        self.init(uuidString: str)
    }
}
