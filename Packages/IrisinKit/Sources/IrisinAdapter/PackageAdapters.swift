import Foundation
import IrisinProtocol

/// The adapters this build ships, and the two questions asked of them: which
/// architectures the catalogue may offer, and what to do with one prepared
/// package. The list is the switch; there is no setting.
public struct PackageAdapters: Sendable {
    public let adapters: [any PackageAdapter]

    public init(adapters: [any PackageAdapter]) {
        self.adapters = adapters
    }

    /// What the app ships. An adapter here is offered to the catalogue
    /// whether or not its conversion is written; one that is not would
    /// throw `AdaptationFailure.unavailable` at staging.
    public static let installed = PackageAdapters(adapters: [RootlessToRoothide()])

    /// The dpkg architectures a package may carry and still install on
    /// `current`: the bootstrap's own, plus every `source` an installed
    /// adapter rewrites into it. `all` is always accepted and not listed.
    public func installable(on current: String) -> Set<String> {
        var accepted: Set<String> = [current]
        for adapter in adapters where adapter.target.rawValue == current {
            accepted.insert(adapter.source.rawValue)
        }
        return accepted
    }

    /// What an adapted package gains in front of its Pre-Depends on
    /// `current`, for the resolver. One adapter per target ships, so the
    /// first answer is the answer.
    public func impliedPreDepends(on current: String) -> String? {
        adapters.first { $0.target.rawValue == current && $0.impliedPreDepends != nil }?.impliedPreDepends
    }

    /// The adapter that takes a package with this control paragraph to
    /// `current`, or nil when the package already fits (`all`, or built for
    /// `current`) or nothing here converts it. Whether the adapter will try
    /// this package is its `canAttemptInstall`, asked by whoever needs it.
    public func adapter(for control: [String: String], on current: String) -> (any PackageAdapter)? {
        // read as a list, the way dpkg and the catalogue read it: a package
        // whose field named two architectures was offered for its adaptable
        // one and would have been installed as built by an adapter that
        // matched the whole field against one name
        let architectures = (control["architecture"] ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
        guard !architectures.contains("all"), !architectures.contains(current) else { return nil }
        return adapters.first { adapter in
            architectures.contains(adapter.source.rawValue) && adapter.target.rawValue == current
        }
    }

    /// Adapt the prepared package under `directory` for `current` if an
    /// adapter applies, returning the rewritten manifest's digest; nil
    /// leaves the tree and its digest as prepared. A package built for
    /// another bootstrap with no adapter is left alone here as well: the
    /// catalogue does not offer it, and a `.deb` the user opened by hand
    /// installs as it always did. One its adapter refuses throws
    /// `AdaptationFailure.incompatible`: the tree it was built as is no
    /// more installable for the refusal.
    public func adapt(preparedPackageAt directory: URL, on current: String) throws -> String? {
        // nothing to consult: the tree stays as prepared, and a control
        // paragraph this parser would reject still reaches the helper, which
        // names its reason in the transcript
        guard !adapters.isEmpty else { return nil }
        let manifest = try PreparedPackage.read(from: directory)
        let control = try DebianControl.parse(manifest.control, preservingLinesFor: ["description"])
        guard let adapter = adapter(for: control, on: current) else { return nil }
        guard adapter.canAttemptInstall(control: control) else {
            throw AdaptationFailure.incompatible(package: control["package"] ?? "")
        }
        return try adapter.adapt(preparedPackageAt: directory)
    }
}
