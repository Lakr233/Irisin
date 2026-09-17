import AptRepository
@testable import AptResolver
import Foundation
import Testing

struct AutoremoveTests {
    @Test func dependencyIsAutomaticAndRequestIsManual() throws {
        let app = pkg("app", "1", ["depends": "library"])
        #expect(try solve([app, pkg("library")], actions: [.install(app)]).autoInstalled == ["library"])
    }

    /// An update keeps the mark the installed copy has.
    @Test func updateKeepsTheInstalledMark() throws {
        let installed = [pkg("app", installed: true), pkg("library", installed: true)]
        let result = try solve([pkg("app", "2"), pkg("library", "2")], installed: installed, actions: [.install(pkg("app", "2")), .install(pkg("library", "2"))], auto: ["library"])
        #expect(result.autoInstalled == ["library"])
    }

    @Test func removalLeavesOnlyAutomaticDependenciesUnneeded() throws {
        let installed = [
            pkg("app", "1", ["depends": "library, base, pinned, manual"], installed: true),
            pkg("library", installed: true),
            pkg("base", "1", ["essential": "yes"], installed: true),
            pkg("pinned", "1", ["status": "hold ok installed"], installed: true),
            pkg("manual", installed: true),
        ]
        let auto: Set = ["library", "base", "pinned"]
        #expect(try solve([], installed: installed, actions: [], auto: auto).unneeded.isEmpty)
        let result = try solve([], installed: installed, actions: [.remove("app")], auto: auto)
        #expect(result.unneeded == ["library": []])
        #expect(result.remove.map(\.identity) == ["app"])
    }

    @Test func chainGoesOnlyAsAWhole() throws {
        let installed = [
            pkg("app", "1", ["depends": "aa"], installed: true),
            pkg("aa", "1", ["depends": "bb"], installed: true),
            pkg("bb", installed: true),
        ]
        func remove(_ autoremove: Set<String>) throws -> ResolutionPlan {
            try solve([], installed: installed, actions: [.remove("app")], auto: ["aa", "bb"], autoremove: autoremove)
        }
        let plain = try remove([])
        #expect(plain.unneeded == ["aa": [], "bb": ["aa"]])
        #expect(ResolutionPlan.removable(["bb"], unneeded: plain.unneeded).isEmpty)
        #expect(try remove(["bb"]).remove.map(\.identity) == ["app"])
        let both = try remove(["aa", "bb"])
        #expect(Set(both.remove.map(\.identity)) == ["app", "aa", "bb"])
        #expect(both.unneeded == plain.unneeded)
    }

    @Test func everyWitnessStaysNeeded() throws {
        let installed = [
            pkg("app", "1", ["depends": "left | right, virtual"], installed: true),
            pkg("left", installed: true),
            pkg("right", installed: true),
            pkg("provider", "1", ["provides": "virtual"], installed: true),
        ]
        #expect(try solve([], installed: installed, actions: [], auto: ["left", "right", "provider"]).unneeded.isEmpty)
    }

    @Test(arguments: ["recommends", "suggests"])
    func weakDependencyKeepsAPackage(_ field: String) throws {
        let installed = [pkg("app", "1", [field: "library"], installed: true), pkg("library", installed: true)]
        #expect(try solve([], installed: installed, actions: [], auto: ["library"]).unneeded.isEmpty)
    }

    @Test func unreadableWeakDependencyIsIgnored() throws {
        let app = pkg("app", "1", ["recommends": "library (>=)"])
        #expect(try solve([app], actions: [.install(app)]).install.map(\.identity) == ["app"])
    }

    @Test func autoremoveIgnoresPackagesThatAreNeeded() throws {
        let installed = [pkg("app", "1", ["depends": "library"], installed: true), pkg("library", installed: true)]
        let result = try solve([], installed: installed, actions: [], auto: ["library"], autoremove: ["app", "library", "ghost"])
        #expect(result.remove.isEmpty)
    }

    /// An explicit request is never swept by the same plan.
    @Test func requestedPackageIsNotSwept() throws {
        let update = pkg("library", "2")
        let result = try solve([update], installed: [pkg("library", installed: true)], actions: [.install(update)], auto: ["library"], autoremove: ["library"])
        #expect(result.install.map(\.identity) == ["library"])
        #expect(result.unneeded.isEmpty)
    }

    /// A dependency an unneeded package brings in with its update is not
    /// offered on its own; it stays for as long as that package does.
    @Test func newDependencyOfUnneededPackageFollowsIt() throws {
        let result = try solve([pkg("stale", "2", ["depends": "fresh"]), pkg("fresh")], installed: [pkg("stale", installed: true)], actions: [], update: true, auto: ["stale"])
        #expect(result.unneeded == ["stale": []])
        #expect(Set(result.install.map(\.identity)) == ["stale", "fresh"])
        #expect(result.autoInstalled == ["fresh", "stale"])
    }
}
