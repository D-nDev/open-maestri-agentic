import XCTest
import CoreGraphics
@testable import open_maestri

/// Test backward-compatible decoding of CanvasNode legacy data formats
final class CanvasNodeLegacyDecodeTests: XCTestCase {
    private let decoder = PersistenceManager.shared.decoder

    // MARK: - lastModifiedAt field is missing

    func testDecodeCanvasNodeWithoutLastModifiedAt() throws {
        // Simulate legacy data (without lastModifiedAt)
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "frame": [[100.0, 200.0], [400.0, 300.0]],
          "content": {
            "terminal": {
              "_0": {
                "agentType": "claude_code",
                "command": "claude",
                "name": "Agent",
                "icon": "seal",
                "color": "#007AFF",
                "id": "00000000-0000-0000-0000-000000000002",
                "shellPath": "/bin/zsh",
                "workingDirectory": "/tmp",
                "status": "idle",
                "isManager": false,
                "monitorWithOmbro": false,
                "autoScrollLocked": false,
                "shortcutMode": {"kind": "automatic"},
                "scrollbackLineCount": 0
              }
            }
          },
          "zIndex": 0,
          "isLocked": false,
          "createdAt": "2026-05-16T00:00:00Z"
        }
        """.data(using: .utf8)!

        // Exception should not be thrown, lastModifiedAt should fallback to Date()
        let node = try decoder.decode(CanvasNode.self, from: json)
        XCTAssertEqual(node.frame.origin.x, 100, accuracy: 0.01)
        XCTAssertNotNil(node.lastModifiedAt)
    }

    // MARK: - zIndex and isLocked fields are missing

    func testDecodeCanvasNodeWithMissingOptionalFields() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000003",
          "frame": [[50.0, 75.0], [200.0, 150.0]],
          "content": {
            "stickyNote": {
              "_0": {
                "color": "#FEFDE8",
                "fontSize": 14,
                "hasCustomName": false,
                "isPreviewing": true,
                "storageMode": {"managed": {}}
              }
            }
          },
          "createdAt": "2026-05-16T00:00:00Z"
        }
        """.data(using: .utf8)!

        let node = try decoder.decode(CanvasNode.self, from: json)
        XCTAssertEqual(node.zIndex, 0, "缺省 zIndex 应为 0")
        XCTAssertFalse(node.isLocked, "缺省 isLocked 应为 false")
    }

    // MARK: - NodeContent round-trip serialization

    func testCanvasNodeRoundTrip() throws {
        let tc = TerminalContent(name: "Test", agentType: "generic_shell", command: "zsh")
        let original = CanvasNode(
            frame: CGRect(x: 9800, y: 8500, width: 600, height: 400),
            content: .terminal(tc)
        )
        let encoder = PersistenceManager.shared.encoder
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(CanvasNode.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.frame.origin.x, original.frame.origin.x, accuracy: 0.01)
        XCTAssertEqual(decoded.zIndex, original.zIndex)
    }
}
