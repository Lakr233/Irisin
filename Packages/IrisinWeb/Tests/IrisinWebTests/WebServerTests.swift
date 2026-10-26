import CryptoKit
import Foundation
@testable import IrisinWeb
import Testing

/// The server on the Mac's loopback, called the way the page calls it.
@Suite(.serialized)
struct WebServerTests {
    /// Answers `echo` with its arguments and `fail` with a failure, streams
    /// three lines.
    struct Responder: WebResponder {
        func answer(_ op: String, _ args: JSONValue) async -> WebAnswer {
            op == "echo" ? .result(args) : .failure("no \(op)")
        }

        func stream(after: Int, send: @escaping @Sendable (JSONValue) async -> Bool) async {
            for sequence in after + 1 ... 3 {
                guard await send(.object(["seq": .integer(sequence), "line": .string("line \(sequence)")])) else { return }
            }
        }

        func words() async -> [String: String] {
            ["code": "Code"]
        }
    }

    private let key = WebKey(code: "123456", salt: Data(repeating: 7, count: 16))

    private func withServer(_ body: (WebServer, URL) async throws -> Void) async throws {
        let server = WebServer(responder: Responder(), key: key)
        let port = try await server.start(port: 18790)
        defer { server.stop() }
        try await body(server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    private func post(_ url: URL, _ body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    private func sealedCall(_ value: JSONValue, with key: WebKey) throws -> (nonce: String, body: Data) {
        let envelope = try SealedEnvelope.seal(value.encoded(), for: .call, with: key)
        return try (envelope.n, JSONEncoder().encode(envelope))
    }

    @Test func servesThePageWithItsPolicyAndTheHello() async throws {
        try await withServer { _, base in
            let (_, response) = try await URLSession.shared.data(from: base.appendingPathComponent("/"))
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200)
            #expect(http.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("script-src 'self'") == true)
            let (hello, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/v1/hello"))
            #expect(try JSONValue.decode(hello)["salt"]?.string == key.salt.base64EncodedString())
            let (words, _) = try await URLSession.shared.data(from: base.appendingPathComponent("api/v1/strings"))
            #expect(try JSONValue.decode(words)["code"]?.string == "Code")
            let (_, missing) = try await URLSession.shared.data(from: base.appendingPathComponent("nothing"))
            #expect((missing as? HTTPURLResponse)?.statusCode == 404)
        }
    }

    @Test func aSealedCallIsAnsweredSealedToItsNonce() async throws {
        try await withServer { _, base in
            let args = JSONValue.object(["q": .string("中文")])
            let call = try sealedCall(.object(["op": .string("echo"), "args": args]), with: key)
            let (data, status) = try await post(base.appendingPathComponent("api/v1/call"), call.body)
            #expect(status == 200)
            let envelope = try JSONDecoder().decode(SealedEnvelope.self, from: data)
            #expect(envelope.open(for: .answer(to: "another nonce"), with: key) == nil)
            let answer = try JSONValue.decode(#require(envelope.open(for: .answer(to: call.nonce), with: key)))
            #expect(answer == .object(["ok": .bool(true), "result": args]))

            let failing = try sealedCall(.object(["op": .string("nope")]), with: key)
            let (failed, _) = try await post(base.appendingPathComponent("api/v1/call"), failing.body)
            let failure = try JSONDecoder().decode(SealedEnvelope.self, from: failed).open(for: .answer(to: failing.nonce), with: key)
            #expect(try JSONValue.decode(#require(failure))["error"]?.string == "no nope")
        }
    }

    @Test func whatDoesNotOpenOrWasSeenIsRefused() async throws {
        try await withServer { _, base in
            let url = base.appendingPathComponent("api/v1/call")
            let call = try sealedCall(.object(["op": .string("echo")]), with: key)
            #expect(try await post(url, call.body).1 == 200)
            #expect(try await post(url, call.body).1 == 403)
            let stranger = WebKey(code: "654321", salt: key.salt)
            #expect(try await post(url, sealedCall(.object(["op": .string("echo")]), with: stranger).body).1 == 403)
            #expect(try await post(url, Data("{}".utf8)).1 == 403)
            let asStream = try JSONEncoder().encode(SealedEnvelope.seal(
                JSONValue.object(["op": .string("echo")]).encoded(), for: .stream, with: key
            ))
            #expect(try await post(url, asStream).1 == 403)
        }
    }

    @Test func aStreamIsSealedFramesInOrder() async throws {
        try await withServer { _, base in
            let envelope = try SealedEnvelope.seal(JSONValue.object(["after": .integer(1)]).encoded(), for: .stream, with: key)
            let (data, status) = try await post(base.appendingPathComponent("api/v1/stream"), JSONEncoder().encode(envelope))
            #expect(status == 200)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            #expect(lines.count == 2)
            for (offset, line) in lines.enumerated() {
                let frame = try JSONDecoder().decode(SealedEnvelope.self, from: Data(line.utf8))
                let opened = try #require(frame.open(for: .frame(of: envelope.n, index: offset + 1), with: key))
                #expect(try JSONValue.decode(opened)["seq"]?.integer == offset + 2)
            }
        }
    }

    @Test func theURLCarriesTheCodeInItsFragment() async throws {
        try await withServer { server, _ in
            #expect(server.url(host: "192.168.1.5") == "http://192.168.1.5:\(server.port)/#123456")
        }
    }

    @Test func aFreshKeyHasSixDigitsAndItsOwnSalt() {
        let first = WebKey()
        let second = WebKey()
        #expect(first.code.count == 6 && first.code.allSatisfy(\.isNumber))
        #expect(first.salt.count == 16 && first.salt != second.salt)
    }
}
