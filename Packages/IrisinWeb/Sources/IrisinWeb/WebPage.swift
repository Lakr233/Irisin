import Foundation

/// The page's files, read from the web root at each request and served in
/// the clear: nothing in them is secret. `WebUI/` builds them and the app's
/// Build Web UI phase copies them into `irisin.app/WebUI`, as Fila's do:
/// `index.html` at `/`, everything else at `/_irisin/<name>`, by bare name.
enum WebPage {
    static let assetPrefix = "/_irisin/"

    private static let types = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "png": "image/png",
    ]

    static func response(for path: String, in root: URL?) -> HTTPResponse? {
        guard let root else { return nil }
        let name: String
        if path == "/" {
            name = "index.html"
        } else if path.hasPrefix(assetPrefix) {
            name = String(path.dropFirst(assetPrefix.count))
            // a bare name, or nothing: no folder, no way out of the root
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), name != "index.html" else { return nil }
        } else {
            return nil
        }
        guard let type = types[(name as NSString).pathExtension.lowercased()],
              let body = try? Data(contentsOf: root.appendingPathComponent(name))
        else {
            return nil
        }
        var headers = [("Content-Type", type)]
        if name == "index.html" {
            headers.append(("Content-Security-Policy", HTTPResponse.contentSecurityPolicy))
        }
        return HTTPResponse(status: 200, headers: headers, body: body)
    }
}
