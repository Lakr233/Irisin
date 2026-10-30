import CryptoKit
import Foundation

/// A consistent catalogue and an exact copy of dpkg's status, detached from WCDB.
public struct ResolutionSnapshot: Sendable {
    public let packages: [Package]
    public let installed: [Package]
    /// The bootstrap's architecture: what a candidate must carry, or
    /// `all`, to be picked.
    public let architecture: String
    public let blockedUpdates: Set<String>
    /// The repository each installed identity came from, for those this
    /// app installed, while that repository still lists it. An identity
    /// follows its repository: only that repository's versions are
    /// candidates for it. An identity with no origin has none to keep to
    /// and takes the newest from any, and so does one whose repository was
    /// removed or no longer lists it: an origin no repository answers for
    /// would keep the package where it is for good, and every update that
    /// needs a newer one with it.
    public let origins: [String: URL]
    /// Installed identities APT marks `Auto-Installed`: they came in as a
    /// dependency, and may go once nothing that was asked for needs them.
    public let autoInstalled: Set<String>
    public let statusDigest: String
    public let catalogueRevision: Int64
    /// The database the catalogue was read from, nil for a snapshot made
    /// by hand. Two snapshots of one database at one revision hold the same
    /// packages: every write to them moves the revision in its own
    /// transaction.
    public let catalogueIdentity: UUID?

    public init(
        packages: [Package],
        installed: [Package],
        architecture: String,
        blockedUpdates: Set<String> = [],
        origins: [String: URL] = [:],
        autoInstalled: Set<String> = [],
        statusDigest: String = "",
        catalogueRevision: Int64 = 0,
        catalogueIdentity: UUID? = nil
    ) {
        self.packages = packages
        self.installed = installed
        self.architecture = architecture
        self.blockedUpdates = blockedUpdates
        let listed = Set(packages.lazy.filter { package in
            origins[package.identity].map { $0 == package.repoRef } == true
        }.map(\.identity))
        self.origins = origins.filter { listed.contains($0.key) }
        self.autoInstalled = autoInstalled
        self.statusDigest = statusDigest
        self.catalogueRevision = catalogueRevision
        self.catalogueIdentity = catalogueIdentity
    }

    /// Whether `other` was read from the same database at the same
    /// revision, and so holds the same packages. Never for a snapshot made
    /// by hand.
    public func sharesCatalogue(with other: ResolutionSnapshot) -> Bool {
        catalogueIdentity != nil && catalogueIdentity == other.catalogueIdentity
            && catalogueRevision == other.catalogueRevision
    }

    /// What moved in the database or on the device since a snapshot was
    /// read (`PackageIndex.changes(since:)`).
    public struct Changes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// A repository was written: refreshed, added or removed.
        public static let catalogue = Changes(rawValue: 1 << 0)
        /// dpkg's status is not the one read.
        public static let installed = Changes(rawValue: 1 << 1)
        /// The architecture or the blocked updates.
        public static let settings = Changes(rawValue: 1 << 2)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
