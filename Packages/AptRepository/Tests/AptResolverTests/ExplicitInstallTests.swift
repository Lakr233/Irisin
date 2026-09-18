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
}
