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

    private func sendSync(_ messageData: Data, id: Int64) -> Response {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Response = .failure(ITerm2APIError.timeout)
        send(messageData, id: id) { response in
            result = response
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    // MARK: - High-Level API

    func listSessions() -> [ITerm2Messages.ParsedWindow] {
        let (id, data) = ITerm2Messages.listSessions()
        switch sendSync(data, id: id) {
        case .success(let (fieldNumber, payload)):
            guard fieldNumber == 106 else {
                SHLog.log("[API] Unexpected response field \(fieldNumber) for listSessions")
                return []
            }
            do {
                return try ITerm2Messages.parseListSessions(payload)
            } catch {
                SHLog.log("[API] Failed to parse ListSessionsResponse: \(error)")
                return []
            }
        case .failure(let error):
            SHLog.log("[API] listSessions failed: \(error)")
            return []
        }
    }

    func getProfileName(sessionId: String) -> String? {
        let (id, data) = ITerm2Messages.getProfileProperty(sessionId: sessionId, keys: ["Name"])
        switch sendSync(data, id: id) {
        case .success(let (fieldNumber, payload)):
            guard fieldNumber == 110 else { return nil }
            if let props = try? ITerm2Messages.parseGetProfileProperty(payload),
               let nameProp = props.first(where: { $0.key == "Name" }) {
                if let jsonData = nameProp.jsonValue.data(using: .utf8),
                   let name = try? JSONSerialization.jsonObject(with: jsonData) as? String {
                    return name
                }
                return nameProp.jsonValue
            }
            return nil
        case .failure:
            return nil
        }
    }

    func activate(sessionId: String) -> Bool {
        let (id, data) = ITerm2Messages.activate(sessionId: sessionId)
        switch sendSync(data, id: id) {
        case .success(let (fieldNumber, _)):
            return fieldNumber == 114
        case .failure(let error):
            SHLog.log("[API] activate failed: \(error)")
            return false
        }
    }

    func createTab(profileName: String, windowId: String? = nil) -> ITerm2Messages.CreateTabResult? {
        let (id, data) = ITerm2Messages.createTab(profileName: profileName, windowId: windowId)
        switch sendSync(data, id: id) {
        case .success(let (fieldNumber, payload)):
            guard fieldNumber == 108 else { return nil }
            return try? ITerm2Messages.parseCreateTab(payload)
        case .failure:
            return nil
        }
    }

    func renameSession(sessionId: String, name: String) -> Bool {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: name),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return false
        }
        let (id, data) = ITerm2Messages.setProfileProperty(sessionId: sessionId, key: "Name", jsonValue: jsonString)
        switch sendSync(data, id: id) {
        case .success(let (fieldNumber, _)):
            return fieldNumber == 105
        case .failure:
            return false
        }
    }
}
