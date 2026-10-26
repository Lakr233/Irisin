import Foundation
@testable import IrisinWeb
import Testing

/// What the parser takes, waits for and refuses.
struct HTTPMessageTests {
    private func parse(_ text: String) -> HTTPRequest.Parse {
        HTTPRequest.parse(Data(text.utf8))
    }

    @Test func aRequestWithItsBody() {
        guard case let .request(request) = parse("POST /api/v1/call?x=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello")
        else {
            Issue.record("not parsed")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/api/v1/call")
        #expect(request.query == ["x": "1"])
        #expect(request.headers["host"] == "a")
        #expect(request.body == Data("hello".utf8))
    }

    @Test func waitsForTheHeadAndTheBody() {
        #expect(parse("GET / HTTP/1.1\r\nHost: a\r\n") == .incomplete)
        #expect(parse("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel") == .incomplete)
    }

    @Test(arguments: [
        ("GET / HTTP/1.1 extra\r\n\r\n", 400),
        ("GET nothing HTTP/1.1\r\n\r\n", 400),
        ("GET / SPDY/3\r\n\r\n", 400),
        ("GET / HTTP/1.1\r\nno colon\r\n\r\n", 400),
        ("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", 400),
        ("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", 411),
        ("POST / HTTP/1.1\r\nContent-Length: 9999999\r\n\r\n", 413),
    ])
    func refuses(text: String, status: Int) {
        #expect(parse(text) == .refused(status: status))
    }

    @Test func aHeadTooLargeIsRefusedBeforeItEnds() {
        let text = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequest.Limits.head + 10)
        #expect(parse(text) == .refused(status: 431))
    }

    @Test func everyAnswerClosesAndIsNotCached() {
        let text = String(decoding: HTTPResponse.json(Data("{}".utf8)).serialized, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Cache-Control: no-store\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }
}
