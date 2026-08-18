import AppKit
import SwiftUI

/// Monitor the full-screen state of the main window for SwiftUI views to respond to layout changes
@Observable
@MainActor
final class WindowStateObserver {
    static let shared = WindowStateObserver()

    /// Whether the window is in full screen (maximized) state
    var isFullScreen: Bool = false

    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []

    private init() {
        notificationObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.isFullScreen = true }
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.isFullScreen = false }
            },
        ]
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Configure main window style (transparent title bar, hidden title)
    func configureMainWindow() {
        guard let window = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Let the content extend into the title bar area
        window.styleMask.insert(.fullSizeContentView)
    }
}
