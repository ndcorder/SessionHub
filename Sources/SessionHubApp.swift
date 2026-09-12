import SwiftUI

@main
@MainActor
struct SessionHubApp: App {
    @State private var controller: AppController

    init() {
        let demo = CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "SessionHubDemo") as? Bool == true
        _controller = State(initialValue: AppController(demo: demo))
    }

    var body: some Scene {
        MenuBarExtra {
            controller.content().frame(width: 370)
        } label: {
            if controller.store.preferences.showSessionCount {
                Label("\(controller.store.sessionCount)", systemImage: "terminal")
            } else {
                Label(controller.store.isDemo ? "SessionHub Demo" : "SessionHub", systemImage: "terminal")
            }
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { controller.showSettings() }.keyboardShortcut(",")
            }
        }
    }
}
