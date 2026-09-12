import XCTest
@testable import SessionHub

final class FakeTransport: APITransport {
    enum Handshake { case valid, rejected, stalled }
    var stateUpdate: ((APITransportState) -> Void)?
    private var queue: DispatchQueue!
    private var reader: ((Data?, Bool, Error?) -> Void)?
    private var events: [(Data?, Bool, Error?)] = []
    private var writes: [Data] = []
    private var originalStateUpdate: ((APITransportState) -> Void)?
    private let handshake: Handshake
    init(_ handshake: Handshake = .valid) { self.handshake = handshake }

    func start(queue: DispatchQueue) {
        self.queue = queue
        originalStateUpdate = stateUpdate
        queue.async { self.stateUpdate?(.ready) }
    }
    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        writes.append(data)
        completion(nil)
        if let request = String(data: data, encoding: .utf8), request.hasPrefix("GET ") {
            switch handshake {
            case .stalled: break
            case .rejected: enqueue(Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8), false, nil)
            case .valid:
                let key = request.components(separatedBy: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key:") }!
                    .components(separatedBy: ": ")[1]
                let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: api.iterm2.com\r\nSec-WebSocket-Accept: \(WebSocketCodec.acceptKey(for: key))\r\n\r\n"
                let data = Data(response.utf8)
                // Exercise split HTTP headers on every successful connection.
                enqueue(Data(data.prefix(19)), false, nil)
                enqueue(Data(data.dropFirst(19)), false, nil)
            }
        }
    }
    func receive(completion: @escaping (Data?, Bool, Error?) -> Void) {
        reader = completion
        drain()
    }
    func cancel() {}
    func inject(_ data: Data? = nil, complete: Bool = false, error: Error? = nil) {
        queue.async { self.enqueue(data, complete, error) }
    }
    func staleClose() { queue.async { self.originalStateUpdate?(.closed) } }
    var sentFrames: [Data] { queue.sync { writes.filter { $0.first != 71 } } }
    private func enqueue(_ data: Data?, _ complete: Bool, _ error: Error?) {
        events.append((data, complete, error))
        drain()
    }
    private func drain() {
        guard let callback = reader, !events.isEmpty else { return }
        reader = nil
        let event = events.removeFirst()
        queue.async { callback(event.0, event.1, event.2) }
    }
}

func serverFrame(_ payload: Data, opcode: UInt8 = 2, final: Bool = true) -> Data {
    var result = Data([(final ? 0x80 : 0) | opcode])
    if payload.count < 126 { result.append(UInt8(payload.count)) }
    else { result.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
    result.append(payload)
    return result
}

final class TransportTests: XCTestCase {
    private func connect(_ client: ITerm2APIClient) async -> Bool {
        await withCheckedContinuation { continuation in
            client.connect { continuation.resume(returning: $0) }
        }
    }

    func testConcurrentConnectsShareHandshakeAndRecoverAfterEOF() async {
        let first = FakeTransport()
        let second = FakeTransport()
        var created = 0
        let client = ITerm2APIClient { created += 1; return created == 1 ? first : second }
        async let a = connect(client)
        async let b = connect(client)
        let results = await [a, b]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(created, 1)
        let failed = expectation(description: "EOF fails request")
        client.send(Data(), id: 99) { response in
            if case .success = response { XCTFail("EOF must fail pending requests") }
            failed.fulfill()
        }
        first.inject(complete: true)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertFalse(client.connected)
        let reconnected = await connect(client)
        XCTAssertTrue(reconnected)
        first.staleClose()
        XCTAssertTrue(client.connected, "Old socket callbacks cannot disconnect the replacement")
        client.disconnect()
    }

    func testRejectedAndStalledHandshakesCompleteAllWaiters() async {
        for mode in [FakeTransport.Handshake.rejected, .stalled] {
            let client = ITerm2APIClient(timeout: 0.05) { FakeTransport(mode) }
            async let a = connect(client)
            async let b = connect(client)
            let results = await [a, b]
            XCTAssertEqual(results, [false, false])
            XCTAssertFalse(client.connected)
        }
    }

    func testTimeoutFailsAllPendingRequestsAndAllowsReconnect() async {
        let client = ITerm2APIClient(timeout: 0.05) { FakeTransport() }
        let connected = await connect(client)
        XCTAssertTrue(connected)
        let failed = expectation(description: "Both pending requests finish")
        failed.expectedFulfillmentCount = 2
        for id in Int64(1)...2 {
            client.send(Data(), id: id) { response in
                if case .success = response { XCTFail("Stalled request succeeded") }
                failed.fulfill()
            }
        }
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertFalse(client.connected)
        let reconnected = await connect(client)
        XCTAssertTrue(reconnected)
        client.disconnect()
    }

    func testFragmentedResponseWithPingAndServerErrorRouting() async {
        let socket = FakeTransport()
        let client = ITerm2APIClient { socket }
        let connected = await connect(client)
        XCTAssertTrue(connected)
        let received = expectation(description: "Response reassembled")
        client.send(Data(), id: 7) { response in
            guard case .success(let (field, payload)) = response else { XCTFail(); received.fulfill(); return }
            XCTAssertEqual(field, 106)
            XCTAssertEqual(payload, Data([1, 2, 3]))
            received.fulfill()
        }
        var message = ProtobufEncoder()
        message.writeInt64(1, value: 7)
        message.writeMessage(106, value: Data([1, 2, 3]))
        socket.inject(serverFrame(Data(message.data.prefix(3)), final: false))
        socket.inject(serverFrame(Data("ping".utf8), opcode: 9))
        socket.inject(serverFrame(Data(message.data.dropFirst(3)), opcode: 0))
        await fulfillment(of: [received], timeout: 1)
        XCTAssertTrue(socket.sentFrames.contains { $0.first == 0x8a }, "Ping must produce a masked pong")
        let rejected = expectation(description: "Server error delivered by request ID")
        client.send(Data(), id: 8) { response in
            guard case .failure(let error) = response else { XCTFail(); rejected.fulfill(); return }
            XCTAssertTrue(String(describing: error).contains("invalid session"))
            rejected.fulfill()
        }
        var error = ProtobufEncoder()
        error.writeInt64(1, value: 8)
        error.writeString(2, value: "invalid session")
        socket.inject(serverFrame(error.data))
        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertTrue(client.connected, "An action error does not corrupt the transport")
        client.disconnect()
    }

    func testSocketErrorFailsWaitersAndCloseFrameDisconnects() async {
        for closedByFrame in [true, false] {
            let socket = FakeTransport()
            let client = ITerm2APIClient { socket }
            _ = await connect(client)
            let failed = expectation(description: "Request failed")
            client.send(Data(), id: 1) { response in
                if case .success = response { XCTFail() }
                failed.fulfill()
            }
            if closedByFrame { socket.inject(serverFrame(Data(), opcode: 8)) }
            else { socket.inject(error: ITerm2APIError.notConnected) }
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertFalse(client.connected)
        }
    }
}
