import Foundation

/// Run through live-smoke.sh. Default is read-only; --actions creates disposable shells.
@main
struct LiveSmoke {
    enum Failure: Error { case assertion(String) }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
    static func customShellProperties(into body: inout ProtobufEncoder, field: Int) throws {
        for (key, value) in [("Custom Command", "Yes"), ("Command", "/bin/zsh -f")] {
            var property = ProtobufEncoder()
            property.writeString(1, value: key)
            property.writeString(2, value: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
            body.writeMessage(field, value: property.data)
        }
    }

    @MainActor static func main() async {
        // Leave time for the user to approve iTerm2's first-connection prompt.
        let client = ITerm2APIClient(timeout: 60)
        let bridge = ITerm2Bridge(client: client)
        var createdIDs: [String] = []
        var previousActive: ITerm2Bridge.SessionInfo?
        var failure: Error?
        do {
            let before = try await bridge.snapshot()
            previousActive = before.sessions.first(where: \.isActive)
            let originalIDs = Set(before.sessions.map(\.id))
            print("Snapshot: \(before.sessions.count) sessions, \(before.profiles.count) profiles, \(before.sessions.filter(\.isActive).count) active, \(before.sessions.filter { !$0.directory.isEmpty }.count) directories")
            client.disconnect()
            let again = try await bridge.snapshot()
            try require(Set(again.sessions.map(\.id)).isSuperset(of: originalIDs), "Sessions missing after reconnect")
            print("Client disconnect/reconnect: passed")
            if CommandLine.arguments.contains("--actions") {
                var create = ProtobufEncoder()
                try customShellProperties(into: &create, field: 5)
                let response = try await client.request(ITerm2Messages.request(108, body: create), expectedField: 108)
                try MessageFields(response).requireOK("Create tab")
                let result = try ITerm2Messages.parseCreateTab(response)
                try require(!result.sessionId.isEmpty && !originalIDs.contains(result.sessionId), "Invalid fixture session identity")
                createdIDs.append(result.sessionId)
                let profileBefore = try await client.variables(sessionId: result.sessionId, names: ["profileName"])
                let name = "SessionHub QA \(UUID().uuidString.prefix(8))"
                try await client.renameSession(sessionId: result.sessionId, name: name)
                let renamed = try await client.variables(sessionId: result.sessionId, names: ["profileName", "autoName"])
                try require(renamed["autoName"] == name, "Rename did not update the session name")
                try require(renamed["profileName"] == profileBefore["profileName"], "Rename changed the profile grouping")
                print("Create and rename without regrouping: passed")
                try await client.activate(sessionId: result.sessionId)
                let active = try await client.variables(sessionId: "active", names: ["id"])
                try require(active["id"] == result.sessionId, "Activate selected a different session")
                print("Activate: passed")
                var split = ProtobufEncoder()
                split.writeString(1, value: result.sessionId)
                split.writeInt64(2, value: 0)
                try customShellProperties(into: &split, field: 5)
                let splitPayload = try await client.request(ITerm2Messages.request(109, body: split), expectedField: 109)
                let splitFields = try MessageFields(splitPayload)
                let ids = try splitFields.strings(2)
                for id in ids where !id.isEmpty && !originalIDs.contains(id) && !createdIDs.contains(id) { createdIDs.append(id) }
                try splitFields.requireOK("Split pane")
                try require(!ids.isEmpty, "Split produced no pane")
                print("Split: passed")
            }
        } catch { failure = error }

        // Always clean up only IDs returned by our own create/split requests.
        for id in createdIDs.reversed() {
            do { try await client.closeSession(sessionId: id) }
            catch { failure = failure ?? error }
        }
        if let previousActive, !createdIDs.isEmpty {
            do { try await client.activate(sessionId: previousActive.id) }
            catch { failure = failure ?? error }
        }
        if !createdIDs.isEmpty {
            do {
                let after = try await bridge.snapshot()
                try require(Set(after.sessions.map(\.id)).isDisjoint(with: createdIDs), "A fixture session is still open")
                print("Close and fixture cleanup: passed")
            } catch { failure = failure ?? error }
        }
        bridge.disconnect()
        if let failure { print("Live smoke check failed: \(failure)"); exit(1) }
        print("Live smoke check passed")
    }
}
