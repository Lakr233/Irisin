import Foundation

/// One HTTP/1.1 request, as much of it as the server reads: the method, the
/// path without its query, the query's items, the headers (names lowercased)
/// and a body of at most `Limits.body` bytes, by `Content-Length` alone.
struct HTTPRequest: Equatable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    enum Limits {
        static let head = 16 * 1024
        static let body = 256 * 1024
    }

    enum Parse: Equatable {
        /// More bytes are needed.
        case incomplete
        case request(HTTPRequest)
        /// Nothing more will make it a request this server takes.
        case refused(status: Int)
    }

    /// What `buffer` holds so far.
    static func parse(_ buffer: Data) -> Parse {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Limits.head ? .refused(status: 431) : .incomplete
        }
        guard end.lowerBound <= Limits.head,
              let head = String(data: buffer[buffer.startIndex ..< end.lowerBound], encoding: .utf8)
        else {
            return .refused(status: 431)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              let components = URLComponents(string: String(requestLine[1])), requestLine[1].hasPrefix("/")
        else {
            return .refused(status: 400)
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .refused(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { return .refused(status: 400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .refused(status: 411)
        }
        let length: Int
        if let value = headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else { return .refused(status: 400) }
            length = parsed
        } else {
            length = 0
        }
        guard length <= Limits.body else { return .refused(status: 413) }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return .request(HTTPRequest(
            method: String(requestLine[0]),
            path: components.path,
            query: query,
            headers: headers,
            body: Data(buffer[bodyStart ..< bodyStart + length])
        ))
    }
}

/// What the server answers with. Every answer closes its connection, and
/// none is cached.
struct HTTPResponse {
    var status: Int
    var headers: [(String, String)]
    var body: Data

    static let reasons = [
        200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        408: "Request Timeout", 411: "Length Required", 413: "Content Too Large",
        431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable",
    ]

    /// What every answer carries.
    static let common = [
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("Connection", "close"),
    ]

    /// The page's own: its script and style from this server alone, and
    /// nothing inline, since a script injected into the page could read the
    /// key it keeps.
    static let contentSecurityPolicy = "default-src 'none'; script-src 'self'; style-src 'self'; "
        + "img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    static func status(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: [], body: Data())
    }

    static func json(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8")], body: data)
    }

    /// The head alone, for an answer whose body follows as it is made and
    /// ends when the connection does.
    static func streamHead(contentType: String) -> Data {
        head(status: 200, headers: [("Content-Type", contentType)], length: nil)
    }

    var serialized: Data {
        Self.head(status: status, headers: headers, length: body.count) + body
    }

    private static func head(status: Int, headers: [(String, String)], length: Int?) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reasons[status] ?? "Status")"]
        for (name, value) in headers + common {
            lines.append("\(name): \(value)")
        }
        if let length {
            lines.append("Content-Length: \(length)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}
