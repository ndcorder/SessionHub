import SwiftUI

@MainActor
struct HelpView: View {
    @Bindable var store: SessionStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Make room for your projects", systemImage: "terminal").font(.title2.bold())
                    Text("SessionHub brings your iTerm2 windows, tabs, and panes into one searchable list.")
                        .foregroundStyle(.secondary)
                }
                GroupBox("Connect iTerm2") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Open iTerm2 → Settings → General → Magic.")
                        Text("2. Turn on Enable Python API.")
                        Text("3. Allow SessionHub if iTerm2 asks for API access, then refresh.")
                        HStack {
                            Button("Open iTerm2") { store.launchITerm() }
                            Button("Reconnect") { store.reconnect() }
                        }
                        Link("Download iTerm2", destination: URL(string: "https://iterm2.com/downloads.html")!)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
                GroupBox("Organize your sessions") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Create an iTerm2 profile for each project. Its name becomes a group here, and its working directory opens with every new session.")
                        Text("Pin your frequent projects. Collapse the others. Right-click a session to rename, split, copy its directory, or close it.")
                        Text("Folder and host details depend on what iTerm2 knows. Remote details work best with iTerm2 shell integration. Branch names appear when your shell sets user.gitBranch.")
                        Link("iTerm2 shell integration", destination: URL(string: "https://iterm2.com/documentation-shell-integration.html")!)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
                GroupBox("Keyboard shortcuts") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        shortcut("⌃⌥⌘Space", "Show or hide the floating panel")
                        shortcut("⌘F", "Focus search")
                        shortcut("↑ / ↓", "Choose a search result")
                        shortcut("Return", "Open the selected session")
                        shortcut("⌘1–9", "Open a visible session")
                        shortcut("Escape", "Clear search or cancel renaming")
                        shortcut("⌘R", "Refresh sessions")
                        shortcut("⌘,", "Open settings")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                }
                Text("SessionHub talks to iTerm2 on your Mac. It does not read terminal scrollback or send your session list to a server.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(width: 500, height: 560)
            .preferredColorScheme(store.preferences.appearance.colorScheme)
    }
    private func shortcut(_ keys: String, _ description: String) -> some View {
        GridRow { Text(keys).font(.system(.callout, design: .monospaced)); Text(description).font(.callout) }
    }
}
