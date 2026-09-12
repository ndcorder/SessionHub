import Foundation

// MARK: - Minimal Protobuf Wire Format Support
// Only implements what's needed for iTerm2 API communication.
// Wire types: 0 = varint, 2 = length-delimited (strings, bytes, nested messages)

// MARK: - Encoder

struct ProtobufEncoder {
    private(set) var data = Data()

    // MARK: - Varint

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v > 127 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func writeVarint(_ value: Int64) {
        writeVarint(UInt64(bitPattern: value))
    }

    mutating func writeVarint(_ value: Int) {
        writeVarint(Int64(value))
    }

    // MARK: - Field Tags

    /// Wire type 0 = varint
    mutating func writeTag(fieldNumber: Int, wireType: Int = 0) {
        writeVarint(UInt64(fieldNumber << 3 | wireType))
    }

    // MARK: - Typed Field Writers

    /// Write an int64/int32 field (wire type 0)
    mutating func writeInt64(_ fieldNumber: Int, value: Int64) {
        writeTag(fieldNumber: fieldNumber, wireType: 0)
        writeVarint(value)
    }

    /// Write a uint32 field (wire type 0)
    mutating func writeUInt32(_ fieldNumber: Int, value: UInt32) {
        writeTag(fieldNumber: fieldNumber, wireType: 0)
        writeVarint(UInt64(value))
    }

    /// Write a bool field (wire type 0)
    mutating func writeBool(_ fieldNumber: Int, value: Bool) {
        writeTag(fieldNumber: fieldNumber, wireType: 0)
        writeVarint(value ? UInt64(1) : UInt64(0))
    }

    /// Write a string field (wire type 2)
    mutating func writeString(_ fieldNumber: Int, value: String) {
        let bytes = Array(value.utf8)
        writeTag(fieldNumber: fieldNumber, wireType: 2)
        writeVarint(UInt64(bytes.count))
        data.append(contentsOf: bytes)
    }

    /// Write a nested message field (wire type 2)
    mutating func writeMessage(_ fieldNumber: Int, value: Data) {
        writeTag(fieldNumber: fieldNumber, wireType: 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    /// Write an empty message field (wire type 2, length 0)
    mutating func writeEmptyMessage(_ fieldNumber: Int) {
        writeTag(fieldNumber: fieldNumber, wireType: 2)
        writeVarint(UInt64(0))
    }
}

// MARK: - Decoder

struct ProtobufDecoder {
    let data: Data
    private var offset: Int = 0

    init(_ data: Data) {
        self.data = Data(data)
    }

    var hasMore: Bool { offset < data.count }

    // MARK: - Varint

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            guard shift < 63 || byte <= 1 else { throw ProtobufError.malformedVarint }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift >= 64 { throw ProtobufError.malformedVarint }
        }
        throw ProtobufError.unexpectedEnd
    }

    // MARK: - Field Reading

    struct FieldHeader {
        let fieldNumber: Int
        let wireType: Int
    }

    mutating func readFieldHeader() throws -> FieldHeader {
        let tag = try readVarint()
        guard tag >> 3 > 0, tag >> 3 <= 0x1fff_ffff else { throw ProtobufError.unexpectedFieldType }
        guard [0, 1, 2, 5].contains(Int(tag & 7)) else { throw ProtobufError.unknownWireType(Int(tag & 7)) }
        return FieldHeader(
            fieldNumber: Int(tag >> 3),
            wireType: Int(tag & 0x07)
        )
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readVarint())
    }

    mutating func readBool() throws -> Bool {
        try readVarint() != 0
    }

    mutating func readInt32() throws -> Int32 {
        Int32(truncatingIfNeeded: try readVarint())
    }

    mutating func readLengthDelimited() throws -> Data {
        let rawLength = try readVarint()
        guard rawLength <= UInt64(data.count - offset) else { throw ProtobufError.unexpectedEnd }
        let length = Int(rawLength)
        guard length <= data.count - offset else {
            throw ProtobufError.unexpectedEnd
        }
        let result = data[offset..<(offset + length)]
        offset += length
        return Data(result)
    }

    mutating func readString() throws -> String {
        let bytes = try readLengthDelimited()
        guard let str = String(data: bytes, encoding: .utf8) else {
            throw ProtobufError.invalidUTF8
        }
        return str
    }

    /// Skip a field value based on wire type
    mutating func skipField(wireType: Int) throws {
        switch wireType {
        case 0: _ = try readVarint()             // varint
        case 1:
            guard data.count - offset >= 8 else { throw ProtobufError.unexpectedEnd }
            offset += 8
        case 2: _ = try readLengthDelimited()     // length-delimited
        case 5:
            guard data.count - offset >= 4 else { throw ProtobufError.unexpectedEnd }
            offset += 4
        default: throw ProtobufError.unknownWireType(wireType)
        }
    }
}

enum ProtobufError: Error {
    case malformedVarint
    case unexpectedEnd
    case invalidUTF8
    case unknownWireType(Int)
    case unexpectedFieldType
}

// MARK: - iTerm2 API Message Builders

/// Builds ClientOriginatedMessage protobuf payloads for iTerm2 API
enum ITerm2Messages {
    private static var nextId: Int64 = 1
    private static let idLock = NSLock()

    /// Generate unique message ID
    static func newId() -> Int64 {
        idLock.lock()
        defer { idLock.unlock() }
        let id = nextId
        nextId = nextId == Int64.max ? 1 : nextId + 1
        return id
    }

    // MARK: - Request Builders

    /// ListSessionsRequest (field 106 on ClientOriginatedMessage, empty body)
    static func listSessions() -> (id: Int64, data: Data) {
        let id = newId()
        var enc = ProtobufEncoder()
        enc.writeInt64(1, value: id)              // id field
        enc.writeEmptyMessage(106)                 // list_sessions_request (empty)
        return (id, enc.data)
    }

    /// ActivateRequest (field 114)
    /// session_id = field 3, order_window_front = field 4, select_tab = field 5, select_session = field 6
    static func activate(sessionId: String) -> (id: Int64, data: Data) {
        let id = newId()
        // Build inner ActivateRequest
        var inner = ProtobufEncoder()
        inner.writeString(3, value: sessionId)     // session_id (oneof identifier)
        inner.writeBool(4, value: true)            // order_window_front
        inner.writeBool(5, value: true)            // select_tab
        inner.writeBool(6, value: true)            // select_session

        var enc = ProtobufEncoder()
        enc.writeInt64(1, value: id)
        enc.writeMessage(114, value: inner.data)   // activate_request
        return (id, enc.data)
    }

    /// CreateTabRequest (field 108)
    /// profile_name = field 1, window_id = field 2
    static func createTab(profileName: String, windowId: String? = nil) -> (id: Int64, data: Data) {
        let id = newId()
        var inner = ProtobufEncoder()
        inner.writeString(1, value: profileName)
        if let wid = windowId {
            inner.writeString(2, value: wid)
        }

        var enc = ProtobufEncoder()
        enc.writeInt64(1, value: id)
        enc.writeMessage(108, value: inner.data)
        return (id, enc.data)
    }

    /// GetProfilePropertyRequest (field 110)
    /// session = field 1, keys = field 2 (repeated string)
    static func getProfileProperty(sessionId: String, keys: [String]) -> (id: Int64, data: Data) {
        let id = newId()
        var inner = ProtobufEncoder()
        inner.writeString(1, value: sessionId)
        for key in keys {
            inner.writeString(2, value: key)
        }

        var enc = ProtobufEncoder()
        enc.writeInt64(1, value: id)
        enc.writeMessage(110, value: inner.data)
        return (id, enc.data)
    }

    /// SetProfilePropertyRequest (field 105)
    /// session = field 1, key = field 3, json_value = field 4
    static func setProfileProperty(sessionId: String, key: String, jsonValue: String) -> (id: Int64, data: Data) {
        let id = newId()
        var inner = ProtobufEncoder()
        inner.writeString(1, value: sessionId)
        inner.writeString(3, value: key)
        inner.writeString(4, value: jsonValue)

        var enc = ProtobufEncoder()
        enc.writeInt64(1, value: id)
        enc.writeMessage(105, value: inner.data)
        return (id, enc.data)
    }

    // MARK: - Response Parsers

    struct Response {
        let id: Int64?
        let fieldNumber: Int
        let payload: Data
        let error: String?
    }

    /// Keep the request ID even on server errors, so the correct waiter is failed.
    static func decodeResponse(_ data: Data) throws -> Response {
        var dec = ProtobufDecoder(data)
        var id: Int64?
        var fieldNumber = 0
        var payload = Data()
        var error: String?
        while dec.hasMore {
            let header = try dec.readFieldHeader()
            switch header.fieldNumber {
            case 1:
                guard header.wireType == 0 else { throw ProtobufError.unexpectedFieldType }
                id = try dec.readInt64()
            case 2:
                guard header.wireType == 2 else { throw ProtobufError.unexpectedFieldType }
                error = try dec.readString()
            default:
                if header.wireType == 2 {
                    fieldNumber = header.fieldNumber
                    payload = try dec.readLengthDelimited()
                } else { try dec.skipField(wireType: header.wireType) }
            }
        }
        guard error != nil || fieldNumber != 0 else { throw ProtobufError.unexpectedEnd }
        return Response(id: id, fieldNumber: fieldNumber, payload: payload, error: error)
    }

    static func parseResponse(_ data: Data) throws -> (id: Int64, fieldNumber: Int, payload: Data) {
        let response = try decodeResponse(data)
        if let error = response.error { throw ITerm2APIError.serverError(error) }
        return (response.id ?? 0, response.fieldNumber, response.payload)
    }

    // MARK: - ListSessions Response Parser

    struct ParsedSession {
        let uniqueId: String
        let title: String
        let windowId: String
        let tabId: String
        let windowNumber: Int32
    }

    struct ParsedWindow {
        let windowId: String
        let windowNumber: Int32
        var tabs: [ParsedTab]
    }

    struct ParsedTab {
        let tabId: String
        var sessions: [ParsedSession]
    }

    /// Parse ListSessionsResponse (field 106)
    static func parseListSessions(_ data: Data) throws -> [ParsedWindow] {
        var dec = ProtobufDecoder(data)
        var windows: [ParsedWindow] = []

        while dec.hasMore {
            let header = try dec.readFieldHeader()
            switch header.fieldNumber {
            case 1: // repeated Window windows
                let windowData = try dec.readLengthDelimited()
                let window = try parseWindow(windowData)
                windows.append(window)
            default:
                try dec.skipField(wireType: header.wireType)
            }
        }
        return windows
    }

    private static func parseWindow(_ data: Data) throws -> ParsedWindow {
        var dec = ProtobufDecoder(data)
        var windowId = ""
        var windowNumber: Int32 = 0
        var tabs: [ParsedTab] = []

        while dec.hasMore {
            let header = try dec.readFieldHeader()
            switch header.fieldNumber {
            case 1: // repeated Tab tabs
                let tabData = try dec.readLengthDelimited()
                let tab = try parseTab(tabData)
                tabs.append(tab)
            case 2: // string window_id
                windowId = try dec.readString()
            case 3: // Frame frame - skip
                try dec.skipField(wireType: header.wireType)
            case 4: // int32 number
                windowNumber = try dec.readInt32()
            default:
                try dec.skipField(wireType: header.wireType)
            }
        }
        return ParsedWindow(windowId: windowId, windowNumber: windowNumber, tabs: tabs)
    }

    private static func parseTab(_ data: Data) throws -> ParsedTab {
        var dec = ProtobufDecoder(data)
        var tabId = ""
        var sessions: [ParsedSession] = []

        while dec.hasMore {
            let header = try dec.readFieldHeader()
            switch header.fieldNumber {
            case 2: // string tab_id
                tabId = try dec.readString()
            case 3: // SplitTreeNode root
                let nodeData = try dec.readLengthDelimited()
                try parseSplitTree(nodeData, into: &sessions)
            default:
                try dec.skipField(wireType: header.wireType)
            }
        }
        return ParsedTab(tabId: tabId, sessions: sessions)
    }

    /// Bound recursion and propagate malformed messages instead of publishing partial snapshots.
    private static func parseSplitTree(_ data: Data, into sessions: inout [ParsedSession], depth: Int = 0) throws {
        guard depth < 64 else { throw ProtobufError.unexpectedFieldType }
        var dec = ProtobufDecoder(data)
        while dec.hasMore {
            let header = try dec.readFieldHeader()
            if header.fieldNumber == 2 {
                let link = try dec.readLengthDelimited()
                var linkDecoder = ProtobufDecoder(link)
                while linkDecoder.hasMore {
                    let field = try linkDecoder.readFieldHeader()
                    switch field.fieldNumber {
                    case 1: sessions.append(try parseSessionSummary(linkDecoder.readLengthDelimited()))
                    case 2: try parseSplitTree(linkDecoder.readLengthDelimited(), into: &sessions, depth: depth + 1)
                    default: try linkDecoder.skipField(wireType: field.wireType)
                    }
                }
            } else { try dec.skipField(wireType: header.wireType) }
        }
    }

    private static func parseSessionSummary(_ data: Data) throws -> ParsedSession {
        var dec = ProtobufDecoder(data)
        var uniqueId = ""
        var title = ""

        while dec.hasMore {
            let header = try dec.readFieldHeader()
            switch header.fieldNumber {
            case 1: // string unique_identifier
                uniqueId = try dec.readString()
            case 4: // string title
                title = try dec.readString()
            default:
                try dec.skipField(wireType: header.wireType)
            }
        }
        return ParsedSession(uniqueId: uniqueId, title: title, windowId: "", tabId: "", windowNumber: 0)
    }

    // MARK: - GetProfileProperty Response Parser

    struct ProfileProperty {
        let key: String
        let jsonValue: String
    }

    static func parseGetProfileProperty(_ data: Data) throws -> [ProfileProperty] {
        var dec = ProtobufDecoder(data)
        var properties: [ProfileProperty] = []

        while dec.hasMore {
            let header = try dec.readFieldHeader()
            switch header.fieldNumber {
            case 1: // Status status - skip
                _ = try dec.readVarint()
            case 3: // repeated ProfileProperty properties
                let propData = try dec.readLengthDelimited()
                let prop = try parseProfileProperty(propData)
                properties.append(prop)
            default:
                try dec.skipField(wireType: header.wireType)
            }
        }
        return properties
    }

    private static func parseProfileProperty(_ data: Data) throws -> ProfileProperty {
        var dec = ProtobufDecoder(data)
        var key = ""
        var jsonValue = ""

        while dec.hasMore {
            let header = try dec.readFieldHeader()
            switch header.fieldNumber {
            case 1: key = try dec.readString()
            case 2: jsonValue = try dec.readString()
            default: try dec.skipField(wireType: header.wireType)
            }
        }
        return ProfileProperty(key: key, jsonValue: jsonValue)
    }

    // MARK: - CreateTab Response Parser

    struct CreateTabResult {
        let windowId: String
        let tabId: Int32
        let sessionId: String
    }

    static func parseCreateTab(_ data: Data) throws -> CreateTabResult {
        var dec = ProtobufDecoder(data)
        var windowId = ""
        var tabId: Int32 = 0
        var sessionId = ""

        while dec.hasMore {
            let header = try dec.readFieldHeader()
            switch header.fieldNumber {
            case 1: _ = try dec.readVarint() // status
            case 2: windowId = try dec.readString()
            case 3: tabId = try dec.readInt32()
            case 4: sessionId = try dec.readString()
            default: try dec.skipField(wireType: header.wireType)
            }
        }
        return CreateTabResult(windowId: windowId, tabId: tabId, sessionId: sessionId)
    }
}

enum ITerm2APIError: Error, CustomStringConvertible {
    case serverError(String)
    case connectionFailed(String)
    case timeout
    case notConnected
    case apiNotEnabled

    var description: String {
        switch self {
        case .serverError(let msg): return "iTerm2 API error: \(msg)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .timeout: return "Request timed out"
        case .notConnected: return "Not connected to iTerm2 API"
        case .apiNotEnabled: return "iTerm2 Python API not enabled"
        }
    }
}
