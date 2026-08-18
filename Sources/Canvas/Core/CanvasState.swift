import OSLog
import Foundation
import CoreGraphics

/// Canvas state, @MainActor forces all modifications to the main thread (Epic 2 implementation)
@MainActor
@Observable
final class CanvasState {
    var origin: CGPoint = Constants.canvasInitialOrigin
    var zoom: CGFloat = 1.0
    var selectedNodeIds: Set<UUID> = []

    private let logger = Logger.make(category: "CanvasState")
}
