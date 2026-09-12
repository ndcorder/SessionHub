import Foundation
import AppKit
import OSLog

/// Unified logging is bounded by macOS. Never log session names, paths, or payloads.
enum SHLog {
    private static let logger = Logger(subsystem: "com.sessionhub.app", category: "connection")
    static func log(_ message: String) { logger.info("\(message, privacy: .private)") }
}

struct SessionSnapshot {
    var sessions: [ITerm2Bridge.SessionInfo]
    var profiles: [String]
}

@MainActor
protocol SessionService {
    func isRunning() -> Bool
    func snapshot() async throws -> SessionSnapshot
    func disconnect()
    func activate(_ session: ITerm2Bridge.SessionInfo) async throws
    func create(profile: String, windowId: String?) async throws
    func rename(_ session: ITerm2Bridge.SessionInfo, to name: String) async throws
    func split(_ session: ITerm2Bridge.SessionInfo, vertical: Bool) async throws
    func close(_ session: ITerm2Bridge.SessionInfo) async throws
}

/// Communicates only through the local iTerm2 API; never reads terminal scrollback.
final class ITerm2Bridge: SessionService {
    struct SessionInfo: Identifiable, Equatable, Codable {
        let id: String
        let windowId: String
        let tabId: String
        let tabIndex: Int
        let sessionIndex: Int
        let profileName: String
        var name: String
        var isActive: Bool
        var directory: String = ""
        var hostname: String = ""
        var job: String = ""
        var gitBranch: String = ""
        var windowNumber: Int32 = 0
    }

    private let client: ITerm2APIClient
    init(client: ITerm2APIClient = ITerm2APIClient()) { self.client = client }

    func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").isEmpty
    }
    func disconnect() { client.disconnect() }

    func snapshot() async throws -> SessionSnapshot {
        async let profiles = client.profiles()
        let windows = try await client.listSessions()
        var activeId: String?
        if !windows.isEmpty {
            do { activeId = try await client.variables(sessionId: "active", names: ["id"])["id"] }
            catch SessionAPIError.rejected(_, let status) where status == 1 { activeId = nil }
        }
        var summaries: [SessionInfo] = []
        for window in windows {
            for (tabIndex, tab) in window.tabs.enumerated() {
                for (sessionIndex, session) in tab.sessions.enumerated() {
                    summaries.append(SessionInfo(id: session.uniqueId, windowId: window.windowId, tabId: tab.tabId,
                                                 tabIndex: tabIndex, sessionIndex: sessionIndex, profileName: "",
                                                 name: session.title, isActive: session.uniqueId == activeId,
                                                 windowNumber: window.windowNumber))
                }
            }
        }
        // Bound concurrency so a large session list cannot flood the socket.
        var sessions: [SessionInfo] = []
        for start in stride(from: 0, to: summaries.count, by: 8) {
            let batch = Array(summaries[start..<min(start + 8, summaries.count)])
            let enriched = try await withThrowingTaskGroup(of: (Int, SessionInfo?).self) { group in
                for (index, session) in batch.enumerated() {
                    group.addTask { [client] in
                        do {
                            let values = try await client.variables(sessionId: session.id,
                                names: ["profileName", "path", "hostname", "jobName", "user.gitBranch"])
                            let result = SessionInfo(id: session.id, windowId: session.windowId, tabId: session.tabId,
                                tabIndex: session.tabIndex, sessionIndex: session.sessionIndex,
                                profileName: values["profileName"] ?? "Default", name: session.name, isActive: session.isActive,
                                directory: values["path"] ?? "", hostname: values["hostname"] ?? "", job: values["jobName"] ?? "",
                                gitBranch: values["user.gitBranch"] ?? "", windowNumber: session.windowNumber)
                            return (index, result)
                        } catch SessionAPIError.rejected(_, let status) where status == 1 {
                            return (index, nil) // A session may close between list and metadata queries.
                        }
                    }
                }
                var result: [(Int, SessionInfo?)] = []
                for try await value in group { result.append(value) }
                return result.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            sessions.append(contentsOf: enriched)
        }
        return try await SessionSnapshot(sessions: sessions, profiles: profiles)
    }

    func activate(_ session: SessionInfo) async throws {
        try await client.activate(sessionId: session.id)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first?.activate()
    }
    func create(profile: String, windowId: String?) async throws {
        try await client.createTab(profileName: profile, windowId: windowId)
    }
    func rename(_ session: SessionInfo, to name: String) async throws {
        try await client.renameSession(sessionId: session.id, name: name)
    }
    func split(_ session: SessionInfo, vertical: Bool) async throws {
        try await client.splitPane(sessionId: session.id, profile: session.profileName, vertical: vertical)
    }
    func close(_ session: SessionInfo) async throws { try await client.closeSession(sessionId: session.id) }
}
