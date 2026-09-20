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

    @Test func graphTraversalHandlesLongChainsWithoutRecursion() {
        let graph = Dictionary(uniqueKeysWithValues: (0 ..< 20000).map { ($0, $0 == 19999 ? [] : [$0 + 1]) })
        let groups = StronglyConnectedComponents.components(graph)
        #expect(groups.count == 20000)
        #expect(groups.first == [19999])
    }
}
