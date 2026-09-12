import SwiftUI
import ServiceManagement

@MainActor
struct SettingsView: View {
    @Bindable var controller: AppController
    @State private var login = LoginItemController()
    private var preferences: AppPreferences { controller.store.preferences }

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Sessions") {
                Picker("Refresh every", selection: $preferences.refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Picker("Sort projects", selection: $preferences.sortOrder) {
                    ForEach(AppPreferences.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show folders and branch names", isOn: $preferences.showDetails)
                Toggle("Show session count in menu bar", isOn: $preferences.showSessionCount)
            }
            Section("Appearance") {
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(AppPreferences.Appearance.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Startup & shortcuts") {
                Toggle("Launch at login", isOn: Binding(get: { login.isEnabled }, set: { enabled in Task { await login.setEnabled(enabled) } }))
                    .disabled(login.isBusy || controller.store.isDemo)
                Toggle("Toggle floating panel with ⌃⌥⌘Space", isOn: $preferences.shortcutEnabled)
                    .disabled(controller.store.isDemo)
                if controller.store.isDemo { Text("Startup and global shortcuts are disabled in the demo.").font(.caption).foregroundStyle(.secondary) }
                if let error = login.error ?? controller.shortcutError { Text(error).font(.caption).foregroundStyle(.orange) }
                if login.status == .requiresApproval {
                    Button("Open Login Items Settings") { login.openSettings() }
                }
            }
            Section {
                HStack {
                    Button("Setup & Shortcuts") { controller.showHelp() }
                    Spacer()
                    Text("SessionHub \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .preferredColorScheme(preferences.appearance.colorScheme)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }

}
