import AptRepository
@testable import AptResolver
import Foundation
import IrisinProtocol
import Testing

/// A package an adapter rewrites is solved as it will be once rewritten.
struct AdaptedPackageTests {
    private let foreign = ["architecture": "other"]

    @Test func foreignArchitectureIsNotACandidateWithoutAnAdapter() {
        let tweak = pkg("tweak", "1", foreign)
        #expect(throws: (any Error).self) { try solve([tweak], actions: [.install(tweak)]) }
    }

    /// libsolv drops a solvable whose architecture is not the pool's own.
    @Test func adaptedCandidateInstallsExplicitlyAndAsADependency() throws {
        let tweak = pkg("tweak", "1", foreign)
        #expect(try solve([tweak], actions: [.install(tweak)], adapting: ["other"]).install == [tweak])
        let app = pkg("app", "1", ["depends": "tweak"])
        let plan = try solve([app, tweak], actions: [.install(app)], adapting: ["other"])
        #expect(Set(plan.install.map(\.identity)) == ["app", "tweak"])
    }

    /// Written the way roothide's patcher writes it, with no space before the version.
    @Test func previewedPreDependsComesFirstAndOnlyForTheAdapted() throws {
        let tweak = pkg("tweak", "1", foreign.merging(["pre-depends": "library"]) { $1 })
        let native = pkg("native")
        let plan = try solve(
            [tweak, native, pkg("library"), pkg("compat", "1")],
            actions: [.install(tweak), .install(native)],
            adapting: ["other"],
            implied: "compat(>= 0.9)"
        )
        #expect(Set(plan.install.map(\.identity)) == ["tweak", "native", "library", "compat"])
        let order = plan.stages.flatMap { stage -> [String] in
            if case let .unpack(names) = stage {
                return names
            }
            return []
        }
        #expect(try #require(order.firstIndex(of: "compat")) < order.firstIndex(of: "tweak")!)
    }

    /// A theme's file showed it has no code: solved without the compat
    /// layer, which then neither comes in nor is required, while a tweak
    /// adapted beside it still brings it.
    @Test func anAdaptedPackageIsSolvedAsItsFileWasAdapted() throws {
        let theme = pkg("theme", "1", foreign)
        let tweak = pkg("tweak", "1", foreign)
        let compat = pkg("compat", "1")
        let alone = try solve(
            [theme, compat], actions: [.install(theme)],
            adapting: ["other"], implied: "compat(>= 0.9)", withoutImplied: [theme]
        )
        #expect(alone.install == [theme])
        _ = try solve(
            [theme], actions: [.install(theme)],
            adapting: ["other"], implied: "compat(>= 0.9)", withoutImplied: [theme]
        )
        let both = try solve(
            [theme, tweak, compat], actions: [.install(theme), .install(tweak)],
            adapting: ["other"], implied: "compat(>= 0.9)", withoutImplied: [theme]
        )
        #expect(Set(both.install.map(\.identity)) == ["theme", "tweak", "compat"])
    }

    @Test func missingPreviewedPreDependsFailsTheAdaptedPackageAlone() throws {
        let tweak = pkg("tweak", "1", foreign)
        #expect(throws: (any Error).self) {
            try solve([tweak], actions: [.install(tweak)], adapting: ["other"], implied: "compat(>= 0.9)")
        }
        #expect(throws: (any Error).self) {
            try solve([tweak, pkg("compat", "0.8")], actions: [.install(tweak)], adapting: ["other"], implied: "compat(>= 0.9)")
        }
        _ = try solve([pkg("native")], actions: [.install(pkg("native"))], adapting: ["other"], implied: "compat(>= 0.9)")
    }

    /// The preference is a preference, not a filter: what only the adapted
    /// version can satisfy is solved with it, where dropping the candidate
    /// used to answer with a conflict every check of which read matched.
    @Test func anAdaptedVersionIsStillThereForWhatOnlyItSatisfies() throws {
        let native = pkg("tweak", "1", [:], source: "https://native.test/")
        let adapted = pkg("tweak", "2", foreign, source: "https://rootless.test/")
        let app = pkg("app", "1", ["depends": "tweak (>= 2)"])
        let plan = try solve([app, native, adapted], actions: [.install(app)], adapting: ["other"])
        #expect(plan.install.first { $0.identity == "tweak" } == adapted)
    }

    @Test func nativeCandidateBeatsANewerAdaptedOneUnlessNamed() throws {
        let native = pkg("tweak", "1", [:], source: "https://native.test/")
        let adapted = pkg("tweak", "2", foreign, source: "https://rootless.test/")
        let app = pkg("app", "1", ["depends": "tweak"])
        let plan = try solve([app, native, adapted], actions: [.install(app)], adapting: ["other"])
        #expect(plan.install.first { $0.identity == "tweak" } == native)
        #expect(try solve([native, adapted], actions: [.install(adapted)], adapting: ["other"]).install == [adapted])
    }

    /// A converted package stays where it is when everything updates, is
    /// not reported as left behind, and still updates when asked by name.
    @Test func updateOfEverythingLeavesAConvertedPackageUnlessAsked() throws {
        let old = pkg("tweak", "1", installed: true)
        let newer = pkg("tweak", "2", foreign)
        let native = pkg("native", "2")
        let installed = [old, pkg("native", "1", installed: true)]
        let frozen = try solve(
            [newer, native], installed: installed, actions: [], update: true,
            adapting: ["other"], adaptedUpdates: false
        )
        #expect(frozen.install == [native])
        #expect(frozen.heldBack.isEmpty)
        let offered = try solve([newer, native], installed: installed, actions: [], update: true, adapting: ["other"])
        #expect(Set(offered.install) == [newer, native])
        let asked = try solve(
            [newer], installed: installed, actions: [.install(newer)],
            adapting: ["other"], adaptedUpdates: false
        )
        #expect(asked.install == [newer])
    }
}
