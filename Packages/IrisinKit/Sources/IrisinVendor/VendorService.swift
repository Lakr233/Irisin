import Foundation

/// Sileo-style payment endpoints, one request each: the app and the
/// command line both ask through here, so a vendor sees one client. Each
/// call is a POST of a JSON object carrying the account token and the
/// device (the vendor answers "remote failed" without the udid), and
/// answers a JSON object.
public enum VendorService {
    /// Why a vendor gave no usable answer, spelt for a log line.
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case transport(String)
        case status(Int)
        case notAnObject(bytes: Int)

        public var description: String {
            switch self {
            case let .transport(reason): "failed: \(reason)"
            case let .status(code): "answered HTTP \(code)"
            case let .notAnObject(bytes): "did not answer with a JSON object, \(bytes) bytes"
            }
        }
    }

    public struct PurchaseStatus: Sendable, Equatable {
        public let purchased: Bool?
        public let available: Bool?
    }

    /// The page that signs in; its callback (`sileo://`) carries the token
    /// and the payment secret back to whoever opened it. The order of the
    /// two parameters is the one vendors expect.
    public static func signInURL(endpoint: URL, device: VendorDevice) -> URL {
        let authenticate = endpoint.appendingPathComponent("authenticate")
        guard var components = URLComponents(url: authenticate, resolvingAgainstBaseURL: false) else {
            return authenticate
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "udid", value: device.udid),
            URLQueryItem(name: "model", value: device.machine),
        ]
        return components.url ?? authenticate
    }

    /// The identities of the packages the account has bought.
    public static func purchasedIdentities(
        endpoint: URL,
        credentials: VendorCredentials,
        device: VendorDevice
    ) async throws(Failure) -> [String] {
        let reply = try await send(request(endpoint.appendingPathComponent("user_info"), credentials, device))
        return reply["items"] as? [String] ?? []
    }

    public static func purchaseStatus(
        of identity: String,
        endpoint: URL,
        credentials: VendorCredentials,
        device: VendorDevice
    ) async throws(Failure) -> PurchaseStatus {
        let reply = try await send(request(package(identity, "info", at: endpoint), credentials, device))
        return PurchaseStatus(purchased: reply["purchased"] as? Bool, available: reply["available"] as? Bool)
    }

    /// The page that finishes a purchase; nil when the purchase went
    /// through already (status 0) and there is no page to open.
    public static func purchasePage(
        for identity: String,
        architecture: String,
        endpoint: URL,
        credentials: VendorCredentials,
        device: VendorDevice
    ) async throws(Failure) -> URL? {
        let reply = try await send(request(package(identity, "purchase", at: endpoint), credentials, device, [
            "payment_secret": credentials.secret,
            "architecture": architecture,
        ]))
        guard let status = reply["status"] as? Int, status != 0,
              let action = reply["url"] as? String
        else { return nil }
        return URL(string: action)
    }

    /// The paid file's link for this version and architecture.
    public static func downloadLink(
        for identity: String,
        version: String?,
        architecture: String,
        repository: URL,
        endpoint: URL,
        credentials: VendorCredentials,
        device: VendorDevice
    ) async throws(Failure) -> URL? {
        let reply = try await send(request(package(identity, "authorize_download", at: endpoint), credentials, device, [
            "version": version,
            "repo": repository.absoluteString,
            "payment_secret": credentials.secret,
            "architecture": architecture,
        ]))
        return (reply["url"] as? String).flatMap(URL.init(string:))
    }

    /// Tells the vendor the account left this device; the answer changes
    /// nothing here and is handed back only to be logged.
    public static func signOut(endpoint: URL, credentials: VendorCredentials, device: VendorDevice) async -> String? {
        var request = URLRequest(url: endpoint.appendingPathComponent("sign_out"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = json([
            "token": credentials.token,
            "udid": device.udid,
            "device": device.machine,
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Wire

    /// `<endpoint>/package/<identity>/<action>`, also what a failure's log
    /// line names.
    public static func package(_ identity: String, _ action: String, at endpoint: URL) -> URL {
        endpoint.appendingPathComponent("package").appendingPathComponent(identity).appendingPathComponent(action)
    }

    /// A signed-in call: the account token and the device go with every
    /// payload, and a key the payload already has keeps its own value.
    static func request(
        _ url: URL,
        _ credentials: VendorCredentials,
        _ device: VendorDevice,
        _ payload: [String: String?] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json(payload.merging([
            "token": credentials.token,
            "udid": device.udid,
            "device": device.machine,
        ]) { current, _ in current })
        return request
    }

    static func json(_ payload: [String: String?]) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: payload.compactMapValues(\.self),
            options: .fragmentsAllowed
        )) ?? Data()
    }

    static func send(_ request: URLRequest) async throws(Failure) -> [String: Any] {
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw Failure.status(http.statusCode)
            }
            data = body
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .transport(error.localizedDescription)
        }
        return try object(from: data)
    }

    static func object(from data: Data) throws(Failure) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any]
        else { throw .notAnObject(bytes: data.count) }
        return object
    }
}
