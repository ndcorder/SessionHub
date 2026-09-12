import Foundation
import CryptoKit

/// RFC 6455 framing for the local iTerm2 socket. No terminal content is logged.
enum WebSocketCodec {
    static let maximumPayload = 8 * 1024 * 1024

    struct Frame {
        let opcode: UInt8
        let final: Bool
        let payload: Data
        let consumed: Int
    }

    static func encode(_ payload: Data, opcode: UInt8 = 2) -> Data {
        var data = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            data.append(0x80 | UInt8(count))
        } else if count <= 65535 {
            data.append(contentsOf: [0xfe, UInt8(count >> 8), UInt8(count & 255)])
        } else {
            data.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((UInt64(count) >> shift) & 255))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        data.append(contentsOf: mask)
        data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return data
    }

    static func decode(_ input: Data) throws -> Frame? {
        let data = Data(input) // Normalize indices even when passed a slice.
        guard data.count >= 2 else { return nil }
        let opcode = data[0] & 15
        let final = data[0] & 0x80 != 0
        guard data[0] & 0x70 == 0, data[1] & 0x80 == 0,
              [0, 1, 2, 8, 9, 10].contains(opcode) else {
            throw ITerm2APIError.connectionFailed("Invalid WebSocket frame")
        }
        var length = UInt64(data[1] & 127)
        var offset = 2
        if length == 126 {
            guard data.count >= 4 else { return nil }
            length = UInt64(data[2]) << 8 | UInt64(data[3])
            guard length >= 126 else { throw ITerm2APIError.connectionFailed("Invalid frame length") }
            offset = 4
        } else if length == 127 {
            guard data.count >= 10 else { return nil }
            length = data[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length >= 65536 else { throw ITerm2APIError.connectionFailed("Invalid frame length") }
            offset = 10
        }
        guard length <= maximumPayload else { throw ITerm2APIError.connectionFailed("WebSocket frame too large") }
        guard opcode < 8 || (final && length <= 125) else {
            throw ITerm2APIError.connectionFailed("Invalid control frame")
        }
        guard data.count - offset >= Int(length) else { return nil }
        return Frame(opcode: opcode, final: final,
                     payload: Data(data[offset..<(offset + Int(length))]), consumed: offset + Int(length))
    }

    static func acceptKey(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// Returns the first byte after the HTTP headers; any following bytes are frames.
    static func validateHandshake(_ data: Data, key: String) throws -> Int? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 16384 else { throw ITerm2APIError.connectionFailed("Handshake headers too large") }
            return nil
        }
        guard end.upperBound <= 16384,
              let header = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            throw ITerm2APIError.connectionFailed("Invalid handshake headers")
        }
        let lines = header.components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ")
        guard status.count >= 2, status[0] == "HTTP/1.1", status[1] == "101" else {
            throw ITerm2APIError.connectionFailed("iTerm2 declined the API connection. Check API access in iTerm2.")
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let connectionTokens = fields["connection", default: ""].lowercased().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard fields["upgrade"]?.lowercased() == "websocket", connectionTokens.contains("upgrade"),
              fields["sec-websocket-accept"] == acceptKey(for: key),
              fields["sec-websocket-protocol"] == "api.iterm2.com" else {
            throw ITerm2APIError.connectionFailed("iTerm2 returned an invalid WebSocket upgrade")
        }
        return end.upperBound
    }
}
