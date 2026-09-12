import Foundation

/// Minimal typed fields for the API messages used by SessionHub.
struct MessageFields {
    var integers: [Int: [UInt64]] = [:]
    var bytes: [Int: [Data]] = [:]

    init(_ data: Data) throws {
        var decoder = ProtobufDecoder(data)
        while decoder.hasMore {
            let header = try decoder.readFieldHeader()
            switch header.wireType {
            case 0: integers[header.fieldNumber, default: []].append(try decoder.readVarint())
            case 2: bytes[header.fieldNumber, default: []].append(try decoder.readLengthDelimited())
            default: try decoder.skipField(wireType: header.wireType)
            }
        }
    }

    func strings(_ field: Int) throws -> [String] {
        try bytes[field, default: []].map {
            guard let string = String(data: $0, encoding: .utf8) else { throw ProtobufError.invalidUTF8 }
            return string
        }
    }

    func requireOK(_ operation: String) throws {
        for status in integers[1, default: [0]] where status != 0 {
            throw SessionAPIError.rejected(operation: operation, status: status)
        }
    }
}

enum SessionAPIError: LocalizedError {
    case rejected(operation: String, status: UInt64)
    case unexpectedResponse
    case invalidName

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a session name before saving."
        case .unexpectedResponse: return "iTerm2 returned an unexpected response. Try refreshing."
        case .rejected(let operation, let status):
            if operation == "Close session", status == 2 { return "The session was kept open in iTerm2." }
            if operation == "Split pane", status == 3 { return "This pane is too small to split. Enlarge it in iTerm2 and try again." }
            if operation == "Create tab", status == 3 { return "The tab was created, but iTerm2 could not place it at the requested position." }
            return "\(operation) failed (iTerm2 status \(status)). The session or profile may have changed; refresh and try again."
        }
    }
}

extension ITerm2Messages {
    static func request(_ field: Int, body: ProtobufEncoder = ProtobufEncoder()) -> (id: Int64, data: Data) {
        let id = newId()
        var envelope = ProtobufEncoder()
        envelope.writeInt64(1, value: id)
        envelope.writeMessage(field, value: body.data)
        return (id, envelope.data)
    }

    static func variables(sessionId: String, names: [String]) -> (id: Int64, data: Data) {
        var body = ProtobufEncoder()
        body.writeString(1, value: sessionId)
        for name in names { body.writeString(3, value: name) }
        return request(115, body: body)
    }

    static func rename(sessionId: String, name: String) throws -> (id: Int64, data: Data) {
        let jsonName = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
        var method = ProtobufEncoder()
        method.writeString(1, value: sessionId)
        var body = ProtobufEncoder()
        body.writeMessage(7, value: method.data)
        body.writeString(5, value: "iterm2.set_name(name: \(jsonName))")
        return request(132, body: body)
    }

    static func split(sessionId: String, profile: String, vertical: Bool) -> (id: Int64, data: Data) {
        var body = ProtobufEncoder()
        body.writeString(1, value: sessionId)
        body.writeInt64(2, value: vertical ? 0 : 1)
        body.writeString(4, value: profile)
        return request(109, body: body)
    }

    static func close(sessionId: String) -> (id: Int64, data: Data) {
        var sessions = ProtobufEncoder()
        sessions.writeString(1, value: sessionId)
        var body = ProtobufEncoder()
        body.writeMessage(2, value: sessions.data)
        body.writeBool(4, value: false) // Preserve iTerm2's running-job confirmation.
        return request(131, body: body)
    }
}
