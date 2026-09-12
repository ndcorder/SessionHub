import XCTest
@testable import SessionHub

final class SnapshotTests: XCTestCase {
    @MainActor
    func testLiveProtocolSnapshotMapsActiveSessionAndMetadata() async throws {
        let socket = FakeTransport()
        socket.onRequest = { _, field, body in
            switch field {
            case 106:
                var tree = ProtobufEncoder()
                for id in ["one", "two"] {
                    var summary = ProtobufEncoder()
                    summary.writeString(1, value: id)
                    summary.writeString(4, value: "Title \(id)")
                    var link = ProtobufEncoder()
                    link.writeMessage(1, value: summary.data)
                    tree.writeMessage(2, value: link.data)
                }
                var tab = ProtobufEncoder()
                tab.writeString(2, value: "tab")
                tab.writeMessage(3, value: tree.data)
                var window = ProtobufEncoder()
                window.writeMessage(1, value: tab.data)
                window.writeString(2, value: "window")
                window.writeInt64(4, value: 4)
                var response = ProtobufEncoder()
                response.writeMessage(1, value: window.data)
                return response.data
            case 115:
                let fields = try MessageFields(body)
                let id = try fields.strings(1).first
                let names = try fields.strings(3)
                var response = ProtobufEncoder()
                response.writeInt64(1, value: 0)
                for name in names {
                    let value: String?
                    switch name {
                    case "id": value = "two"
                    case "profileName": value = "Project"
                    case "path": value = "/work/\(id ?? "")"
                    case "hostname": value = "host"
                    case "jobName": value = "zsh"
                    default: value = nil
                    }
                    response.writeString(2, value: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
                }
                return response.data
            case 118:
                var property = ProtobufEncoder()
                property.writeString(1, value: "Name")
                property.writeString(2, value: "\"Project\"")
                var profile = ProtobufEncoder()
                profile.writeMessage(1, value: property.data)
                var response = ProtobufEncoder()
                response.writeMessage(1, value: profile.data)
                return response.data
            default: throw SessionAPIError.unexpectedResponse
            }
        }
        let bridge = ITerm2Bridge(client: ITerm2APIClient { socket })
        let snapshot = try await bridge.snapshot()
        XCTAssertEqual(snapshot.profiles, ["Project"])
        XCTAssertEqual(snapshot.sessions.map(\.id), ["one", "two"])
        XCTAssertEqual(snapshot.sessions.map(\.isActive), [false, true])
        XCTAssertEqual(snapshot.sessions.map(\.directory), ["/work/one", "/work/two"])
        XCTAssertEqual(snapshot.sessions.map(\.sessionIndex), [0, 1])
        XCTAssertEqual(snapshot.sessions.map(\.windowNumber), [4, 4])
        bridge.disconnect()
    }
}
