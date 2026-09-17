import AptRepository
import Foundation
import IrisinProtocol

public struct ResolutionPlan: Sendable {
    public let id: UUID
    public let snapshot: ResolutionSnapshot
    public let install: [Package]
    public let remove: [Package]
    public let finalPackages: [Package]
    public let stages: [InstallerStage]
    public let heldBack: [String]
    /// Repository entries the plan had to leave out, and why.
    public let diagnostics: [ResolutionFailure.Reason]
    /// Why a package is in the plan: for each identity the plan installs,
    /// the names of the packages in the final set whose Depends or
    /// Pre-Depends it satisfies, sorted. Absent for a package nothing
    /// selected depends on, which is the one the user asked for.
    public let requiredBy: [String: [String]]
    /// The identities in `install` that came in as a dependency, sorted:
    /// the helper marks them `Auto-Installed` in APT's `extended_states`.
    public let autoInstalled: [String]
    /// Installed packages that came in as a dependency and that nothing
    /// installed by hand still needs through Depends, Pre-Depends or
    /// Recommends, the set `apt autoremove` would take. Computed before the
    /// request's `autoremove` is applied, so it does not change as that
    /// set does. Each value names the other unneeded packages that depend
    /// on the key, sorted: the key can only go with them.
    public let unneeded: [String: [String]]

    /// The part of `chosen` that can go: a name is dropped while an
    /// unneeded package that depends on it is not chosen as well.
    public static func removable(_ chosen: Set<String>, unneeded: [String: [String]]) -> Set<String> {
        var selected = chosen.intersection(unneeded.keys)
        while case let blocked = selected.filter({ unneeded[$0]!.contains { !selected.contains($0) } }),
              !blocked.isEmpty
        {
            selected.subtract(blocked)
        }
        return selected
    }
}
