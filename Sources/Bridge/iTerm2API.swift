import Foundation
import Network

/// All callbacks must run on the queue supplied to start().
protocol APITransport: AnyObject {
    var stateUpdate: ((APITransportState) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func receive(completion: @escaping (Data?, Bool, Error?) -> Void)
    func cancel()
}

enum APITransportState { case ready, failed(Error), closed }

final class SocketTransport: APITransport {
    private let connection: NWConnection
    var stateUpdate: ((APITransportState) -> Void)?

    init(path: String) {
        let parameters = NWParameters(tls: nil)
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        connection = NWConnection(to: .unix(path: path), using: parameters)
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.stateUpdate?(.ready)
            case .failed(let error), .waiting(let error): self?.stateUpdate?(.failed(error))
            case .cancelled: self?.stateUpdate?(.closed)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func receive(completion: @escaping (Data?, Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            completion(data, complete, error)
        }
    }

    func cancel() { connection.cancel() }
}

/// Serializes every connection transition and request callback on one private queue.
/// Old socket callbacks are ignored after teardown; every waiter completes exactly once.
final class ITerm2APIClient {
    typealias Response = Result<(Int, Data), Error>
    private let queue = DispatchQueue(label: "com.sessionhub.iterm2api")
    private let factory: () -> APITransport
    private let timeout: TimeInterval
    private var transport: APITransport?
    private var generation = UUID()
    private var isConnected = false
    private var connectionFailure: Error?
    private var connectWaiters: [(Bool) -> Void] = []
    private var pending: [Int64: (Response) -> Void] = [:]
    private var receiveBuffer = Data()
    private var fragments: Data?
    private var handshakeKey = ""

    init(timeout: TimeInterval = 5, factory: (() -> APITransport)? = nil) {
        self.timeout = timeout
        self.factory = factory ?? {
            SocketTransport(path: NSHomeDirectory() + "/Library/Application Support/iTerm2/private/socket")
        }
    }

    var connected: Bool { queue.sync { isConnected } }

    func connect(completion: @escaping (Bool) -> Void) {
        queue.async {
            if self.isConnected { completion(true); return }
            self.connectWaiters.append(completion)
            guard self.transport == nil else { return }
            let socket = self.factory()
            let token = UUID()
            self.generation = token
            self.transport = socket
            self.handshakeKey = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            socket.stateUpdate = { [weak self] state in
                guard let self, self.generation == token else { return }
                switch state {
                case .ready: self.beginHandshake(socket, token: token)
                case .failed(let error): self.tearDown(error)
                case .closed: self.tearDown(ITerm2APIError.notConnected)
                }
            }
            socket.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                guard let self, self.generation == token, !self.isConnected else { return }
                self.tearDown(ITerm2APIError.timeout)
            }
        }
    }

    func disconnect() {
        queue.async { self.tearDown(ITerm2APIError.notConnected) }
    }

    private func tearDown(_ error: Error) {
        generation = UUID()
        let old = transport
        transport = nil
        isConnected = false
        connectionFailure = error
        receiveBuffer.removeAll()
        fragments = nil
        let waiters = connectWaiters
        connectWaiters.removeAll()
        let handlers = pending.values.map { $0 }
        pending.removeAll()
        old?.stateUpdate = nil
        old?.cancel()
        waiters.forEach { $0(false) }
        handlers.forEach { $0(.failure(error)) }
    }

    private func beginHandshake(_ socket: APITransport, token: UUID) {
        let request = [
            "GET / HTTP/1.1", "Host: localhost", "Upgrade: websocket", "Connection: Upgrade",
            "Sec-WebSocket-Key: \(handshakeKey)", "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Protocol: api.iterm2.com", "Origin: ws://localhost/",
            "x-iterm2-library-version: swift 1.0", "x-iterm2-advisory-name: SessionHub", "", ""
        ].joined(separator: "\r\n")
        socket.send(Data(request.utf8)) { [weak self] error in
            guard let self, self.generation == token else { return }
            if let error { self.tearDown(error) }
        }
        receive(socket, token: token)
    }

    private func receive(_ socket: APITransport, token: UUID) {
        socket.receive { [weak self] data, complete, error in
            guard let self, self.generation == token else { return }
            if let error { self.tearDown(error); return }
            do {
                if let data { self.receiveBuffer.append(data) }
                if !self.isConnected {
                    if let end = try WebSocketCodec.validateHandshake(self.receiveBuffer, key: self.handshakeKey) {
                        self.receiveBuffer = Data(self.receiveBuffer.dropFirst(end))
                        self.isConnected = true
                        self.connectionFailure = nil
                        let waiters = self.connectWaiters
                        self.connectWaiters.removeAll()
                        waiters.forEach { $0(true) }
                    }
                }
                if self.isConnected { try self.consumeFrames(socket, token: token) }
                guard self.generation == token else { return }
                if complete { self.tearDown(ITerm2APIError.notConnected); return }
                self.receive(socket, token: token)
            } catch { self.tearDown(error) }
        }
    }

    private func consumeFrames(_ socket: APITransport, token: UUID) throws {
        while let frame = try WebSocketCodec.decode(receiveBuffer) {
            receiveBuffer = Data(receiveBuffer.dropFirst(frame.consumed))
            switch frame.opcode {
            case 8:
                tearDown(ITerm2APIError.notConnected)
                return
            case 9:
                socket.send(WebSocketCodec.encode(frame.payload, opcode: 10)) { [weak self] error in
                    guard let self, self.generation == token else { return }
                    if let error { self.tearDown(error) }
                }
            case 10: break
            case 2:
                guard fragments == nil else { throw ITerm2APIError.connectionFailed("Unexpected data frame") }
                if frame.final { try handleResponse(frame.payload) } else { fragments = frame.payload }
            case 0:
                guard var message = fragments, message.count <= WebSocketCodec.maximumPayload - frame.payload.count else {
                    throw ITerm2APIError.connectionFailed("Invalid fragmented message")
                }
                message.append(frame.payload)
                fragments = frame.final ? nil : message
                if frame.final { try handleResponse(message) }
            default: throw ITerm2APIError.connectionFailed("Expected a binary API message")
            }
        }
    }

    private func handleResponse(_ data: Data) throws {
        let response = try ITerm2Messages.decodeResponse(data)
        guard let id = response.id else { return } // Unsolicited notifications.
        let handler = pending.removeValue(forKey: id)
        if let error = response.error {
            handler?(.failure(ITerm2APIError.serverError(error)))
        } else {
            handler?(.success((response.fieldNumber, response.payload)))
        }
    }

    func send(_ messageData: Data, id: Int64, completion: @escaping (Response) -> Void) {
        queue.async {
            guard let socket = self.transport, self.isConnected else {
                completion(.failure(ITerm2APIError.notConnected)); return
            }
            guard self.pending[id] == nil else {
                completion(.failure(ITerm2APIError.serverError("Duplicate request ID"))); return
            }
            let token = self.generation
            self.pending[id] = completion
            socket.send(WebSocketCodec.encode(messageData)) { [weak self] error in
                guard let self, self.generation == token else { return }
                if let error { self.tearDown(error) }
            }
            self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in
                guard let self, self.generation == token, self.pending[id] != nil else { return }
                // A stalled socket is unusable. Fail all requests promptly and reconnect next time.
                self.tearDown(ITerm2APIError.timeout)
            }
        }
    }

    func request(_ message: (id: Int64, data: Data), expectedField: Int) async throws -> Data {
        let available = await withCheckedContinuation { continuation in
            connect { continuation.resume(returning: $0) }
        }
        guard available else { throw queue.sync { connectionFailure ?? ITerm2APIError.notConnected } }
        let response: (Int, Data) = try await withCheckedThrowingContinuation { continuation in
            send(message.data, id: message.id) { continuation.resume(with: $0) }
        }
        guard response.0 == expectedField else { throw SessionAPIError.unexpectedResponse }
        return response.1
    }

    func listSessions() async throws -> [ITerm2Messages.ParsedWindow] {
        try ITerm2Messages.parseListSessions(await request(ITerm2Messages.listSessions(), expectedField: 106))
    }

    func variables(sessionId: String, names: [String]) async throws -> [String: String] {
        let payload = try await request(ITerm2Messages.variables(sessionId: sessionId, names: names), expectedField: 115)
        let fields = try MessageFields(payload)
        try fields.requireOK("Read session")
        let values = try fields.strings(2)
        guard values.count == names.count else { throw SessionAPIError.unexpectedResponse }
        var result: [String: String] = [:]
        for (name, value) in zip(names, values) {
            if value == "null" { continue }
            let decoded = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
            result[name] = decoded as? String
        }
        return result
    }

    func profiles() async throws -> [String] {
        var body = ProtobufEncoder()
        body.writeString(1, value: "Name")
        let payload = try await request(ITerm2Messages.request(118, body: body), expectedField: 118)
        let profiles = try MessageFields(payload)
        var names: Set<String> = []
        for profile in profiles.bytes[1, default: []] {
            for property in try MessageFields(profile).bytes[1, default: []] {
                let fields = try MessageFields(property)
                if try fields.strings(1).first == "Name", let json = try fields.strings(2).first {
                    names.insert(try JSONDecoder().decode(String.self, from: Data(json.utf8)))
                }
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func activate(sessionId: String) async throws {
        let payload = try await request(ITerm2Messages.activate(sessionId: sessionId), expectedField: 114)
        try MessageFields(payload).requireOK("Activate session")
    }

    func createTab(profileName: String, windowId: String? = nil) async throws {
        let payload = try await request(ITerm2Messages.createTab(profileName: profileName, windowId: windowId), expectedField: 108)
        try MessageFields(payload).requireOK("Create tab")
    }

    func renameSession(sessionId: String, name: String) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionAPIError.invalidName }
        let payload = try await request(ITerm2Messages.rename(sessionId: sessionId, name: name), expectedField: 132)
        let fields = try MessageFields(payload)
        if let error = fields.bytes[1]?.first {
            let reason = try MessageFields(error).strings(2).first ?? "Unable to rename session."
            throw ITerm2APIError.serverError(reason)
        }
        guard fields.bytes[2] != nil else { throw SessionAPIError.unexpectedResponse }
    }

    func splitPane(sessionId: String, profile: String, vertical: Bool) async throws {
        let payload = try await request(ITerm2Messages.split(sessionId: sessionId, profile: profile, vertical: vertical), expectedField: 109)
        try MessageFields(payload).requireOK("Split pane")
    }

    func closeSession(sessionId: String) async throws {
        let payload = try await request(ITerm2Messages.close(sessionId: sessionId), expectedField: 131)
        let fields = try MessageFields(payload)
        guard fields.integers[1]?.count == 1 else { throw SessionAPIError.unexpectedResponse }
        try fields.requireOK("Close session")
    }
}
