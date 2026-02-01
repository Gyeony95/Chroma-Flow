import SwiftUI

@main
struct ChromaFlowApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("ChromaFlow", systemImage: "drop.fill") {
            PopoverContentView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}
