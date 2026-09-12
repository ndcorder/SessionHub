import Foundation
import AppKit

/// Groups sessions by their iTerm2 profile name, representing a "project".
struct ProjectGroup: Identifiable, Equatable {
    var id: String { profileName }
    let profileName: String
    var sessions: [ITerm2Bridge.SessionInfo]

    var windowIds: Set<String> {
        Set(sessions.map(\.windowId))
    }

    var sessionCount: Int { sessions.count }

    var hasActiveSession: Bool {
        sessions.contains { $0.isActive }
    }

    /// Match every search term across the project and session names.
    /// Keep the original order so results don't jump around while typing.
    func matching(_ query: String) -> ProjectGroup? {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return self }
        if sessions.isEmpty, terms.allSatisfy({ profileName.localizedStandardContains($0) }) { return self }
        let matches = sessions.filter { session in
            let text = "\(profileName) \(session.name) \(session.displayName) \(session.directory) \(session.hostname) \(session.job) \(session.gitBranch)"
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
        guard !matches.isEmpty else { return nil }
        var group = self
        group.sessions = matches
        return group
    }
}

extension ITerm2Bridge.SessionInfo {
    var displayName: String {
        let shell = (name as NSString).lastPathComponent
        if name.isEmpty || ["zsh", "bash", "sh", "fish", "-zsh", "-bash"].contains(shell) {
            return "Session \(sessionIndex + 1)"
        }
        return name
    }
}

/// Main-actor state and coalesced asynchronous refreshes. Failed polls never erase a good snapshot.
@MainActor
@Observable
final class SessionStore {
    private(set) var projectGroups: [ProjectGroup] = []
    private(set) var profiles: [String] = []
    private(set) var isITerm2Running = false
    private(set) var isAPIConnected = false
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false
    private(set) var isPerformingAction = false
    private(set) var lastUpdated: Date?
    var connectionMessage: String?
    var actionError: String?
    var notice: String?

    let preferences: AppPreferences
    @ObservationIgnored private let service: SessionService
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = UUID()
    @ObservationIgnored private var refreshAfterAction = false

    init(service: SessionService? = nil, preferences: AppPreferences? = nil) {
        self.service = service ?? ITerm2Bridge()
        self.preferences = preferences ?? AppPreferences()
    }

    var isDemo: Bool { service is DemoSessionService }

    func setDemoMode(_ mode: DemoSessionService.Mode) {
        (service as? DemoSessionService)?.mode = mode
        refresh()
    }

    func launchITerm() {
        guard !isDemo else { setDemoMode(.connected); return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") else {
            actionError = "Install iTerm2 to use SessionHub. The setup guide has the download link."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.actionError = error.localizedDescription }
                self?.refresh()
            }
        }
    }

    var sessions: [ITerm2Bridge.SessionInfo] { projectGroups.flatMap(\.sessions) }
    var sessionCount: Int { sessions.count }
    var canAct: Bool { isAPIConnected && !isPerformingAction }

    func startPolling(interval: TimeInterval = 3) {
        stopPolling()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = min(1, interval / 5)
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        refreshGeneration = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        refreshAfterAction = false
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard !isRefreshing else { return refreshTask }
        isRefreshing = true
        let generation = refreshGeneration
        refreshTask = Task {
            defer {
                if generation == refreshGeneration {
                    isRefreshing = false
                    refreshTask = nil
                    if refreshAfterAction {
                        refreshAfterAction = false
                        refresh()
                    }
                }
            }
            isITerm2Running = service.isRunning()
            guard isITerm2Running else {
                service.disconnect()
                isAPIConnected = false
                projectGroups = []
                profiles = []
                connectionMessage = nil
                hasLoaded = true
                return
            }
            do {
                let snapshot = try await service.snapshot()
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                let nextGroups = Self.groupByProfile(snapshot.sessions)
                if projectGroups != nextGroups { projectGroups = nextGroups }
                if profiles != snapshot.profiles { profiles = snapshot.profiles }
                isAPIConnected = true
                connectionMessage = nil
                lastUpdated = Date()
            } catch {
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                isAPIConnected = false
                connectionMessage = Self.message(for: error)
            }
            hasLoaded = true
        }
        return refreshTask
    }

    func reconnect() {
        stopPolling()
        service.disconnect()
        startPolling(interval: preferences.refreshInterval)
    }

    @discardableResult
    func switchToSession(_ session: ITerm2Bridge.SessionInfo) -> Task<Void, Never>? {
        runAction {
            try await self.service.activate(session)
            self.preferences.recordVisit(session.id)
        }
    }

    @discardableResult
    func createTab(forProfile profile: String, inWindowId windowId: String) -> Task<Void, Never>? {
        runAction { try await self.service.create(profile: profile, windowId: windowId) }
    }

    @discardableResult
    func createWindow(withProfile profile: String) -> Task<Void, Never>? {
        runAction { try await self.service.create(profile: profile, windowId: nil) }
    }

    func renameSession(_ session: ITerm2Bridge.SessionInfo, to name: String) async -> Bool {
        await performAction {
            try await self.service.rename(session, to: name)
        }
    }

    @discardableResult
    func splitSession(_ session: ITerm2Bridge.SessionInfo, vertical: Bool) -> Task<Void, Never>? {
        runAction { try await self.service.split(session, vertical: vertical) }
    }

    @discardableResult
    func closeSession(_ session: ITerm2Bridge.SessionInfo) -> Task<Void, Never>? {
        runAction { try await self.service.close(session) }
    }

    private func runAction(_ action: @escaping () async throws -> Void) -> Task<Void, Never>? {
        guard canAct else { return nil }
        // Set this before scheduling the task to coalesce double clicks.
        isPerformingAction = true
        return Task { _ = await executeAction(action) }
    }

    private func performAction(_ action: @escaping () async throws -> Void) async -> Bool {
        guard canAct else { return false }
        isPerformingAction = true
        return await executeAction(action)
    }

    private func executeAction(_ action: () async throws -> Void) async -> Bool {
        defer {
            isPerformingAction = false
            if isRefreshing { refreshAfterAction = true } else { refresh() }
        }
        actionError = nil
        do { try await action(); return true }
        catch { actionError = Self.message(for: error); return false }
    }

    static func groupByProfile(_ sessions: [ITerm2Bridge.SessionInfo]) -> [ProjectGroup] {
        Dictionary(grouping: sessions, by: \.profileName).map {
            ProjectGroup(profileName: $0.key, sessions: $0.value)
        }.sorted { $0.profileName.localizedStandardCompare($1.profileName) == .orderedAscending }
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? ITerm2APIError { return apiError.description }
        return error.localizedDescription
    }
}
