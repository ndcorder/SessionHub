import SwiftUI

@MainActor
struct MenuBarView: View {
    @Bindable var store: SessionStore
    var isPanel = false
    var openPanel: () -> Void = {}
    var openSettings: () -> Void = {}
    var openHelp: () -> Void = {}
    @State private var searchText = ""
    @State private var pinnedOnly = false
    @State private var selectedID: String?
    @State private var renamingSession: ITerm2Bridge.SessionInfo?
    @State private var renameText = ""
    @State private var closingSession: ITerm2Bridge.SessionInfo?
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var groups: [ProjectGroup] {
        var all = store.projectGroups
        let open = Set(all.map(\.profileName))
        for profile in store.profiles where store.preferences.favorites.contains(profile) && !open.contains(profile) {
            all.append(ProjectGroup(profileName: profile, sessions: []))
        }
        return store.preferences.ordered(all).filter {
            !pinnedOnly || store.preferences.favorites.contains($0.profileName)
        }.compactMap { $0.matching(searchText) }
    }
    private var visibleSessions: [ITerm2Bridge.SessionInfo] {
        groups.filter { isSearching || !store.preferences.collapsed.contains($0.profileName) }.flatMap(\.sessions)
    }
    private var selectedSession: ITerm2Bridge.SessionInfo? {
        visibleSessions.first { $0.id == selectedID } ?? visibleSessions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.actionError {
                messageBanner(error, symbol: "exclamationmark.circle", dismiss: { store.actionError = nil })
            }
            if !store.hasLoaded {
                stateView("Connecting to iTerm2", detail: "Looking for your projects and sessions…", symbol: "terminal")
                    .overlay(alignment: .bottom) { ProgressView().controlSize(.small).padding(.bottom, 8) }
            } else if !store.isITerm2Running {
                stateView("Your terminals, in one place", detail: "Open iTerm2 to find your sessions here, organized by profile.", symbol: "terminal")
                Button("Open iTerm2") { store.launchITerm() }.buttonStyle(.borderedProminent).padding(.bottom, 20)
            } else if !store.isAPIConnected && store.projectGroups.isEmpty {
                stateView("Connect to iTerm2", detail: store.connectionMessage ?? "Enable the Python API to show your sessions.", symbol: "antenna.radiowaves.left.and.right")
                HStack {
                    Button("Setup Guide", action: openHelp)
                    Button("Try Again") { store.reconnect() }
                }.buttonStyle(.bordered).padding(.bottom, 20)
            } else {
                if !store.isAPIConnected {
                    messageBanner("Connection lost. Showing the last session list; reconnecting…", symbol: "wifi.exclamationmark")
                }
                searchBar
                filterBar
                if store.sessionCount == 0 && groups.isEmpty {
                    stateView("Start a session", detail: "Choose a profile from New to open a project window.", symbol: "plus.rectangle.on.folder")
                } else if groups.isEmpty {
                    stateView(isSearching ? "No matching sessions" : "No pinned projects",
                              detail: isSearching ? "Try a project, session, folder, host, or job name." : "Use the pin beside a project to keep it at the top.",
                              symbol: isSearching ? "magnifyingglass" : "pin")
                    if isSearching { Button("Clear Search") { searchText = "" }.padding(.bottom, 16) }
                } else {
                    sessionList
                }
            }
            Divider()
            SessionFooterView(store: store, find: { searchFocused = true }, openPanel: openPanel, openSettings: openSettings, openHelp: openHelp)
        }
        .frame(minWidth: 350, maxWidth: .infinity)
        .background(.background)
        .preferredColorScheme(store.preferences.appearance.colorScheme)
        .onChange(of: visibleSessions.map(\.id)) { _, ids in
            if !ids.contains(selectedID ?? "") { selectedID = ids.first }
        }
        .onChange(of: searchText) { _, _ in selectedID = visibleSessions.first?.id }
        .alert("Close this session?", isPresented: Binding(get: { closingSession != nil }, set: { if !$0 { closingSession = nil } })) {
            Button("Cancel", role: .cancel) { closingSession = nil }
            Button("Close Session", role: .destructive) {
                if let session = closingSession { store.closeSession(session) }
                closingSession = nil
            }
        } message: {
            Text("Closing “\(closingSession?.displayName ?? "")” can stop its running programs. iTerm2 may ask for an additional confirmation.")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal.fill").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("SessionHub").font(.system(.headline, design: .rounded))
                Text(store.isDemo ? "Demo • sample sessions" : "\(store.sessionCount) sessions in \(store.projectGroups.count) projects")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isPanel {
                Button(action: openPanel) { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless).help("Open floating panel (⌃⌥⌘Space)")
                    .accessibilityLabel("Open floating panel")
            }
            newSessionMenu
        }
        .padding(14)
    }

    private var newSessionMenu: some View {
        Menu {
            Menu("New Window") {
                ForEach(store.profiles, id: \.self) { profile in
                    Button(profile) { store.createWindow(withProfile: profile) }
                }
            }
            if let window = store.sessions.first(where: \.isActive)?.windowId ?? store.sessions.first?.windowId {
                Menu("New Tab in Current Window") {
                    ForEach(store.profiles, id: \.self) { profile in
                        Button(profile) { store.createTab(forProfile: profile, inWindowId: window) }
                    }
                }
            }
        } label: { Label("New", systemImage: "plus") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!store.canAct || store.profiles.isEmpty)
        .accessibilityLabel("New session")
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search sessions, projects, folders…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if let selectedSession { store.switchToSession(selectedSession) } }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onExitCommand { searchText = "" }
                .accessibilityLabel("Search sessions")
            if !searchText.isEmpty {
                Button { searchText = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Clear search (Escape)").accessibilityLabel("Clear search")
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.top, 12)
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f").hidden().accessibilityHidden(true)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Button { pinnedOnly = false } label: { Text("All").font(.caption.weight(.medium)) }
                .buttonStyle(.plain).foregroundStyle(pinnedOnly ? .secondary : .primary)
                .accessibilityAddTraits(pinnedOnly ? [] : [.isSelected])
            Text("/").foregroundStyle(.tertiary)
            Button { pinnedOnly = true } label: { Label("Pinned", systemImage: "pin.fill").font(.caption.weight(.medium)) }
                .buttonStyle(.plain).foregroundStyle(pinnedOnly ? .primary : .secondary)
                .accessibilityAddTraits(pinnedOnly ? [.isSelected] : [])
            Spacer()
            if isSearching { Text("\(visibleSessions.count) matches").font(.caption2).foregroundStyle(.secondary) }
            Menu {
                Picker("Sort projects", selection: Bindable(store.preferences).sortOrder) {
                    ForEach(AppPreferences.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Expand All") { store.preferences.collapsed = [] }
                Button("Collapse All") { store.preferences.collapsed = Set(store.projectGroups.map(\.profileName)) }
            } label: { Image(systemName: "arrow.up.arrow.down") }
            .menuStyle(.borderlessButton).fixedSize().help("Sort and organize projects").accessibilityLabel("Sort projects")
        }
        .padding(.horizontal, 15).padding(.vertical, 10)
    }

    private var sessionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(groups) { group in projectGroup(group) }
                }
                .padding(.bottom, 10)
            }
            .frame(height: isPanel ? nil : min(420, max(90, CGFloat(visibleSessions.count * (store.preferences.showDetails ? 49 : 32) + groups.count * 38))))
            .frame(maxHeight: isPanel ? .infinity : nil)
            .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func projectGroup(_ group: ProjectGroup) -> some View {
        let expanded = isSearching || !store.preferences.collapsed.contains(group.profileName)
        let pinned = store.preferences.favorites.contains(group.profileName)
        return VStack(spacing: 2) {
            HStack(spacing: 7) {
                Button { store.preferences.toggleCollapsed(group.profileName) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        Image(systemName: "folder.fill").foregroundStyle(colorForProfile(group.profileName))
                        Text(group.profileName).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Text("\(group.sessionCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(isSearching)
                    .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(group.profileName), \(group.sessionCount) sessions")
                Button { store.preferences.toggleFavorite(group.profileName) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin").foregroundStyle(pinned ? Color.accentColor : .secondary)
                }.buttonStyle(.borderless).help(pinned ? "Unpin project" : "Pin project")
                    .accessibilityLabel("\(pinned ? "Unpin" : "Pin") \(group.profileName)")
                Button {
                    if let window = group.sessions.first?.windowId { store.createTab(forProfile: group.profileName, inWindowId: window) }
                    else { store.createWindow(withProfile: group.profileName) }
                } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).disabled(!store.canAct)
                    .help("New session in \(group.profileName)").accessibilityLabel("New session in \(group.profileName)")
            }
            .font(.caption).padding(.horizontal, 14).padding(.vertical, 5)
            if expanded {
                if group.sessions.isEmpty { Text("No open sessions").font(.caption).foregroundStyle(.secondary).padding(.vertical, 6) }
                ForEach(group.sessions) { session in sessionRow(session).id(session.id) }
            }
        }
    }

    private func sessionRow(_ session: ITerm2Bridge.SessionInfo) -> some View {
        Group {
            if renamingSession?.id == session.id {
                HStack {
                    TextField("Session name", text: $renameText).textFieldStyle(.roundedBorder).focused($renameFocused)
                        .task {
                            // Let the context menu restore focus before focusing the editor.
                            await Task.yield()
                            renameFocused = true
                        }
                        .onSubmit { saveRename(session) }
                        .onExitCommand { renamingSession = nil }
                        .accessibilityLabel("Session name")
                    Button("Save") { saveRename(session) }.disabled(!store.canAct || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { renamingSession = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Cancel rename")
                }.padding(.horizontal, 24).padding(.vertical, 5)
            } else {
                Button { selectedID = session.id; store.switchToSession(session) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(session.isActive ? Color.green : Color.secondary.opacity(0.25)).frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(session.displayName).font(.system(.callout, weight: session.isActive ? .semibold : .regular)).lineLimit(1)
                                Spacer(minLength: 4)
                                if !session.job.isEmpty { Text(session.job).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            if store.preferences.showDetails {
                                HStack(spacing: 6) {
                                    Text(session.directory.isEmpty ? "Window \(session.windowNumber) • Tab \(session.tabIndex + 1)" : session.directory)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 2)
                                    if !session.gitBranch.isEmpty {
                                        Label(session.gitBranch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
                                    }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if let index = visibleSessions.firstIndex(where: { $0.id == session.id }), index < 9 {
                            Text("⌘\(index + 1)").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, store.preferences.showDetails ? 7 : 6)
                    .contentShape(Rectangle())
                    .background(selectedID == session.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).disabled(!store.canAct)
                .modifier(SessionShortcut(index: visibleSessions.firstIndex { $0.id == session.id }))
                .padding(.horizontal, 12)
                .help("\(session.name)\n\(session.profileName) • Window \(session.windowNumber) • Tab \(session.tabIndex + 1) • Pane \(session.sessionIndex + 1)\n\(session.hostname) \(session.directory)")
                .accessibilityLabel("\(session.displayName), \(session.isActive ? "active session, " : "")\(session.profileName), tab \(session.tabIndex + 1), pane \(session.sessionIndex + 1)")
                .contextMenu {
                    Button("Rename…") { renameText = session.name; renamingSession = session }
                    Button("New Tab in \(session.profileName)") { store.createTab(forProfile: session.profileName, inWindowId: session.windowId) }
                    Divider()
                    Button("Split Right") { store.splitSession(session, vertical: true) }
                    Button("Split Below") { store.splitSession(session, vertical: false) }
                    Divider()
                    Button("Copy Directory") { copy(session.directory) }.disabled(session.directory.isEmpty)
                    Button("Copy Session ID") { copy(session.id) }
                    Divider()
                    Button("Close Session…", role: .destructive) { closingSession = session }
                }
            }
        }
    }

    private func messageBanner(_ message: String, symbol: String, dismiss: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error") }
        }.padding(12).background(Color.orange.opacity(0.08))
    }
    private func stateView(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.vertical, 26)
    }
    private func moveSelection(_ step: Int) {
        guard !visibleSessions.isEmpty else { return }
        let current = visibleSessions.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : visibleSessions.count)
        selectedID = visibleSessions[min(max(0, current + step), visibleSessions.count - 1)].id
    }
    private func saveRename(_ session: ITerm2Bridge.SessionInfo) {
        Task { if await store.renameSession(session, to: renameText) { renamingSession = nil } }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func colorForProfile(_ name: String) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .indigo, .teal]
        let hash = name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

private struct SessionShortcut: ViewModifier {
    let index: Int?
    @ViewBuilder func body(content: Content) -> some View {
        if let index, index < 9 { content.keyboardShortcut(KeyEquivalent(Character(String(index + 1)))) }
        else { content }
    }
}

/// Keep polling progress and timestamps out of the session list's observation scope.
@MainActor
private struct SessionFooterView: View {
    @Bindable var store: SessionStore
    var find: () -> Void
    var openPanel: () -> Void
    var openSettings: () -> Void
    var openHelp: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button { store.refresh() } label: {
                if store.isRefreshing { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                else { Image(systemName: "arrow.clockwise") }
            }.buttonStyle(.plain).keyboardShortcut("r").help("Refresh (⌘R)").accessibilityLabel("Refresh")
            HStack(spacing: 5) {
                Circle().fill(store.isAPIConnected ? Color.green : Color.orange).frame(width: 5, height: 5)
                Text(store.isAPIConnected ? "Connected" : (store.isITerm2Running ? "Reconnecting" : "Offline")).font(.caption2).foregroundStyle(.secondary)
            }.help(store.lastUpdated.map { "Last updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Waiting for the first update")
            Spacer()
            if store.isDemo {
                Menu("Demo") {
                    ForEach(DemoSessionService.Mode.allCases, id: \.self) { mode in Button(mode.rawValue) { store.setDemoMode(mode) } }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            Menu {
                Button("Find Session", action: find).keyboardShortcut("f")
                Button("Floating Panel", action: openPanel)
                Button("Settings…", action: openSettings).keyboardShortcut(",")
                Button("Setup & Shortcuts", action: openHelp)
                Divider()
                Button("Reconnect to iTerm2") { store.reconnect() }
                Button("Quit SessionHub") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("More actions")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

}
