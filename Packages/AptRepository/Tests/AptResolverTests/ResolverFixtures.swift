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
/// into the fixtures' `arm64`, and `implied` the Pre-Depends it adds.
func solve(_ available: [Package], installed: [Package] = [], actions: [ResolutionAction], update: Bool = false, blocked: Set<String> = [], origins: [String: String]? = nil, auto: Set<String> = [], autoremove: Set<String> = [], allowSystemRemoval: Bool = false, adapting: Set<String> = [], implied: String? = nil) throws -> ResolutionPlan {
    let origins = origins ?? Dictionary(uniqueKeysWithValues: installed.map { ($0.identity, "https://example.test/") })
    return try PackageResolver.resolve(
        request: .init(actions: actions, updateAll: update, autoremove: autoremove, allowSystemRemoval: allowSystemRemoval),
        snapshot: .init(
            packages: available,
            installed: installed,
            architecture: "arm64",
            installableArchitectures: adapting.union(["arm64"]),
            adaptedPreDepends: implied,
            blockedUpdates: blocked,
            origins: origins.compactMapValues(URL.init(string:)),
            autoInstalled: auto
        )
    )
}
