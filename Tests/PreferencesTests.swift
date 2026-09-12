import XCTest
@testable import SessionHub

final class PreferencesTests: XCTestCase {
    @MainActor
    func testPreferencesPersistAndFavoritesTakePriority() throws {
        let suite = "SessionHubTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.toggleFavorite("Website")
        preferences.toggleCollapsed("Website")
        preferences.showDetails = false
        preferences.refreshInterval = 5
        preferences.sortOrder = .recent
        preferences.recordVisit("a", at: Date(timeIntervalSince1970: 100))
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.favorites, ["Website"])
        XCTAssertEqual(restored.collapsed, ["Website"])
        XCTAssertFalse(restored.showDetails)
        XCTAssertEqual(restored.refreshInterval, 5)
        XCTAssertEqual(restored.recent["a"], 100)
        let groups = [ProjectGroup(profileName: "Alpha", sessions: [sampleSession("a", profile: "Alpha")]),
                      ProjectGroup(profileName: "Website", sessions: [])]
        XCTAssertEqual(restored.ordered(groups).map(\.profileName), ["Website", "Alpha"])
        XCTAssertNotNil(groups[1].matching("website"), "Pinned projects remain searchable after their sessions close")
    }

    @MainActor
    func testInvalidIntervalDefaultsSafelyAndRecentHistoryIsBounded() throws {
        let suite = "SessionHubTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-1, forKey: "refreshInterval")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.refreshInterval, 3)
        for index in 0..<150 { preferences.recordVisit("\(index)", at: Date(timeIntervalSince1970: Double(index))) }
        XCTAssertEqual(preferences.recent.count, 100)
        XCTAssertNil(preferences.recent["0"])
        XCTAssertNotNil(preferences.recent["149"])
    }

    @MainActor
    func testDemoActionsDoNotChangeProjectIdentity() async throws {
        let service = DemoSessionService()
        let before = try await service.snapshot()
        let session = try XCTUnwrap(before.sessions.first)
        try await service.rename(session, to: "Renamed")
        try await service.split(session, vertical: true)
        var snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.sessions.first?.profileName, session.profileName)
        XCTAssertEqual(snapshot.sessions.first?.name, "Renamed")
        XCTAssertEqual(snapshot.sessions.count, before.sessions.count + 1)
        let created = try XCTUnwrap(snapshot.sessions.last)
        XCTAssertEqual(created.tabId, session.tabId)
        try await service.close(created)
        snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.sessions.count, before.sessions.count)
    }
}
