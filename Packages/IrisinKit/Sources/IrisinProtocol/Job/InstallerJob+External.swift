import Foundation

public extension InstallerJob {
    /// A transaction another package's program asked for through
    /// `submitInstall` or `removePackage`, under an id it chose.
    ///
    /// No path crosses the wire here either: the helper finds the
    /// transaction's directory from its own install root and the id, and an
    /// install's package arrives as the helper's descriptor 3, which the
    /// daemon passed through from the client unopened.
    struct External: Codable, Equatable, Sendable {
        public enum Action: Codable, Equatable, Sendable {
            /// The package on descriptor 3, which must hash to `sha256`
            /// once copied.
            case install(sha256: String)
            /// One installed package, by id. What depends on it stays, so
            /// such a removal fails.
            case remove(identity: String)
        }

        public var transaction: String
        public var action: Action

        public init(transaction: String, action: Action) {
            self.transaction = transaction
            self.action = action
        }

        /// The descriptor an install's package arrives on.
        public static let packageDescriptor: Int32 = 3

        func validate() throws {
            guard ExternalTransaction.isIdentifier(transaction) else {
                throw IrisinFailure(code: .invalidRequest)
            }
            switch action {
            case let .install(sha256):
                guard InstallerJob.isSHA256Hex(sha256) else { throw IrisinFailure(code: .invalidRequest) }
            case let .remove(identity):
                guard InstallerJob.isPackageIdentity(identity), !ExternalTransaction.isReserved(identity) else {
                    throw IrisinFailure(code: .invalidRequest, path: identity)
                }
            }
        }
    }
}

/// The names and rules external transactions share between the daemon, the
/// helper and the harness.
public enum ExternalTransaction {
    /// A UUID as the client library spells one: 36 characters, lowercase
    /// hexadecimal in groups of 8-4-4-4-12. Nothing else names a directory.
    public static func isIdentifier(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == 0x2D else { return false }
            } else {
                guard (0x30 ... 0x39).contains(byte) || (0x61 ... 0x66).contains(byte) else { return false }
            }
        }
        return true
    }

    /// Irisin's own packages are not an external client's to replace or
    /// remove: the app that would be replaced is the one that reads the
    /// transcript of its own update.
    public static func isReserved(_ identity: String) -> Bool {
        identity.hasPrefix(InstallerJob.selfIdentityPrefix)
    }

    /// The transaction's directory under an install root.
    public static func directory(installRoot: String, transaction: String) -> String {
        installRoot + IrisinWire.transactionsPath + "/" + transaction
    }

    /// The files in a transaction's directory.
    public enum File {
        /// What was asked, written by the daemon before anything starts.
        public static let request = "request.json"
        /// The helper's transcript, one `InstallerOutput` line per event;
        /// line n is event n. The daemon opens it as the helper's standard
        /// output and holds an exclusive `flock` on it that the helper
        /// inherits, so a lock nobody holds and no `exit` line means the
        /// helper is gone.
        public static let journal = "events.jsonl"
        /// The package an install identified, written by the helper once
        /// the archive is read.
        public static let package = "package.json"
        /// The copy of the client's package, removed when the run ends.
        public static let archive = "package.deb"
        /// The prepared tree, removed when the run ends.
        public static let prepared = "prepared"
    }

    public enum Kind: String, Codable, Sendable {
        case install, remove, respring
    }

    /// `request.json`.
    public struct Request: Codable, Equatable, Sendable {
        public var kind: Kind
        public var sha256: String?
        public var identity: String?
        /// Seconds since 1970.
        public var created: Double
        /// The admitted client executable, for the record.
        public var client: String

        public init(kind: Kind, sha256: String? = nil, identity: String? = nil, created: Double, client: String) {
            self.kind = kind
            self.sha256 = sha256
            self.identity = identity
            self.created = created
            self.client = client
        }

        /// Whether a second submission is this one again.
        public func isSameRequest(as other: Request) -> Bool {
            kind == other.kind && sha256 == other.sha256 && identity == other.identity
        }
    }

    /// `package.json`.
    public struct Package: Codable, Equatable, Sendable {
        public var identity: String
        public var version: String

        public init(identity: String, version: String) {
            self.identity = identity
            self.version = version
        }
    }

    public enum State: String, Sendable {
        /// The helper holds the journal and has not written its `exit`.
        case running
        /// The journal ends with `exit` 0.
        case succeeded
        /// The journal ends with a non-zero `exit`.
        case failed
        /// No `exit`, and nobody holds the journal: the helper died or the
        /// device restarted mid-run. What it changed is in the events.
        case interrupted
    }
}
