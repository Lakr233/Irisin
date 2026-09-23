import Foundation

/// Answers `URLSession.shared` for the hosts it was given: a file, 404 for
/// anything else, no answer at all, or a path that answers slowly, stops
/// halfway or fails on its own. Counts what each host was asked.
final class StubServer: URLProtocol, @unchecked Sendable {
    /// How one path answers besides handing a file over at once.
    enum Behavior: Sendable {
        /// the status, with an empty body
        case status(Int)
        /// `chunks` pieces of `chunk`, one every `every` seconds, then done
        case trickle(chunk: Data, every: TimeInterval, chunks: Int)
        /// 200 and these bytes, then silence for good
        case stallAfter(Data)
        /// no answer at all, as a connection that never completes
        case hang
        /// no answer, for this reason
        case fail(URLError.Code)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var files = [String: [String: Data]]()
    private nonisolated(unsafe) static var behaviors = [String: [String: Behavior]]()
    private nonisolated(unsafe) static var failing = [String: URLError.Code]()
    private nonisolated(unsafe) static var asked = [String: [String]]()
    private nonisolated(unsafe) static var registered = false

    /// the timer of a slow answer, stopped with the request
    private var timer: Timer?

    static func serve(_ served: [String: Data], on host: String, behaving: [String: Behavior] = [:]) {
        lock.withLock {
            // `fail(host:)` comes first for a host that is to stay silent
            files[host] = served
            behaviors[host] = behaving
            if !registered {
                registered = true
                URLProtocol.registerClass(StubServer.self)
            }
        }
    }

    static func fail(host: String, with code: URLError.Code = .notConnectedToInternet) {
        lock.withLock { failing[host] = code }
    }

    /// The paths asked of `host`, in the order asked.
    static func requests(to host: String) -> [String] {
        lock.withLock { asked[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { files[host] != nil || failing[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let (body, behavior, failure) = Self.lock.withLock {
            Self.asked[host, default: []].append(url.path)
            return (Self.files[host]?[url.path], Self.behaviors[host]?[url.path], Self.failing[host])
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        switch behavior {
        case let .status(code):
            respond(url, code)
            client?.urlProtocolDidFinishLoading(self)
        case let .trickle(chunk, every, chunks):
            respond(url, 200)
            var sent = 0
            schedule(every: every) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                client?.urlProtocol(self, didLoad: chunk)
                sent += 1
                if sent == chunks {
                    timer.invalidate()
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        case let .stallAfter(data):
            respond(url, 200)
            client?.urlProtocol(self, didLoad: data)
        case .hang:
            break
        case let .fail(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            respond(url, body == nil ? 404 : 200)
            client?.urlProtocol(self, didLoad: body ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        timer?.invalidate()
    }

    private func respond(_ url: URL, _ code: Int) {
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    /// A repeating timer on the loading thread's run loop, where the
    /// client expects to be called.
    private func schedule(every: TimeInterval, _ tick: @escaping (Timer) -> Void) {
        let timer = Timer(timeInterval: every, repeats: true, block: tick)
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }
}
