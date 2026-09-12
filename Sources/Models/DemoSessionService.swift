import Foundation

/// A repeatable UI sandbox: every action affects these sample sessions only.
@MainActor
final class DemoSessionService: SessionService {
    enum Mode: String, CaseIterable { case connected = "Connected", empty = "No sessions", offline = "iTerm2 closed", error = "Connection lost" }
    var mode = Mode.connected
    private var sessions = DemoSessionService.samples
    private var nextID = 10
    private let profiles = ["SessionHub", "Website", "Operations", "Experiments"]
    func isRunning() -> Bool { mode != .offline }
    func disconnect() {}
    func snapshot() async throws -> SessionSnapshot {
        if mode == .error { throw ITerm2APIError.timeout }
        return SessionSnapshot(sessions: mode == .empty ? [] : sessions, profiles: profiles)
    }
    func activate(_ session: ITerm2Bridge.SessionInfo) async throws {
        for index in sessions.indices { sessions[index].isActive = sessions[index].id == session.id }
    }
    func create(profile: String, windowId: String?) async throws {
        mode = .connected
        nextID += 1
        sessions.append(.init(id: "demo-\(nextID)", windowId: windowId ?? "window-\(nextID)", tabId: "tab-\(nextID)",
            tabIndex: sessions.filter { $0.windowId == windowId }.count, sessionIndex: 0, profileName: profile,
            name: "New session", isActive: false, directory: "~/Projects/\(profile)", job: "zsh", windowNumber: 3))
    }
    func rename(_ session: ITerm2Bridge.SessionInfo, to name: String) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionAPIError.invalidName }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].name = name }
    }
    func split(_ session: ITerm2Bridge.SessionInfo, vertical: Bool) async throws {
        nextID += 1
        sessions.append(.init(id: "demo-\(nextID)", windowId: session.windowId, tabId: session.tabId, tabIndex: session.tabIndex,
            sessionIndex: sessions.filter { $0.tabId == session.tabId }.count, profileName: session.profileName,
            name: "New pane", isActive: false, directory: session.directory, job: "zsh", windowNumber: session.windowNumber))
    }
    func close(_ session: ITerm2Bridge.SessionInfo) async throws { sessions.removeAll { $0.id == session.id } }

    static let samples: [ITerm2Bridge.SessionInfo] = [
        .init(id: "demo-1", windowId: "window-1", tabId: "tab-1", tabIndex: 0, sessionIndex: 0, profileName: "SessionHub",
              name: "Build & test", isActive: true, directory: "~/Projects/SessionHub", hostname: "MacBook", job: "swift", gitBranch: "feature/session-tools", windowNumber: 1),
        .init(id: "demo-2", windowId: "window-1", tabId: "tab-2", tabIndex: 1, sessionIndex: 0, profileName: "SessionHub",
              name: "Shell", isActive: false, directory: "~/Projects/SessionHub", hostname: "MacBook", job: "zsh", windowNumber: 1),
        .init(id: "demo-3", windowId: "window-2", tabId: "tab-3", tabIndex: 0, sessionIndex: 0, profileName: "Website",
              name: "Development server", isActive: false, directory: "~/Projects/website", hostname: "MacBook", job: "node", gitBranch: "main", windowNumber: 2),
        .init(id: "demo-4", windowId: "window-2", tabId: "tab-3", tabIndex: 0, sessionIndex: 1, profileName: "Website",
              name: "Café notes", isActive: false, directory: "~/Projects/website/docs", hostname: "MacBook", job: "vim", windowNumber: 2),
        .init(id: "demo-5", windowId: "window-2", tabId: "tab-4", tabIndex: 1, sessionIndex: 0, profileName: "Operations",
              name: "Staging logs", isActive: false, directory: "/srv/app", hostname: "staging", job: "tail", windowNumber: 2)
    ]
}
