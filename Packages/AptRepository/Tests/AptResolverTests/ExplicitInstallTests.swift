import AptRepository
import AptResolver
import Foundation
import Testing

struct ExplicitInstallTests {
    @Test(arguments: ["4.0.2", "4.0.3", "4.0.5", "4.0.6"], [false, true])
    func exactPackageSurvivesCatalogueChanges(version: String, local: Bool) throws {
        let repository = "https://selected.example.test/"
        let file = URL(fileURLWithPath: "/imports/AirDrop package.deb")
        let requested = Package(identity: "app", payload: [version: [
            "architecture": "arm64", "depends": "library (>= 1)",
            "filename": local ? file.absoluteString : "pool/selected.deb",
            "sha256": "selected-archive",
        ]], repoRef: local ? nil : URL(string: repository))
        let actions = [ResolutionAction.install(requested)]
        let installed = [pkg("app", "4.0.3", installed: true)]

        // Same version from another source, a changed record from the same
        // source, and a newer version must all lose to the explicit request.
        let alternatives = [
            pkg("app", version),
            pkg("app", version, ["sha256": "different-archive"], source: repository),
            pkg("app", "99", source: repository),
        ]
        let first = try solve(alternatives + [pkg("library")], installed: installed, actions: actions, origins: [:])
        #expect(first.install.first { $0.identity == "app" } == requested)
        #expect(first.install.contains(pkg("library")))

        // A refresh changes dependencies and removes the original catalogue
        // entries. Re-solving the retained request must still install its file.
        let refreshed = try solve([pkg("app", "100"), pkg("library", "2")], installed: installed, actions: actions, origins: [:])
        #expect(refreshed.install.first { $0.identity == "app" } == requested)
        #expect(refreshed.install.contains(pkg("library", "2")))
    }

    @Test(arguments: ["missing-library", "library (>= 2)"])
    func unmetDependencyFailsInsteadOfInstallingAnAlternative(dependency: String) {
        let requested = pkg("app", "2", ["depends": dependency], source: "https://selected.example.test/")
        let alternatives = [pkg("app", "2"), pkg("app", "3"), pkg("library")]
        #expect(throws: ResolutionFailure.self) {
            try solve(alternatives, actions: [.install(requested)])
        }
    }

    @Test
    func conflictingExplicitChoicesAreNotChangedToMakeAPlan() {
        let requested = pkg("app", "2", ["depends": "library (>= 2)"])
        let selectedLibrary = pkg("library", "1")
        #expect(throws: ResolutionFailure.self) {
            try solve(
                [pkg("app", "1"), requested, selectedLibrary, pkg("library", "2")],
                actions: [.install(requested), .install(selectedLibrary)]
            )
        }
    }

    @Test
    func recoveryInstallationContainsOnlyTheSelectedPackage() {
        let installed = pkg("resident", installed: true)
        let recovery = pkg("recovery", "2", [
            "depends": "missing",
            "conflicts": installed.identity,
        ])
        let snapshot = ResolutionSnapshot(
            packages: [],
            installed: [installed],
            architecture: "arm64",
            statusDigest: "status"
        )

        let plan = ResolutionPlan.recoveryInstallation(of: recovery, in: snapshot)

        #expect(plan.install == [recovery])
        #expect(plan.remove.isEmpty)
        #expect(plan.stages == [.unpack([recovery.identity]), .configure([recovery.identity])])
        #expect(plan.finalPackages == [installed, recovery])
        #expect(plan.recoveryMode)
    }

    @Test func recoveryRemovalKeepsDependentsAndRemovesOnlyTheBrokenPackage() throws {
        let broken = pkg("broken", "1", ["status": "install reinstreq half-installed"], installed: true)
        let dependent = pkg("dependent", "1", ["depends": "broken"], installed: true)
        let snapshot = ResolutionSnapshot(packages: [], installed: [broken, dependent], architecture: "arm64")
        let plan = try ResolutionPlan.recoveryRemoval(of: "broken", in: snapshot, allowSystemRemoval: false)
        #expect(plan.install.isEmpty)
        #expect(plan.remove == [broken])
        #expect(plan.finalPackages == [dependent])
        #expect(plan.stages == [.remove(["broken"])])
        #expect(plan.recoveryMode)
    }

    @Test(arguments: ["essential", "protected"])
    func recoveryRemovalProtectsSystemPackages(field: String) throws {
        let package = pkg("system", "1", [field: "yes"], installed: true)
        let snapshot = ResolutionSnapshot(packages: [], installed: [package], architecture: "arm64")
        #expect(throws: ResolutionFailure.self) {
            try ResolutionPlan.recoveryRemoval(of: package.identity, in: snapshot, allowSystemRemoval: false)
        }
        let plan = try ResolutionPlan.recoveryRemoval(of: package.identity, in: snapshot, allowSystemRemoval: true)
        #expect(plan.remove == [package])
    }
}
