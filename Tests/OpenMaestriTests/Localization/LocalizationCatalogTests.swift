import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    private let supportedLocales = ["en", "zh-Hans", "pt-BR"]

    func testEveryCatalogEntrySupportsEveryLocale() throws {
        let strings = try loadCatalogStrings()
        var failures: [String] = []

        for (key, value) in strings.sorted(by: { $0.key < $1.key }) {
            guard let entry = value as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                failures.append("\(key): missing localizations")
                continue
            }

            for locale in supportedLocales {
                guard let localization = localizations[locale] as? [String: Any],
                      let stringUnit = localization["stringUnit"] as? [String: Any],
                      let text = stringUnit["value"] as? String,
                      !text.isEmpty else {
                    failures.append("\(key): missing \(locale)")
                    continue
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testEveryLocalizedKeyUsedBySwiftExistsInCatalog() throws {
        let catalogKeys = Set(try loadCatalogStrings().keys)
        let pattern = try NSRegularExpression(pattern: #"\"([A-Za-z0-9_.-]+)\"\.localized"#)
        var missing: [String] = []

        for file in try swiftSourceFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                if !catalogKeys.contains(key) {
                    missing.append("\(file.path): \(key)")
                }
            }
        }

        XCTAssertTrue(missing.isEmpty, missing.joined(separator: "\n"))
    }

    func testTooltipsDoNotBypassLocalization() throws {
        let rawTooltip = try NSRegularExpression(
            pattern: #"tooltip:\s*\"[^\"]+\"(?!\.localized)"#
        )
        let rawHelp = try NSRegularExpression(
            pattern: #"\.help\(\s*\"[^\"]+\"\s*\)"#
        )
        var failures: [String] = []

        for file in try swiftSourceFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            if rawTooltip.firstMatch(in: source, range: range) != nil {
                failures.append("\(file.path): raw tooltip")
            }
            if rawHelp.firstMatch(in: source, range: range) != nil {
                failures.append("\(file.path): raw .help text")
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func loadCatalogStrings() throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot
            .appendingPathComponent("Sources/Resources/Localizable.xcstrings"))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            throw NSError(domain: "LocalizationCatalogTests", code: 1)
        }
        return strings
    }

    private func swiftSourceFiles() throws -> [URL] {
        let sourceRoot = repositoryRoot.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
