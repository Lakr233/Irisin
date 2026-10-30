import AptRepository
@testable import AptResolver
import Foundation
import IrisinProtocol
import Testing

struct ResolutionTests {
    @Test func explicitDownloadLocationSurvivesVersionSelection() throws {
        let catalogue = pkg("paid.package", "2")
        var metadata = try #require(catalogue.payload["2"])
        metadata["filename"] = "https://downloads.example.test/authorized.deb"
        let requested = try Package(identity: catalogue.identity, payload: ["1": #require(pkg("paid.package").payload["1"]), "2": metadata], repoRef: catalogue.repoRef)
        let result = try solve([catalogue], actions: [.install(requested)])
        #expect(result.install.first?.payload["2"]?["filename"] == metadata["filename"])
    }

    @Test func prerequisitesBeforeUnpack() throws {
        let app = pkg("app", "1", ["pre-depends": "library (>= 2)"])
        let result = try solve([app, pkg("library", "1"), pkg("library", "2")], actions: [.install(app)])
        #expect(result.stages == [.unpack(["library"]), .configure(["library"]), .unpack(["app"]), .configure(["app"])])
    }

    @Test func ordinaryDependencyCycle() throws {
        let aa = pkg("aa", "1", ["depends": "bb"])
        let bb = pkg("bb", "1", ["depends": "aa"])
        let result = try solve([aa, bb], actions: [.install(aa)])
        #expect(result.stages.last == .configure(["aa", "bb"]))
    }

    @Test func prerequisiteCycleFailsBeforeExecution() {
        let aa = pkg("aa", "1", ["pre-depends": "bb"])
        let bb = pkg("bb", "1", ["pre-depends": "aa"])
        #expect(throws: (any Error).self) { try solve([aa, bb], actions: [.install(aa)]) }
    }

    @Test func alternativesBacktrackAroundConflict() throws {
        let app = pkg("app", "1", ["depends": "bad | good, required"])
        let bad = pkg("bad", "1", ["conflicts": "required"])
        let result = try solve([app, bad, pkg("good"), pkg("required")], actions: [.install(app)])
        #expect(Set(result.install.map(\.identity)) == ["app", "good", "required"])
        #expect(result.requiredBy == ["good": ["app"], "required": ["app"]])
    }

    @Test(arguments: ["1", "1-0", "0:1", "1-00"])
    func debianEquivalentVersions(_ version: String) throws {
        let app = pkg("app", "1", ["depends": "library (= 1-0)"])
        let result = try solve([app, pkg("library", version)], actions: [.install(app)])
        #expect(result.install.count == 2)
    }

    @Test func versionedProvides() throws {
        let app = pkg("app", "1", ["depends": "virtual (>= 2)"])
        let wrong = pkg("wrong", "99", ["provides": "virtual"])
        let right = pkg("right", "1", ["provides": "virtual (= 2)"])
        let result = try solve([app, wrong, right], actions: [.install(app)])
        #expect(Set(result.install.map(\.identity)) == ["app", "right"])
        #expect(throws: (any Error).self) { try solve([app, wrong], actions: [.install(app)]) }
    }

    @Test func removalIncludesReverseDependencies() throws {
        let result = try solve([], installed: [pkg("app", "1", ["depends": "library"], installed: true), pkg("library", installed: true)], actions: [.remove("library")])
        #expect(Set(result.remove.map(\.identity)) == ["app", "library"])
        #expect(result.stages == [.remove(["app", "library"])])
    }

    @Test func combinedRemovalAndReplacement() throws {
        let new = pkg("new", "1", ["provides": "virtual"])
        let result = try solve([new], installed: [pkg("app", "1", ["depends": "virtual"], installed: true), pkg("old", "1", ["provides": "virtual"], installed: true)], actions: [.remove("old"), .install(new)])
        #expect(result.remove.map(\.identity) == ["old"])
        #expect(result.stages.first == .unpack(["new"]))
    }

    @Test func reverseConflictAndProtection() throws {
        let app = pkg("app")
        let existing = pkg("existing", "1", ["conflicts": "app"], installed: true)
        let result = try solve([app], installed: [existing], actions: [.install(app)])
        #expect(result.remove.map(\.identity) == ["existing"])
        #expect(throws: (any Error).self) {
            try solve([app], installed: [pkg("existing", "1", ["conflicts": "app", "essential": "yes"], installed: true)], actions: [.install(app)])
        }
    }

    @Test func holdPreventsExplicitUpgrade() {
        let update = pkg("library", "2")
        #expect(throws: (any Error).self) {
            try solve([update], installed: [pkg("library", "1", ["status": "hold ok installed"], installed: true)], actions: [.install(update)])
        }
    }

    @Test func conservativeUpdateAndHeldBack() throws {
        let result = try solve([pkg("aa", "2", ["depends": "new"]), pkg("new"), pkg("bb", "2", ["conflicts": "keep"])], installed: [pkg("aa", installed: true), pkg("bb", installed: true), pkg("keep", installed: true)], actions: [], update: true)
        #expect(Set(result.install.map(\.identity)) == ["aa", "new"])
        #expect(result.remove.isEmpty)
        #expect(result.heldBack == ["bb"])
    }

    /// An installed package follows the repository it came from: another
    /// repository's newer copy is not its update. A package with no origin
    /// has no repository to keep to and takes the newest from any.
    @Test func updateKeepsToTheOriginRepository() throws {
        let a = "https://a.test/", b = "https://b.test/"
        let available = [
            pkg("followed", "2", source: a), pkg("followed", "3", source: b),
            pkg("unknown", "2", source: a), pkg("unknown", "3", source: b),
        ]
        let installed = [pkg("followed", installed: true), pkg("unknown", installed: true)]
        let result = try solve(available, installed: installed, actions: [], update: true, origins: ["followed": a])
        #expect(result.install.map { ($0.identity, $0.latestVersion, $0.repoRef?.absoluteString) }.map { "\($0.0) \($0.1 ?? "") \($0.2 ?? "")" }.sorted() == ["followed 2 https://a.test/", "unknown 3 https://b.test/"])
        #expect(result.heldBack.isEmpty)
    }

    /// An origin whose repository was removed, or no longer lists the
    /// package, has nothing to keep to: the package takes the newest from
    /// any repository, and the updates that need it are no longer held
    /// back. Issue 144: roothide installed from roothide's Procursus, that
    /// repository removed for OwnGoal Stripe, and Update All held back
    /// every Stripe update that needs Stripe's roothide.
    @Test func updateLeavesAnOriginThatNoLongerListsThePackage() throws {
        let gone = "https://gone.test/", stripe = "https://stripe.test/"
        let available = [
            pkg("other", "1", source: gone),
            pkg("roothide", "0.1.0-5", source: stripe),
            pkg("apt", "2.9.4-3", ["depends": "roothide (>= 0.1.0-5)"], source: stripe),
        ]
        let installed = [pkg("roothide", "0.1.0", installed: true), pkg("apt", "2.6.0-2", installed: true)]
        let result = try solve(available, installed: installed, actions: [], update: true, origins: ["roothide": gone])
        #expect(result.install.map { "\($0.identity) \($0.latestVersion ?? "")" }.sorted() == ["apt 2.9.4-3", "roothide 0.1.0-5"])
        #expect(result.heldBack.isEmpty)
    }

    /// An update that needs a newer version of a package than the
    /// repository it follows offers, when another repository has one, is
    /// held back with a migration: that package moves, and the update goes
    /// through. Nothing else moves with it, however new its copy elsewhere.
    @Test func heldBackUpdateOffersAMigration() throws {
        let classic = "https://classic.test/", new = "https://new.test/"
        let available = [
            pkg("core", "1.0", source: classic), pkg("tweak", "1", source: classic),
            pkg("core", "1.0-5", source: new), pkg("tweak", "9", source: new),
            pkg("utils", "2.0", ["depends": "core (>= 1.0-5)"], source: new),
        ]
        let installed = [
            pkg("core", "1.0", installed: true), pkg("tweak", "1", installed: true),
            pkg("utils", "1.0", ["depends": "core"], installed: true),
        ]
        let origins = ["core": classic, "tweak": classic, "utils": new]
        let result = try solve(available, installed: installed, actions: [], update: true, origins: origins)
        #expect(result.install.isEmpty)
        #expect(result.heldBack == ["utils"])
        let migration = try #require(result.migration)
        #expect(migration.moves.map { "\($0.identity) \($0.latestVersion ?? "") \($0.repoRef?.absoluteString ?? "")" } == ["core 1.0-5 https://new.test/"])
        #expect(migration.install.map { "\($0.identity) \($0.latestVersion ?? "")" }.sorted() == ["core 1.0-5", "utils 2.0"])
        #expect(migration.released == ["utils"])
        #expect(migration.requiredBy == ["core": ["utils"]])
    }

    /// A package the held-back update would bring in may be the one that
    /// needs the move.
    @Test func migrationFollowsWhatTheUpdateBringsIn() throws {
        let classic = "https://classic.test/", new = "https://new.test/"
        let available = [
            pkg("core", "1.0-5", source: new),
            pkg("library", "1", ["depends": "core (>= 1.0-5)"], source: new),
            pkg("utils", "2.0", ["depends": "library"], source: new),
        ]
        let installed = [pkg("core", "1.0", installed: true), pkg("utils", "1.0", installed: true)]
        let result = try solve(available + [pkg("core", "1.0", source: classic)], installed: installed, actions: [], update: true, origins: ["core": classic, "utils": new])
        #expect(result.heldBack == ["utils"])
        #expect(result.migration?.moves.map(\.identity) == ["core"])
        #expect(result.migration?.install.map(\.identity).sorted() == ["core", "library", "utils"])
    }

    /// An update held back for another reason offers no migration.
    @Test func conflictOffersNoMigration() throws {
        let classic = "https://classic.test/", new = "https://new.test/"
        let available = [
            pkg("core", "1.0", source: classic), pkg("core", "1.0-5", source: new),
            pkg("utils", "2.0", ["conflicts": "keep"], source: new),
        ]
        let installed = [pkg("core", "1.0", installed: true), pkg("utils", "1.0", installed: true), pkg("keep", installed: true)]
        let result = try solve(available, installed: installed, actions: [], update: true, origins: ["core": classic, "utils": new])
        #expect(result.heldBack == ["utils"])
        #expect(result.migration == nil)
    }

    /// Asking for another repository's copy by name is how a package moves
    /// there; nothing else moves with it.
    @Test func explicitInstallMayLeaveTheOriginRepository() throws {
        let a = "https://a.test/", b = "https://b.test/"
        let wanted = pkg("followed", "3", source: b)
        let result = try solve([pkg("followed", "2", source: a), wanted], installed: [pkg("followed", installed: true)], actions: [.install(wanted)], origins: ["followed": a])
        #expect(result.install == [wanted])
    }

    @Test func explicitDowngradeDoesNotDowngradeDependencies() throws {
        let old = pkg("app", "1", ["depends": "library"])
        let result = try solve([old, pkg("library", "1")], installed: [pkg("app", "2", installed: true), pkg("library", "2", installed: true)], actions: [.install(old)])
        #expect(result.install.map(\.identity) == ["app"])
    }

    @Test func latestIntentWins() throws {
        let app = pkg("app", "2")
        let result = try solve([app], installed: [pkg("app", installed: true)], actions: [.remove("app"), .install(app)])
        #expect(result.install.map(\.latestVersion) == ["2"])
        #expect(result.remove.isEmpty)
    }

    @Test func replacesIsNotObsoletes() throws {
        let app = pkg("app", "1", ["replaces": "other"])
        let result = try solve([app], installed: [pkg("other", installed: true)], actions: [.install(app)])
        #expect(result.remove.isEmpty)
    }

    @Test func malformedRelationshipIsNotNoDependencies() {
        let app = pkg("app", "1", ["depends": "library (>=)"])
        #expect(throws: (any Error).self) { try solve([app], actions: [.install(app)]) }
    }

    @Test func dependencyFreePackageAndArchitectureAll() throws {
        let app = pkg("app", "1", ["architecture": "all"])
        #expect(try solve([app], actions: [.install(app)]).install.count == 1)
    }

    @Test func oldConfiguredVersionCanSatisfyPreDependency() throws {
        let aa = pkg("aa", "2", ["pre-depends": "bb (>= 1)"])
        let bb = pkg("bb", "2", ["pre-depends": "aa (>= 1)"])
        let result = try solve([aa, bb], installed: [pkg("aa", installed: true), pkg("bb", installed: true)], actions: [.install(aa), .install(bb)])
        #expect(result.install.count == 2)
        #expect(result.stages.count == 4)
    }

    @Test func breakUpgradeDeconfiguresThenReconfigures() throws {
        let aa = pkg("aa", "2", ["breaks": "bb (<< 2)"])
        let bb = pkg("bb", "2", ["breaks": "aa (<< 2)"])
        let result = try solve([aa, bb], installed: [pkg("aa", installed: true), pkg("bb", installed: true)], actions: [.install(aa), .install(bb)])
        #expect(result.install.count == 2)
        #expect(result.stages.filter {
            if case .configure = $0 {
                true
            } else {
                false
            }
        }.count == 2)
    }

    @Test func unpackedInstalledPackageIsConfigured() throws {
        let result = try solve([], installed: [pkg("aa", "1", ["status": "install ok unpacked"], installed: true)], actions: [])
        #expect(result.stages == [.configure(["aa"])])
    }

    /// What a run left that stopped at build-essential (issue 146): the new
    /// libapt-pkg6.0 unpacked, apt still the version that needs the old
    /// one, a trigger pending.
    private func interruptedRun(tool: String = "apt", toolUpdate: Bool = true) -> (available: [Package], installed: [Package]) {
        let installed = [
            pkg("libapt-pkg6.0", "2.9", ["status": "install ok unpacked"], installed: true),
            pkg(tool, "2.6", ["depends": "libapt-pkg6.0 (= 2.6)"], installed: true),
            pkg("build-essential", "16.1", installed: true),
            pkg("trigger", "1", ["status": "install ok triggers-pending"], installed: true),
        ]
        var available = [
            pkg("libapt-pkg6.0", "2.9"),
            pkg("build-essential", "16.4"),
            pkg("trigger", "1"),
            pkg("irisin", "5.1.3"),
        ]
        if toolUpdate {
            available.append(pkg(tool, "2.9", ["depends": "libapt-pkg6.0 (= 2.9)"]))
        }
        return (available, installed)
    }

    /// Every request but Update All failed there, Irisin's own update
    /// among them: libsolv keeps an installed package that was broken
    /// before. Any request now updates it, as `apt --fix-broken` would,
    /// and configures what the run left.
    @Test func anyRequestMendsWhatAnInterruptedRunLeftBroken() throws {
        for tool in ["apt", "tool"] {
            let (available, installed) = interruptedRun(tool: tool)
            for name in ["build-essential", "irisin"] {
                let wanted = try #require(available.first { $0.identity == name })
                let plan = try solve(available, installed: installed, actions: [.install(wanted)])
                #expect(Set(plan.install.map { "\($0.identity) \($0.latestVersion ?? "")" }) == ["\(tool) 2.9", "\(name) \(wanted.latestVersion!)"])
                #expect(plan.remove.isEmpty)
                let configured = plan.stages.flatMap { stage -> [String] in
                    if case let .configure(names) = stage { names } else { [] }
                }
                #expect(Set(configured) == ["libapt-pkg6.0", "trigger", tool, name])
            }
            // removing an unrelated package mends it too
            let removal = try solve(available, installed: installed, actions: [.remove("build-essential")])
            #expect(removal.install.map(\.identity) == [tool])
            #expect(removal.remove.map(\.identity) == ["build-essential"])
        }
    }

    /// Whatever the run left, the solver finds the mend: a dependency the
    /// new version brought that was never installed, or a Breaks the
    /// package it names has not caught up with. Update All mends it too.
    @Test func aPlanMendsWhateverShapeTheBreakageHas() throws {
        let unrelated = pkg("irisin", "5.1.3")
        let missing = (
            available: [pkg("tweak", "2", ["depends": "newlib (>= 1)"]), pkg("newlib", "1"), unrelated],
            installed: [pkg("tweak", "2", ["depends": "newlib (>= 1)"], installed: true)]
        )
        let breaks = (
            available: [pkg("libfoo", "2", ["breaks": "bar (<< 2)"]), pkg("bar", "1"), pkg("bar", "2"), unrelated],
            installed: [
                pkg("libfoo", "2", ["breaks": "bar (<< 2)"], installed: true),
                pkg("bar", "1", installed: true),
            ]
        )
        for (fixture, mend) in [(missing, "newlib 1"), (breaks, "bar 2")] {
            for update in [false, true] {
                let plan = try solve(
                    fixture.available,
                    installed: fixture.installed,
                    actions: update ? [] : [.install(unrelated)],
                    update: update
                )
                let installs = Set(plan.install.map { "\($0.identity) \($0.latestVersion ?? "")" })
                #expect(installs == (update ? [mend] : [mend, "irisin 5.1.3"]))
                #expect(plan.remove.isEmpty)
            }
        }
    }

    /// With no version that mends it, the request still fails and names
    /// the requirement, as it did: the mend never removes the broken
    /// package, protected or not, and a held package is not updated for it.
    @Test func aBrokenPackageNothingMendsStillFails() throws {
        for tool in ["apt", "tool"] {
            let (available, installed) = interruptedRun(tool: tool, toolUpdate: false)
            let wanted = try #require(available.first { $0.identity == "irisin" })
            do {
                _ = try solve(available, installed: installed, actions: [.install(wanted)])
                Issue.record("a broken package nothing mends must fail the request")
            } catch let failure as ResolutionFailure {
                #expect(failure.reason == .missingRequirement(package: tool, requirement: "libapt-pkg6.0 (= 2.6)"))
            }
        }
        let wanted = pkg("irisin", "5.1.3")
        do {
            _ = try solve(
                [pkg("libfoo", "2", ["breaks": "bar (<< 2)"]), pkg("bar", "1"), wanted],
                installed: [pkg("libfoo", "2", ["breaks": "bar (<< 2)"], installed: true), pkg("bar", "1", installed: true)],
                actions: [.install(wanted)]
            )
            Issue.record("a Breaks nothing mends must fail the request")
        } catch let failure as ResolutionFailure {
            #expect(failure.reason == .conflict(package: "libfoo", requirement: "bar (<< 2)"))
        }
        var (offered, held) = interruptedRun(tool: "tool")
        held[1] = pkg("tool", "2.6", ["depends": "libapt-pkg6.0 (= 2.6)", "status": "hold ok installed"], installed: true)
        offered.removeAll { $0.identity == "build-essential" }
        #expect(throws: (any Error).self) {
            try solve(offered, installed: held, actions: [.install(wanted)])
        }
    }

    /// The user may still remove the broken package, and that alone.
    @Test func theBrokenPackageGoesWhenTheRequestRemovesIt() throws {
        let (available, installed) = interruptedRun(tool: "tool", toolUpdate: false)
        let plan = try solve(available, installed: installed, actions: [.remove("tool")])
        #expect(plan.install.isEmpty)
        #expect(plan.remove.map(\.identity) == ["tool"])
    }

    @Test func graphTraversalHandlesLongChainsWithoutRecursion() {
        let graph = Dictionary(uniqueKeysWithValues: (0 ..< 20000).map { ($0, $0 == 19999 ? [] : [$0 + 1]) })
        let groups = StronglyConnectedComponents.components(graph)
        #expect(groups.count == 20000)
        #expect(groups.first == [19999])
    }
}
