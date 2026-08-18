import AppKit

/// 8-directional Resize enumeration for use with CanvasInteractionHandler and hit testing.
/// Originally defined in the deleted BaseNodeView (NSView subclass), now moved to this separate file.
enum ResizeEdge {
    case right, left, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    /// macOS native resize cursor (loaded from system cursor resources)
    var cursor: NSCursor {
        switch self {
        case .right, .left:
            return .resizeLeftRight
        case .top, .bottom:
            return .resizeUpDown
        case .topLeft, .bottomRight:
            return ResizeCursors.nwse
        case .topRight, .bottomLeft:
            return ResizeCursors.nesw
        }
    }
}

// MARK: - System native diagonal Resize cursor

/// Load native diagonal resize cursor from macOS system cursor resource directory.
/// Path: HIServices.framework/Resources/cursors/
private enum ResizeCursors {
    /// ↘↖ Diagonal (upper left-lower right / NW-SE)
    static let nwse: NSCursor = loadSystemCursor(name: "resizenorthwestsoutheast", hotSpot: NSPoint(x: 11, y: 11))
    /// ↗↙ Diagonal (upper right-lower left / NE-SW)
    static let nesw: NSCursor = loadSystemCursor(name: "resizenortheastsouthwest", hotSpot: NSPoint(x: 11, y: 11))

    private static func loadSystemCursor(name: String, hotSpot: NSPoint) -> NSCursor {
        let basePath = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/Resources/cursors"
        let cursorPath = "\(basePath)/\(name)/cursor.pdf"

        if let image = NSImage(contentsOfFile: cursorPath) {
            return NSCursor(image: image, hotSpot: hotSpot)
        }

        // Downgrade: resizeLeftRight using public API (should not happen)
        return .crosshair
    }
}
