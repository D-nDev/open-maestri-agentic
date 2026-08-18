import AppKit
import XCTest
@testable import open_maestri

final class OrcaTerminalTranscriptTests: XCTestCase {
    func testStreamingPrefixReplacesThePartialLine() {
        let output = OrcaTerminalTranscript.merge(
            existing: ["starting", "exe"],
            incoming: ["executando"]
        )

        XCTAssertEqual(output, ["starting", "executando"])
    }

    func testCarriageReturnKeepsOnlyTheLatestRevision() {
        XCTAssertEqual(
            OrcaTerminalTranscript.normalize("exe\rexecutando"),
            "executando"
        )
    }

    func testSpinnerFramesReplaceInsteadOfAccumulating() {
        let output = OrcaTerminalTranscript.merge(
            existing: ["ready", "⠋ Working… ⟦esc⟧"],
            incoming: ["⠙ Working… ⟦esc⟧"]
        )

        XCTAssertEqual(output, ["ready", "⠙ Working… ⟦esc⟧"])
    }

    func testRedrawnBlocksReplaceTheirPreviousFrame() {
        let output = OrcaTerminalTranscript.merge(
            existing: ["history", "⠋ Wait", "Todos 1/4", "one", "two"],
            incoming: ["⠙ Wait", "Todos 1/4", "one", "three"]
        )

        XCTAssertEqual(output, ["history", "⠙ Wait", "Todos 1/4", "one", "three"])
    }

    func testDistinctLinesArePreserved() {
        let output = OrcaTerminalTranscript.merge(
            existing: ["build started"],
            incoming: ["build finished"]
        )

        XCTAssertEqual(output, ["build started", "build finished"])
    }

    @MainActor
    func testTerminalStylerHighlightsStructuredOutput() {
        let styled = OrcaTerminalTextStyler.attributedString(
            for: #"{"status":"running","attempt":2}"#
        )
        let source = styled.string as NSString
        let keyLocation = source.range(of: "status").location
        let valueLocation = source.range(of: "running").location
        let numberLocation = source.range(of: "2").location

        XCTAssertEqual(
            styled.attribute(.foregroundColor, at: keyLocation, effectiveRange: nil) as? NSColor,
            .systemCyan
        )
        XCTAssertEqual(
            styled.attribute(.foregroundColor, at: valueLocation, effectiveRange: nil) as? NSColor,
            .systemGreen
        )
        XCTAssertEqual(
            styled.attribute(.foregroundColor, at: numberLocation, effectiveRange: nil) as? NSColor,
            .systemOrange
        )
    }
}
