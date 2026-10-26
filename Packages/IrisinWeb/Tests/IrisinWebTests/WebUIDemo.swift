import Foundation
@testable import IrisinWeb
import Testing

/// Not a test. `IRISIN_WEB_DEMO=1 swift test --package-path Packages/IrisinWeb
/// --filter WebUIDemo` serves `WebUI/dist` over the real server with made-up
/// answers, so the page can be looked at in a browser on the Mac (run
/// `pnpm watch` in WebUI and reload), as Fila's WebUIDemo does. Requests go
/// asking → running → done after a few seconds, and the operation streams a
/// short transcript. Skipped in a normal run.
@Suite("Web UI demo")
struct WebUIDemo {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IRISIN_WEB_DEMO"] != nil))
    func serve() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent() // Tests/IrisinWebTests
            .deletingLastPathComponent().deletingLastPathComponent() // Packages/IrisinWeb
            .deletingLastPathComponent().deletingLastPathComponent() // the repository
        let dist = repository.appendingPathComponent("WebUI/dist")
        let server = WebServer(responder: DemoResponder(), webRoot: dist, key: WebKey(code: "123456", salt: Data(repeating: 1, count: 16)))
        let port = try await server.start(port: UInt16(ProcessInfo.processInfo.environment["IRISIN_WEB_DEMO_PORT"] ?? "") ?? 8790)
        print("""

        ===== Irisin Web UI =====
        URL:      \(server.url(host: "127.0.0.1"))
        code:     \(server.key.code)
        web root: \(dist.path)
        Ctrl-C to stop.
        =========================

        """)
        fflush(stdout)
        try await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
    }
}

/// Made-up answers in the shapes of Packages/IrisinWeb/README.md.
private actor DemoState {
    var requests: [String: (state: String, started: Date, op: String)] = [:]
    var queued = false
    var operationStarted: Date?

    func ask(_ op: String) -> JSONValue {
        let id = UUID().uuidString
        requests[id] = ("asking", Date(), op)
        return .object(["id": .string(id), "state": .string("asking"), "detail": .null])
    }

    func request(_ id: String) -> JSONValue {
        guard let request = requests[id] else { return .null }
        let elapsed = Date().timeIntervalSince(request.started)
        let state = elapsed < 3 ? "asking" : elapsed < 6 && request.op == "confirm" ? "running" : "done"
        if state == "running", operationStarted == nil {
            operationStarted = Date()
        }
        if state == "done", request.op == "confirm" {
            queued = false
        }
        return .object(["id": .string(id), "state": .string(state), "detail": .null])
    }

    func propose() {
        queued = true
    }

    func clear() {
        queued = false
    }

    var busy: Bool {
        operationStarted.map { Date().timeIntervalSince($0) < 4 } ?? false
    }
}

private struct DemoResponder: WebResponder {
    let state = DemoState()

    func answer(_ op: String, _ args: JSONValue) async -> WebAnswer {
        switch op {
        case "device":
            return await .result(.object([
                "name": .string("Demo iPhone"), "model": .string("iPhone17,1"), "system": .string("iOS 27.0.1"),
                "bootstrap": .string("RootHide"), "architecture": .string("iphoneos-arm64e"),
                "irisinVersion": .string("5.1.0"), "freeSpace": .integer(32_000_000_000), "busy": .bool(state.busy),
            ]))
        case "repositories":
            return .result(.array([
                .object(["url": .string("https://apt.procurs.us/"), "name": .string("Procursus"), "packageCount": .integer(1832),
                         "refreshed": .string("2026-10-26T08:00:00Z"), "refreshing": .bool(false), "problem": .null]),
                .object(["url": .string("https://havoc.app/"), "name": .string("Havoc"), "packageCount": .integer(0),
                         "refreshed": .null, "refreshing": .bool(false), "problem": .string("The server answered 503.")]),
            ]))
        case "search":
            let query = args["query"]?.string ?? ""
            return .result(.array((1 ... 6).map { index in
                .object(["id": .string("com.example.\(query.lowercased())\(index)"), "name": .string("\(query) \(index)"),
                         "version": .string("1.\(index).0"), "section": .string("Tweaks"),
                         "summary": .string("A package about \(query), number \(index)."), "repository": .string("Procursus"),
                         "installed": index == 2 ? .string("1.1.0") : .null])
            }))
        case "package":
            let id = args["id"]?.string ?? "com.example.demo"
            return .result(.object([
                "id": .string(id), "name": .string("Demo Package"), "version": .string("1.2.0"),
                "versions": .array([.string("1.2.0"), .string("1.1.0")]), "section": .string("Tweaks"),
                "author": .string("Someone <someone@example.com>"), "maintainer": .string("Someone"),
                "summary": .string("Shows what a package page looks like."),
                "description": .string("A longer description.\nIt keeps its line breaks."),
                "depends": .string("firmware (>= 15.0), mobilesubstrate"), "repository": .string("Procursus"),
                "installed": .string("1.1.0"), "size": .integer(48213), "installedSize": .integer(204_800),
                "homepage": .string("https://example.com/"),
            ]))
        case "installed":
            return .result(.array(["bash", "coreutils", "dpkg", "firmware"].map {
                .object(["id": .string($0), "name": .string($0), "version": .string("1.0"), "section": .string("System")])
            }))
        case "updates":
            return .result(.array([.object(["id": .string("bash"), "name": .string("bash"), "installed": .string("5.2"),
                                            "available": .string("5.3"), "repository": .string("Procursus")])]))
        case "propose":
            await state.propose()
            return await answer("plan", .null)
        case "plan":
            guard await state.queued else { return .result(.null) }
            return .result(.object([
                "id": .string("demo-plan"),
                "install": .array([.object(["id": .string("com.example.demo"), "name": .string("Demo Package"),
                                            "version": .string("1.2.0"), "repository": .string("Procursus"), "size": .integer(48213)])]),
                "remove": .array([]), "downloadSize": .integer(48213), "notes": .array([]),
            ]))
        case "clear":
            await state.clear()
            return .result(.object([:]))
        case "refresh":
            return .result(.object([:]))
        case "confirm", "addRepository", "removeRepository", "respring":
            return await .result(state.ask(op))
        case "request":
            return await .result(state.request(args["id"]?.string ?? ""))
        default:
            return .failure("The demo does not answer \(op).")
        }
    }

    func stream(after: Int, send: @escaping @Sendable (JSONValue) async -> Bool) async {
        let frames: [JSONValue] = [
            .object(["line": .string("Preparing")]),
            .object(["package": .string("com.example.demo"), "step": .string("verifying")]),
            .object(["progress": .object(["completed": .integer(1), "total": .integer(3)])]),
            .object(["package": .string("com.example.demo"), "step": .string("unpacking")]),
            .object(["line": .string("Unpacking com.example.demo (1.2.0)")]),
            .object(["progress": .object(["completed": .integer(2), "total": .integer(3)])]),
            .object(["package": .string("com.example.demo"), "step": .string("configuring")]),
            .object(["line": .string("Setting up com.example.demo (1.2.0)")]),
            .object(["package": .string("com.example.demo"), "step": .string("done")]),
            .object(["progress": .object(["completed": .integer(3), "total": .integer(3)])]),
            .object(["end": .bool(true), "succeeded": .bool(true), "status": .integer(0)]),
        ]
        for (index, frame) in frames.enumerated() where index + 1 > after {
            guard case var .object(fields) = frame else { continue }
            fields["seq"] = .integer(index + 1)
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard await send(.object(fields)) else { return }
        }
    }
}
