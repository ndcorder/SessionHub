import XCTest
@testable import SessionHub

final class ProtocolTests: XCTestCase {
    func testHandshakeValidationAndCoalescedData() throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        XCTAssertEqual(WebSocketCodec.acceptKey(for: key), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let headers = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Protocol: api.iterm2.com\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n".utf8)
        var buffer = headers
        buffer.append(contentsOf: [0x82, 0])
        XCTAssertEqual(try WebSocketCodec.validateHandshake(buffer, key: key), headers.count)
        XCTAssertThrowsError(try WebSocketCodec.validateHandshake(headers, key: "wrong"))
        XCTAssertNil(try WebSocketCodec.validateHandshake(Data(headers.prefix(10)), key: key))
        XCTAssertThrowsError(try WebSocketCodec.validateHandshake(Data(repeating: 65, count: 16385), key: key))
        XCTAssertThrowsError(try WebSocketCodec.validateHandshake(Data("HTTP/1.1 403 Error 101\r\n\r\n".utf8), key: key))
    }

    func testFramesRejectUnsafeLengthsAndControlFrames() throws {
        XCTAssertNil(try WebSocketCodec.decode(Data([0x82, 126, 1])))
        XCTAssertThrowsError(try WebSocketCodec.decode(Data([0x82, 127] + Array(repeating: 255, count: 8))))
        XCTAssertThrowsError(try WebSocketCodec.decode(Data([0x09, 0]))) // fragmented ping
        XCTAssertThrowsError(try WebSocketCodec.decode(Data([0x82, 0x80]))) // masked server frame
        XCTAssertThrowsError(try WebSocketCodec.decode(Data([0xc2, 0]))) // unsupported extension
        XCTAssertThrowsError(try WebSocketCodec.decode(Data([0x82, 126, 0, 2, 1, 2])))
        let payload = Data(repeating: 42, count: 200)
        let frame = try XCTUnwrap(WebSocketCodec.decode(serverFrame(payload)))
        XCTAssertEqual(frame.payload, payload)
        XCTAssertEqual(frame.consumed, 204)
    }

    func testClientFramesAreMaskedWithoutChangingPayload() {
        for count in [0, 5, 125, 126, 65535, 65536] {
            let original = Data((0..<count).map { UInt8($0 % 251) })
            let frame = WebSocketCodec.encode(original)
            XCTAssertEqual(frame[1] & 0x80, 0x80)
            let start = count < 126 ? 2 : (count <= 65535 ? 4 : 10)
            let mask = Array(frame[start..<(start + 4)])
            let decoded = Data(frame.dropFirst(start + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] })
            XCTAssertEqual(decoded, original)
        }
    }

    func testProtobufRejectsTruncationOverflowAndInvalidTags() {
        for bytes: [UInt8] in [[0x80], Array(repeating: 0xff, count: 10), Array(repeating: 0xff, count: 9) + [2]] {
            var decoder = ProtobufDecoder(Data(bytes))
            XCTAssertThrowsError(try decoder.readVarint())
        }
        var length = ProtobufDecoder(Data(Array(repeating: 0xff, count: 9) + [1]))
        XCTAssertThrowsError(try length.readLengthDelimited())
        var fixed = ProtobufDecoder(Data([1, 2]))
        XCTAssertThrowsError(try fixed.skipField(wireType: 1))
        var tag = ProtobufDecoder(Data([0]))
        XCTAssertThrowsError(try tag.readFieldHeader())
        var encoder = ProtobufEncoder()
        encoder.writeVarint(UInt64.max)
        var decoder = ProtobufDecoder(encoder.data)
        XCTAssertEqual(try decoder.readVarint(), UInt64.max)
    }

    func testConcurrentMessageIDsAreUnique() {
        let lock = NSLock()
        var ids: Set<Int64> = []
        DispatchQueue.concurrentPerform(iterations: 2000) { _ in
            let id = ITerm2Messages.newId()
            lock.lock(); ids.insert(id); lock.unlock()
        }
        XCTAssertEqual(ids.count, 2000)
    }
}
