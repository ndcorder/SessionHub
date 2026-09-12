import XCTest
@testable import SessionHub

func sampleSession(_ id: String = "one", profile: String = "Project", name: String = "Server") -> ITerm2Bridge.SessionInfo {
    ITerm2Bridge.SessionInfo(id: id, windowId: "window", tabId: "tab", tabIndex: 0, sessionIndex: 0,
                           profileName: profile, name: name, isActive: true, directory: "/projects/café", job: "node")
}

@MainActor
final class FakeSessionService: SessionService {
    var running = true
    var next = SessionSnapshot(sessions: [sampleSession()], profiles: ["Project"])
    var error: Error?
    var actionError: Error?
    var snapshotCalls = 0
    var holdSnapshot = false
    var heldSnapshot: CheckedContinuation<SessionSnapshot, Error>?
    var onSnapshot: (() -> Void)?
    var disconnected = false

    func isRunning() -> Bool { running }
    func disconnect() { disconnected = true }
    func snapshot() async throws -> SessionSnapshot {
        snapshotCalls += 1
        if holdSnapshot {
            return try await withCheckedThrowingContinuation { continuation in
                heldSnapshot = continuation
                onSnapshot?()
            }
        }
        onSnapshot?()
        if let error { throw error }
        return next
    }
    func activate(_ session: ITerm2Bridge.SessionInfo) async throws { if let actionError { throw actionError } }
    func create(profile: String, windowId: String?) async throws { if let actionError { throw actionError } }
    func rename(_ session: ITerm2Bridge.SessionInfo, to name: String) async throws { if let actionError { throw actionError } }
    func split(_ session: ITerm2Bridge.SessionInfo, vertical: Bool) async throws { if let actionError { throw actionError } }
    func close(_ session: ITerm2Bridge.SessionInfo) async throws { if let actionError { throw actionError } }
}

final class SessionTests: XCTestCase {
    @MainActor
    func testFailedRefreshRetainsSnapshotAndSuccessfulTimestamp() async {
        let service = FakeSessionService()
        let store = SessionStore(service: service)
        await store.refresh()?.value
        let updated = store.lastUpdated
        service.error = ITerm2APIError.timeout
        await store.refresh()?.value
        XCTAssertEqual(store.sessionCount, 1)
        XCTAssertEqual(store.lastUpdated, updated)
        XCTAssertFalse(store.isAPIConnected)
        XCTAssertFalse(store.canAct)
        XCTAssertNotNil(store.connectionMessage)
        service.error = nil
        await store.refresh()?.value
        XCTAssertTrue(store.isAPIConnected)
        XCTAssertNil(store.connectionMessage)
        service.running = false
        await store.refresh()?.value
        XCTAssertEqual(store.sessionCount, 0)
        XCTAssertTrue(service.disconnected)
    }

    @MainActor
    func testRefreshesCoalesceAndStoppedWorkCannotPublish() async {
        let service = FakeSessionService()
        service.holdSnapshot = true
        let began = expectation(description: "Snapshot began")
        service.onSnapshot = { began.fulfill() }
        let store = SessionStore(service: service)
        let first = store.refresh()
        _ = store.refresh()
        _ = store.refresh()
        await fulfillment(of: [began], timeout: 1)
        XCTAssertEqual(service.snapshotCalls, 1)
        store.stopPolling()
        service.heldSnapshot?.resume(returning: service.next)
        await first?.value
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.sessionCount, 0)
    }

    @MainActor
    func testRenameFailureIsVisibleAndDoesNotReportSuccess() async {
        let service = FakeSessionService()
        let store = SessionStore(service: service)
        await store.refresh()?.value
        service.actionError = SessionAPIError.rejected(operation: "Rename", status: 1)
        let renamed = await store.renameSession(sampleSession(), to: "New name")
        XCTAssertFalse(renamed)
        XCTAssertNotNil(store.actionError)
        XCTAssertFalse(store.isPerformingAction)
        await store.refresh()?.value
    }

    func testRenameUsesMethodAndEscapesNameInsteadOfChangingProfile() throws {
        let name = "Build \\\"quoted\\\"\n世界"
        let message = try ITerm2Messages.rename(sessionId: "session-id", name: name)
        let envelope = try ITerm2Messages.decodeResponse(message.data)
        XCTAssertEqual(envelope.fieldNumber, 132)
        let body = try MessageFields(envelope.payload)
        let receiver = try MessageFields(XCTUnwrap(body.bytes[7]?.first))
        XCTAssertEqual(try receiver.strings(1), ["session-id"])
        let invocation = try XCTUnwrap(body.strings(5).first)
        let prefix = "iterm2.set_name(name: "
        XCTAssertTrue(invocation.hasPrefix(prefix))
        let json = String(invocation.dropFirst(prefix.count).dropLast())
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(json.utf8)), name)
        XCTAssertNil(body.bytes[3], "No profile property assignment")
    }

    func testActionStatusAndCloseRequestPreserveConfirmation() async throws {
        let socket = FakeTransport()
        socket.onRequest = { _, field, data in
            if field == 131 {
                let close = try MessageFields(data)
                XCTAssertEqual(close.integers[4], [0])
            }
            var response = ProtobufEncoder()
            response.writeInt64(1, value: 1)
            return response.data
        }
        let client = ITerm2APIClient { socket }
        do {
            try await client.activate(sessionId: "missing")
            XCTFail("A response envelope alone is not success")
        } catch { XCTAssertTrue(error is SessionAPIError) }
        do {
            try await client.closeSession(sessionId: "missing")
            XCTFail("A missing session is not a successful close")
        } catch { XCTAssertTrue(error is SessionAPIError) }
        client.disconnect()
    }

    func testVariablesDecodeJSONStringAndUnavailableValues() async throws {
        let socket = FakeTransport()
        socket.onRequest = { _, _, _ in
            var body = ProtobufEncoder()
            body.writeInt64(1, value: 0)
            body.writeString(2, value: "\"Café\"")
            body.writeString(2, value: "null")
            body.writeString(2, value: "42")
            return body.data
        }
        let client = ITerm2APIClient { socket }
        let values = try await client.variables(sessionId: "one", names: ["profileName", "hostname", "user.gitBranch"])
        XCTAssertEqual(values, ["profileName": "Café"])
        client.disconnect()
    }

    func testSearchIncludesContextAndPreservesOriginalOrder() {
        let group = ProjectGroup(profileName: "Project", sessions: [sampleSession("first"), sampleSession("second")])
        XCTAssertEqual(group.matching("project CAFE node")?.sessions.map(\.id), ["first", "second"])
        XCTAssertNil(group.matching("missing"))
        XCTAssertEqual(group.matching(" \n ")?.sessionCount, 2)
    }
}
