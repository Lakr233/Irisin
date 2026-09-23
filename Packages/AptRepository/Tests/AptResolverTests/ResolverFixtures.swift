import AptRepository
import AptResolver
import Foundation
import IrisinProtocol
import Testing

func pkg(_ name: String, _ version: String = "1", _ fields: [String: String] = [:], installed: Bool = false, source: String = "https://example.test/") -> Package {
    var metadata = fields
    metadata["package"] = name
    metadata["version"] = version
    metadata["architecture"] = fields["architecture"] ?? "arm64"
    if installed {
        metadata["status"] = fields["status"] ?? "install ok installed"
    } else {
        metadata["filename"] = "\(name)_\(version).deb"
    }
    return Package(identity: name, payload: [version: metadata], repoRef: installed ? nil : URL(string: source))
}

/// `origins` names the repository each installed package came from; an
/// installed package left out has no origin, so an update of everything
/// takes it from any. The default follows every installed package to the
/// fixtures' one repository. `auto` names the installed packages marked
/// `Auto-Installed`. `adapting` names the architectures an adapter rewrites
/// into the fixtures' `arm64`, `adaptedUpdates` whether an update of
/// everything takes their newer versions, and `implied` the Pre-Depends its preview
/// puts in front; `withoutImplied` the adapted packages whose file, once
/// adapted, showed they get none.
func solve(_ available: [Package], installed: [Package] = [], actions: [ResolutionAction], update: Bool = false, blocked: Set<String> = [], origins: [String: String]? = nil, auto: Set<String> = [], autoremove: Set<String> = [], allowSystemRemoval: Bool = false, adapting: Set<String> = [], adaptedUpdates: Bool = true, implied: String? = nil, withoutImplied: Set<Package> = []) throws -> ResolutionPlan {
    let origins = origins ?? Dictionary(uniqueKeysWithValues: installed.map { ($0.identity, "https://example.test/") })
    var preview: ResolutionSnapshot.ManifestPreview?
    if let implied {
        preview = { fields in
            fields.merging(["pre-depends": [implied, fields["pre-depends"]].compactMap(\.self).joined(separator: ", ")]) { $1 }
        }
    }
    var snapshot = ResolutionSnapshot(
        packages: available,
        installed: installed,
        architecture: "arm64",
        installableArchitectures: adapting.union(["arm64"]),
        adaptedManifestPreview: preview,
        blockedUpdates: blocked,
        offersAdaptedUpdates: adaptedUpdates,
        origins: origins.compactMapValues(URL.init(string:)),
        autoInstalled: auto
    )
    snapshot.adaptedManifests = Dictionary(uniqueKeysWithValues: withoutImplied.map { ($0, $0.latestMetadata ?? [:]) })
    return try resolveBothWays(
        request: .init(actions: actions, updateAll: update, autoremove: autoremove, allowSystemRemoval: allowSystemRemoval),
        snapshot: snapshot
    )
}

/// Solves `request` as the resolver does with nothing read ahead, and again
/// against a `ResolutionPool` read ahead from the same packages, and
/// records an issue unless the two answer alike: every test that solves
/// through here checks the pool as well. Returns (or throws) the first.
func resolveBothWays(
    request: ResolutionRequest,
    snapshot: ResolutionSnapshot,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> ResolutionPlan {
    let plain = Result { try PackageResolver.resolve(request: request, snapshot: snapshot) }
    let catalogued = snapshot.catalogued(as: UUID(), revision: 1)
    let pooled = Result {
        let pool = try ResolutionPool(snapshot: catalogued)
        #expect(pool.serves(catalogued), sourceLocation: sourceLocation)
        return try PackageResolver.resolve(request: request, snapshot: catalogued, pool: pool)
    }
    switch (plain, pooled) {
    case let (.success(lhs), .success(rhs)):
        #expect(PlanSummary(lhs) == PlanSummary(rhs), "a pool read ahead solved otherwise", sourceLocation: sourceLocation)
    case let (.failure(lhs), .failure(rhs)):
        #expect(FailureSummary(lhs) == FailureSummary(rhs), "a pool read ahead failed otherwise", sourceLocation: sourceLocation)
    default:
        Issue.record("with a pool read ahead: \(pooled), without: \(plain)", sourceLocation: sourceLocation)
    }
    return try plain.get()
}

extension ResolutionSnapshot {
    /// The same snapshot, as if read from the database `identity` at
    /// `revision`: what a pool is kept for.
    func catalogued(
        as identity: UUID,
        revision: Int64,
        packages: [Package]? = nil,
        installed: [Package]? = nil
    ) -> ResolutionSnapshot {
        var copy = ResolutionSnapshot(
            packages: packages ?? self.packages,
            installed: installed ?? self.installed,
            architecture: architecture,
            installableArchitectures: installableArchitectures,
            adaptedManifestPreview: adaptedManifestPreview,
            blockedUpdates: blockedUpdates,
            offersAdaptedUpdates: offersAdaptedUpdates,
            origins: origins,
            autoInstalled: autoInstalled,
            statusDigest: statusDigest,
            catalogueRevision: revision,
            catalogueIdentity: identity
        )
        copy.adaptedManifests = adaptedManifests
        return copy
    }
}

/// Everything a plan says, but its id and its snapshot.
struct PlanSummary: Equatable {
    let install: [Package]
    let remove: [Package]
    let finalPackages: [Package]
    let stages: [InstallerStage]
    let heldBack: [String]
    let diagnostics: [ResolutionFailure.Reason]
    let requiredBy: [String: [String]]
    let autoInstalled: [String]
    let unneeded: [String: [String]]
    let recoveryMode: Bool

    init(_ plan: ResolutionPlan) {
        install = plan.install
        remove = plan.remove
        finalPackages = plan.finalPackages
        stages = plan.stages
        heldBack = plan.heldBack
        diagnostics = plan.diagnostics
        requiredBy = plan.requiredBy
        autoInstalled = plan.autoInstalled
        unneeded = plan.unneeded
        recoveryMode = plan.recoveryMode
    }
}

struct FailureSummary: Equatable {
    let reason: ResolutionFailure.Reason?
    let checks: [ResolutionCheck]
    let other: String?

    init(_ error: any Error) {
        let failure = error as? ResolutionFailure
        reason = failure?.reason
        checks = failure?.checks ?? []
        other = failure == nil ? String(describing: error) : nil
    }
}
