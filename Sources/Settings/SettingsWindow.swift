import SwiftUI

/// Global settings window (Story 1.6 implements complete content)
struct SettingsWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environment(appState)
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
            TerminalSettingsView()
                .environment(appState)
                .tabItem { Label("settings.tab.terminal", systemImage: "terminal") }
            AgentsSettingsView()
                .environment(appState)
                .tabItem { Label("settings.tab.agents", systemImage: "person.crop.rectangle.stack") }
            ShortcutsSettingsView()
                .environment(appState)
                .tabItem { Label("settings.tab.shortcuts", systemImage: "keyboard") }
            DataSettingsView()
                .environment(appState)
                .tabItem { Label("settings.tab.data", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 520)
    }
}
