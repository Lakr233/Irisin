import Foundation
import Network

/// The page's server, on Network.framework: one request per connection, then
/// the connection closes. The page is served in the clear, from `webRoot`;
/// every call and stream is opened with this start's key before the
/// responder sees it, and what does not open is refused (403) and answered
/// nothing else.
public final class WebServer: @unchecked Sendable {
    public let key: WebKey
    private let responder: any WebResponder
    /// The built page (`WebUI/dist`, `irisin.app/WebUI`); nil serves none.
    private let webRoot: URL?
    private let queue = DispatchQueue(label: "wiki.qaq.irisin.web")
    // Everything below is the queue's.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var answered: Set<ObjectIdentifier> = []
    private var nonces: Set<String> = []
    private var listening: UInt16 = 0

    static let maximumConnections = 32
    /// How long a request may take to arrive.
    static let requestTimeout: TimeInterval = 15

    public init(responder: any WebResponder, webRoot: URL?, key: WebKey = WebKey()) {
        self.responder = responder
        self.webRoot = webRoot
        self.key = key
    }

    /// The port it listens on, 0 before `start`.
    public var port: UInt16 {
        queue.sync { listening }
    }

    /// Listens on `port`, or on the first free one of the nine after it, on
    /// every interface but cellular. Answers the port it took.
    @discardableResult
    public func start(port: UInt16 = 8790) async throws -> UInt16 {
        var lastError: Error = NWError.posix(.EADDRINUSE)
        for candidate in port ..< port &+ 10 {
            do {
                try await listen(on: candidate)
                return candidate
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            listening = 0
            for connection in connections.values {
                connection.cancel()
            }
            connections = [:]
        }
    }

    /// The address a browser opens, the code in its fragment.
    public func url(host: String) -> String {
        "http://\(host):\(port)/#\(key.code)"
    }

    private func listen(on port: UInt16) async throws {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: parameters, on: endpointPort)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // the handler runs on the queue, one state at a time
            let resumed = Flag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed.raise() else { return }
                    self?.listener = listener
                    self?.listening = port
                    continuation.resume()
                case let .failed(error):
                    listener.cancel()
                    guard !resumed.raise() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard !resumed.raise() else { return }
                    continuation.resume(throwing: NWError.posix(.ECANCELED))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    // MARK: Connections (on the queue)

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
                self?.answered.remove(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard let self, connections[id] != nil, !answered.contains(id) else { return }
            send(.status(408), on: connection)
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                guard !isComplete, error == nil else {
                    connection.cancel()
                    return
                }
                receive(on: connection, buffer: buffer)
            case let .refused(status):
                send(.status(status), on: connection)
            case let .request(request):
                answered.insert(ObjectIdentifier(connection))
                handle(request, on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        answered.insert(ObjectIdentifier(connection))
        connection.send(content: response.serialized, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/api/v1/hello"):
            let hello = JSONValue.object(["version": .integer(1), "salt": .string(key.salt.base64EncodedString())])
            send((try? hello.encoded()).map(HTTPResponse.json) ?? .status(500), on: connection)
        case ("POST", "/api/v1/call"):
            guard let (nonce, call) = open(request.body, for: .call), let op = call["op"]?.string else {
                return send(.status(403), on: connection)
            }
            Task {
                let answer = switch await responder.answer(op, call["args"] ?? .null) {
                case let .result(value): JSONValue.object(["ok": .bool(true), "result": value])
                case let .failure(message): JSONValue.object(["ok": .bool(false), "error": .string(message)])
                }
                let body = try? JSONEncoder().encode(SealedEnvelope.seal(answer.encoded(), for: .answer(to: nonce), with: key))
                queue.async { self.send(body.map(HTTPResponse.json) ?? .status(500), on: connection) }
            }
        case ("POST", "/api/v1/stream"):
            guard let (nonce, call) = open(request.body, for: .stream) else {
                return send(.status(403), on: connection)
            }
            stream(after: call["after"]?.integer ?? 0, nonce: nonce, on: connection)
        case ("GET", _):
            send(WebPage.response(for: request.path, in: webRoot) ?? .status(404), on: connection)
        default:
            send(.status(request.path.hasPrefix("/api/") ? 405 : 404), on: connection)
        }
    }

    /// The call's nonce and its plaintext, once; a nonce seen before this
    /// start is refused, so a recorded call cannot be sent again.
    private func open(_ body: Data, for purpose: SealedEnvelope.Purpose) -> (String, JSONValue)? {
        guard let envelope = try? JSONDecoder().decode(SealedEnvelope.self, from: body),
              let plaintext = envelope.open(for: purpose, with: key),
              let value = try? JSONValue.decode(plaintext),
              nonces.insert(envelope.n).inserted
        else {
            return nil
        }
        return (envelope.n, value)
    }

    /// The operation's lines, one sealed frame a line, until the responder
    /// is done or the page has gone; then the connection closes.
    private func stream(after: Int, nonce: String, on connection: NWConnection) {
        let responder = responder
        let key = key
        let frames = FrameCounter()
        connection.send(
            content: HTTPResponse.streamHead(contentType: "application/x-ndjson"),
            completion: .contentProcessed { _ in }
        )
        Task {
            await responder.stream(after: after) { frame in
                let index = frames.next()
                guard let data = try? JSONEncoder().encode(SealedEnvelope.seal(frame.encoded(), for: .frame(of: nonce, index: index), with: key))
                else { return false }
                return await withCheckedContinuation { continuation in
                    connection.send(content: data + Data("\n".utf8), completion: .contentProcessed { error in
                        continuation.resume(returning: error == nil)
                    })
                }
            }
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

/// Raised once, and says whether it already was.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = raised
        raised = true
        return was
    }
}

/// The index of each frame of one stream.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
