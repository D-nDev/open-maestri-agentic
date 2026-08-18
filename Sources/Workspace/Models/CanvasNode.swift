import Foundation
import CoreGraphics

/// Canvas node, frame is encoded using Maestri [[x,y],[w,h]] format
struct CanvasNode: Codable, Identifiable, Equatable {
    var id: UUID
    var frame: CGRect
    var content: NodeContent
    var zIndex: Int
    var isLocked: Bool
    var createdAt: Date
    var lastModifiedAt: Date

    // MARK: - Codable (frame uses [[x,y],[w,h]] format compatible with Maestri)

    private enum CodingKeys: String, CodingKey {
        case id, frame, content, zIndex, isLocked, createdAt, lastModifiedAt
    }

    init(
        id: UUID = UUID(),
        frame: CGRect,
        content: NodeContent,
        zIndex: Int = 0,
        isLocked: Bool = false
    ) {
        self.id = id
        self.frame = frame
        self.content = content
        self.zIndex = zIndex
        self.isLocked = isLocked
        self.createdAt = Date()
        self.lastModifiedAt = Date()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        let frameArray = try container.decode([[Double]].self, forKey: .frame)
        guard let rect = CGRect(frameArray: frameArray) else {
            throw DecodingError.dataCorruptedError(
                forKey: .frame,
                in: container,
                debugDescription: "Invalid frame format, expected [[x,y],[w,h]]"
            )
        }
        frame = rect
        content = try container.decode(NodeContent.self, forKey: .content)
        zIndex = (try? container.decode(Int.self, forKey: .zIndex)) ?? 0
        isLocked = (try? container.decode(Bool.self, forKey: .isLocked)) ?? false
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        // decodeIfPresent is compatible with old data (this field may not be available before v0.24)
        lastModifiedAt = (try? container.decode(Date.self, forKey: .lastModifiedAt)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(frame.frameArray, forKey: .frame)
        try container.encode(content, forKey: .content)
        try container.encode(zIndex, forKey: .zIndex)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastModifiedAt, forKey: .lastModifiedAt)
    }

    // MARK: - Equatable (layout field + content, used by SwiftUI ForEach diff)
    static func == (lhs: CanvasNode, rhs: CanvasNode) -> Bool {
        lhs.id == rhs.id &&
        lhs.frame == rhs.frame &&
        lhs.zIndex == rhs.zIndex &&
        lhs.isLocked == rhs.isLocked &&
        lhs.content == rhs.content
    }
}
