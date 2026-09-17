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
    /// What an adapter prepends to the Pre-Depends of every package it
    /// rewrites. The adapter runs after resolution, so the solver has to
    /// hear of it here or the plan would miss what the helper then demands.
    public let adaptedPreDepends: String?
    public let blockedUpdates: Set<String>
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

    public init(
        packages: [Package],
        installed: [Package],
        architecture: String,
        installableArchitectures: Set<String>? = nil,
        adaptedPreDepends: String? = nil,
        blockedUpdates: Set<String> = [],
        origins: [String: URL] = [:],
        autoInstalled: Set<String> = [],
        statusDigest: String = "",
        catalogueRevision: Int64 = 0
    ) {
        self.packages = packages
        self.installed = installed
        self.architecture = architecture
        self.installableArchitectures = installableArchitectures ?? [architecture]
        self.adaptedPreDepends = adaptedPreDepends
        self.blockedUpdates = blockedUpdates
        self.origins = origins
        self.autoInstalled = autoInstalled
        self.statusDigest = statusDigest
        self.catalogueRevision = catalogueRevision
    }

    /// Whether `package` reaches this bootstrap through an adapter: accepted,
    /// and not built for it.
    public func adapts(_ package: Package) -> Bool {
        !package.supports(architecture: architecture) && package.supports(anyOf: installableArchitectures)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
