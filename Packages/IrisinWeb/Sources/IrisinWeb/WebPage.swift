import Foundation

/// The page's files, served in the clear: nothing in them is secret.
enum WebPage {
    private static let files: [String: (name: String, type: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/page.js": ("page.js", "text/javascript; charset=utf-8"),
        "/page.css": ("page.css", "text/css; charset=utf-8"),
        "/cipher.js": ("cipher.js", "text/javascript; charset=utf-8"),
    ]

    static func response(for path: String) -> HTTPResponse? {
        guard let file = files[path],
              let url = Bundle.module.url(forResource: file.name, withExtension: nil, subdirectory: "Page"),
              let body = try? Data(contentsOf: url)
        else {
            return nil
        }
        var headers = [("Content-Type", file.type)]
        if path == "/" {
            headers.append(("Content-Security-Policy", HTTPResponse.contentSecurityPolicy))
        }
        return HTTPResponse(status: 200, headers: headers, body: body)
    }
}
