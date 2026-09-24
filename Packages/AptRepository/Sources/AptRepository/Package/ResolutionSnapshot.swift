import CryptoKit
import Foundation

/// A consistent catalogue and an exact copy of dpkg's status, detached from WCDB.
public struct ResolutionSnapshot: Sendable {
    public let packages: [Package]
    public let installed: [Package]
    /// The bootstrap's own architecture: what the solver treats as native.
    public let architecture: String
    /// What a candidate may carry and still be picked: `architecture` plus
    /// every one an adapter rewrites into it.
    public let installableArchitectures: Set<String>
    /// A control paragraph (lowercase field names) to the one its adapter
    /// expects to leave it with.
    public typealias ManifestPreview = @Sendable ([String: String]) -> [String: String]
    /// The adapters' preview of a package they rewrite. The adapter runs
    /// after resolution, so the solver has to hear here of the relations it
    /// adds or the plan would miss what the helper then demands.
    public let adaptedManifestPreview: ManifestPreview?
    /// The control paragraph the adapter did write, for the packages it has
    /// been through: solved with that from then on, never the preview. A
    /// package whose file gave it no reason for the compat layer (a theme:
    /// no code to load) loses it here.
    public var adaptedManifests: [Package: [String: String]] = [:]
    public let blockedUpdates: Set<String>
    /// Whether updating everything may move an installed package to a
    /// version an adapter would have to rewrite. Asked for by name, such a
    /// version installs either way.
    public let offersAdaptedUpdates: Bool
    /// The repository each installed identity came from, for those this
    /// app installed. An identity follows its repository: only that
    /// repository's versions are candidates for it. An identity with no
    /// origin has none to keep to and takes the newest from any.
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
        installableArchitectures: Set<String>? = nil,
        adaptedManifestPreview: ManifestPreview? = nil,
        blockedUpdates: Set<String> = [],
        offersAdaptedUpdates: Bool = true,
        origins: [String: URL] = [:],
        autoInstalled: Set<String> = [],
        statusDigest: String = "",
        catalogueRevision: Int64 = 0,
        catalogueIdentity: UUID? = nil
    ) {
        self.packages = packages
        self.installed = installed
        self.architecture = architecture
        self.installableArchitectures = installableArchitectures ?? [architecture]
        self.adaptedManifestPreview = adaptedManifestPreview
        self.blockedUpdates = blockedUpdates
        self.offersAdaptedUpdates = offersAdaptedUpdates
        self.origins = origins
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

    /// Whether `package` reaches this bootstrap through an adapter: accepted,
    /// and not built for it.
    public func adapts(_ package: Package) -> Bool {
        !package.supports(architecture: architecture) && package.supports(anyOf: installableArchitectures)
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
        /// The architectures, the blocked updates or whether an update may
        /// be adapted.
        public static let settings = Changes(rawValue: 1 << 2)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
