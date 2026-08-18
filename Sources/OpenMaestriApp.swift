import OSLog
import SwiftUI

private let appLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "open-maestri", category: "App")

@main
struct OpenMaestriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var l10n = LocalizationManager.shared
    @State private var showRoutines = false
    @State private var showCreateWorkspace = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(\.locale, l10n.locale)
                .task {
                    // Bind appState to AppDelegate for access on exit
                    appDelegate.appState = appState
                    await appState.loadOnLaunch()
                    // Synchronize language settings to LocalizationManager after startup
                    LocalizationManager.shared.sync(from: appState.preferences.language)
                    appState.startAutosave()
                    BackupManager.shared.startHourlyBackups()
                    // InterAgentServer started at AppDelegate.applicationDidFinishLaunching
                    do {
                        try RoutineScheduler.shared.loadRoutines()
                    } catch {
                        appLogger.error("Failed to load routines on launch: \(error.localizedDescription)")
                    }
                    // Spotlight: Rebuild index
                    let wsNodes = Dictionary(
                        uniqueKeysWithValues: appState.workspaces.map { ws in
                            (ws.id, ws.nodes)
                        }
                    )
                    SpotlightIndexer.shared.rebuildIndex(
                        workspaces: appState.manifest.workspaces,
                        nodes: wsNodes
                    )
                    // Configure window style
                    WindowStateObserver.shared.configureMainWindow()
                }
                .onDisappear {
                    // Note: The main cleanup logic has been moved to AppDelegate.applicationShouldTerminate
                    // This is only used as a backup cleanup when the window is closed (not triggered when exiting the scene)
                    appState.stopAutosave()
                    BackupManager.shared.stopBackups()
                }
                .sheet(isPresented: $showRoutines) {
                    RoutineManagerView()
                        .environment(appState)
                        .environment(\.locale, l10n.locale)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // MARK: File menu
            CommandGroup(after: .newItem) {
                Button("menu.app.new_workspace") {
                    NotificationCenter.default.post(name: .showCreateWorkspace, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("menu.app.routines") {
                    showRoutines = true
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }

            // MARK: View menu
            CommandMenu("menu.view") {
                Button("menu.view.toggle_zoom") {
                    NotificationCenter.default.post(name: .toggleCanvasZoom, object: nil)
                }
                .keyboardShortcut("\\", modifiers: .command)

                Button("menu.view.floor_overview") {
                    NotificationCenter.default.post(name: .showFloorOverview, object: nil)
                }
                .keyboardShortcut("\\", modifiers: [.command, .shift])

                Divider()

                Button("menu.view.zoom_in") {
                    NotificationCenter.default.post(name: .canvasZoomIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("menu.view.zoom_out") {
                    NotificationCenter.default.post(name: .canvasZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("menu.view.reset_zoom") {
                    NotificationCenter.default.post(name: .canvasZoomReset, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button("menu.view.filter_search") {
                    NotificationCenter.default.post(name: .showCanvasFilter, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Divider()

                Button("menu.view.open_in_editor") {
                    NotificationCenter.default.post(name: .openInEditor, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            // MARK: Window menu supplement
            CommandGroup(after: .windowSize) {
                Button("menu.view.next_workspace") {
                    NotificationCenter.default.post(name: .nextWorkspace, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("menu.view.prev_workspace") {
                    NotificationCenter.default.post(name: .prevWorkspace, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Divider()

                Button("menu.view.next_terminal") {
                    NotificationCenter.default.post(name: .nextTerminal, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: .control)

                Button("menu.view.prev_terminal") {
                    NotificationCenter.default.post(name: .prevTerminal, object: nil)
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
        }

        Settings {
            SettingsWindow()
                .environment(appState)
                .environment(\.locale, l10n.locale)
        }
    }
}
