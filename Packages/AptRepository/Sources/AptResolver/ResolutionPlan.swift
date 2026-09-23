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
    /// Repository entries the plan had to leave out, and why: those of a
    /// package it installs, one those depend on, or, updating everything,
    /// one installed. An unreadable entry nothing here looks at is not listed.
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
    /// A single local package installed with the last-resort policy. The
    /// helper bypasses package relationships and treats maintainer-script
    /// failures as warnings; archive, architecture and filesystem safety
    /// checks still apply.
    public let recoveryMode: Bool

    /// A last-resort plan for one local package. It never chooses another
    /// package, removes anything, or claims that a dependency brought it in.
    public static func recoveryInstallation(
        of package: Package,
        in snapshot: ResolutionSnapshot
    ) -> ResolutionPlan {
        let identity = package.identity
        return ResolutionPlan(
            id: UUID(),
            snapshot: snapshot,
            install: [package],
            remove: [],
            finalPackages: snapshot.installed.filter { $0.identity != identity } + [package],
            stages: [.unpack([identity]), .configure([identity])],
            heldBack: [],
            diagnostics: [],
            requiredBy: [:],
            autoInstalled: [],
            unneeded: [:],
            recoveryMode: true
        )
    }

    /// Removes exactly the selected installed package without solving relationships.
    /// The helper still enforces held/system-package protection and filesystem safety.
    public static func recoveryRemoval(
        of identity: String,
        in snapshot: ResolutionSnapshot,
        allowSystemRemoval: Bool
    ) throws -> ResolutionPlan {
        guard let package = snapshot.installed.first(where: { $0.identity == identity }) else {
            throw ResolutionFailure(.unfinishedInstall(package: identity))
        }
        let fields = package.latestMetadata ?? [:]
        let protected = fields["essential"] == "yes" || fields["protected"] == "yes"
            || ["apt", "dpkg", "essential", "firmware", "bash", "coreutils",
                "base", "base-files", "base-passwd", "libroot", "roothide"].contains(identity)
        guard fields["status"]?.hasPrefix("hold ") != true else {
            throw ResolutionFailure(.onHold(package: identity))
        }
        guard allowSystemRemoval || !protected else {
            throw ResolutionFailure(.requiredBySystem(package: identity))
        }
        return ResolutionPlan(
            id: UUID(), snapshot: snapshot, install: [], remove: [package],
            finalPackages: snapshot.installed.filter { $0.identity != identity },
            stages: [.remove([identity])], heldBack: [], diagnostics: [], requiredBy: [:],
            autoInstalled: [], unneeded: [:], recoveryMode: true
        )
    }

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
