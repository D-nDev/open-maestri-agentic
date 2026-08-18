import Foundation

extension Date {
    /// ISO 8601 UTC string (consistent with Maestri data format)
    var iso8601String: String {
        ISO8601DateFormatter().string(from: self)
    }

    /// Parsing from ISO 8601 strings
    static func from(iso8601 string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
