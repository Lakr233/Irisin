import AptRepository
import AptResolver
import Foundation

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
    return try PackageResolver.resolve(
        request: .init(actions: actions, updateAll: update, autoremove: autoremove, allowSystemRemoval: allowSystemRemoval),
        snapshot: snapshot
    )
}
