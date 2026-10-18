import Foundation
import IrisinProtocol

/// What this helper tells the maintainer scripts it runs about itself, as
/// `IRISIN_INSTALLER_*` in their environment. dpkg sets none of them, so a
/// script can tell Irisin's helper from dpkg and leave to it what it does
/// itself: Irisin's own postinst skips its icon rebuild under the helper,
/// which registers the apps a transaction changed and leaves Irisin's own
/// to the app as it exits.
public struct InstallerIdentity: Equatable, Sendable {
    /// Who asked for the transaction.
    public enum Client: String, Sendable {
        /// Irisin's own app.
        case app
        /// Another package's program, through the external operations.
        case external
    }

    /// `CFBundleShortVersionString`, the release: `4.7.1`.
    public var version: String
    /// `CFBundleVersion`, the build number.
    public var build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    /// The helper's own, from the Info.plist linked into its binary
    /// (`CREATE_INFOPLIST_SECTION_IN_BINARY`). A build without one says
    /// `0`, never nothing: the scripts test the variable for being set.
    public static var current: InstallerIdentity {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String {
            guard let text = info[key] as? String, !text.isEmpty else { return "0" }
            return text
        }
        return InstallerIdentity(version: value("CFBundleShortVersionString"), build: value("CFBundleVersion"))
    }

    /// The variables, for a transaction `client` asked for; `transaction`
    /// is an external client's own id.
    func environment(client: Client, transaction: String? = nil) -> [String: String] {
        var environment = [
            "IRISIN_INSTALLER_VERSION": version,
            "IRISIN_INSTALLER_BUILD": build,
            "IRISIN_INSTALLER_PROTOCOL": String(IrisinWire.version),
            "IRISIN_INSTALLER_CLIENT": client.rawValue,
        ]
        if let transaction {
            environment["IRISIN_INSTALLER_TRANSACTION"] = transaction
        }
        return environment
    }
}
