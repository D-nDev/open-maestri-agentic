import Foundation

enum OrcaTerminalTranscript {
    static func merge(
        existing: [String],
        incoming: [String],
        limit: Int = 500
    ) -> [String] {
        let cleanIncoming = incoming.map(normalize)
        guard !cleanIncoming.isEmpty else { return Array(existing.suffix(limit)) }
        guard !existing.isEmpty else { return Array(cleanIncoming.suffix(limit)) }

        var result = existing
        if let redrawStart = redrawStart(in: result, incoming: cleanIncoming) {
            result.removeSubrange(redrawStart...)
            result.append(contentsOf: cleanIncoming)
            return Array(result.suffix(limit))
        }

        let overlap = exactOverlap(existing: result, incoming: cleanIncoming)
        if overlap > 0 {
            result.append(contentsOf: cleanIncoming.dropFirst(overlap))
        } else if let last = result.last,
                  let first = cleanIncoming.first,
                  isRevision(last, first) {
            result[result.count - 1] = first
            result.append(contentsOf: cleanIncoming.dropFirst())
        } else {
            result.append(contentsOf: cleanIncoming)
        }
        return Array(result.suffix(limit))
    }

    static func normalize(_ line: String) -> String {
        let withoutANSI = line.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        let latestCarriageReturn = withoutANSI
            .split(separator: "\r", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? withoutANSI
        return applyBackspaces(latestCarriageReturn)
    }

    private static func exactOverlap(existing: [String], incoming: [String]) -> Int {
        let maximum = min(existing.count, incoming.count)
        guard maximum > 0 else { return 0 }
        for count in stride(from: maximum, through: 1, by: -1) {
            if existing.suffix(count).elementsEqual(incoming.prefix(count)) {
                return count
            }
        }
        return 0
    }

    private static func redrawStart(in existing: [String], incoming: [String]) -> Int? {
        guard incoming.count >= 2 else { return nil }
        let lowerBound = max(0, existing.count - 160)
        for start in stride(from: existing.count - 1, through: lowerBound, by: -1) {
            let comparisonCount = min(existing.count - start, incoming.count)
            guard comparisonCount >= 2 else { continue }
            var matches = 0
            for offset in 0..<comparisonCount {
                let oldLine = existing[start + offset]
                let newLine = incoming[offset]
                if oldLine == newLine || (offset == 0 && isRevision(oldLine, newLine)) {
                    matches += 1
                }
            }
            let requiredMatches = max(2, Int(ceil(Double(comparisonCount) * 0.7)))
            if matches >= requiredMatches { return start }
        }
        return nil
    }

    private static func isRevision(_ oldLine: String, _ newLine: String) -> Bool {
        let old = oldLine.trimmingCharacters(in: .whitespaces)
        let new = newLine.trimmingCharacters(in: .whitespaces)
        guard !old.isEmpty, !new.isEmpty else { return false }
        if spinnerBody(old) == spinnerBody(new), spinnerBody(old) != old { return true }
        let shorterCount = min(old.count, new.count)
        return shorterCount >= 3 && (old.hasPrefix(new) || new.hasPrefix(old))
    }

    private static func spinnerBody(_ line: String) -> String {
        guard let first = line.first,
              ("\u{2800}"..."\u{28FF}").contains(String(first)) else { return line }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func applyBackspaces(_ line: String) -> String {
        var characters: [Character] = []
        for character in line {
            if character == "\u{0008}" {
                if !characters.isEmpty { characters.removeLast() }
            } else {
                characters.append(character)
            }
        }
        return String(characters)
    }
}
