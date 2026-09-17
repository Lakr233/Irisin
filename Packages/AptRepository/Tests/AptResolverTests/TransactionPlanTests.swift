import AptRepository
@testable import AptResolver
import Foundation
import IrisinProtocol
import Testing

struct TransactionPlanTests {
    /// A tweak that depends on a substrate provider unpacked before it once,
    /// because its repository sorted first; the provider's preinst then moved
    /// the files the tweak had just placed. Dependencies unpack first,
    /// through Provides, whichever repository each came from.
    @Test(arguments: [
        ("https://havoc.app/", "https://roothide.github.io/"),
        ("https://roothide.github.io/", "https://havoc.app/"),
    ])
    func dependenciesUnpackBeforeTheirDependants(tweakSource: String, dependencySource: String) throws {
        let tweak = pkg("wiki.qaq.colorfulwallpaperx", "1", ["depends": "mobilesubstrate, preferenceloader"], source: tweakSource)
        let ellekit = pkg("ellekit", "1", ["provides": "mobilesubstrate (= 99)"], source: dependencySource)
        let loader = pkg("preferenceloader", "1", ["depends": "mobilesubstrate"], source: dependencySource)
        let result = try solve([tweak, ellekit, loader], actions: [.install(tweak)])
        #expect(result.stages.prefix(3) == [
            .unpack(["ellekit"]),
            .unpack(["preferenceloader"]),
            .unpack(["wiki.qaq.colorfulwallpaperx"]),
        ])
    }

    /// A provider whose Pre-Depends are not configured yet unpacks in a
    /// later pass, and the tweak that depends on it waits with it.
    @Test func dependantsWaitForADependencyThatWaits() throws {
        let tweak = pkg("tweak", "1", ["depends": "provider"])
        let provider = pkg("provider", "1", ["pre-depends": "base"])
        let result = try solve([tweak, provider, pkg("base")], actions: [.install(tweak)])
        #expect(result.stages.prefix(4) == [
            .unpack(["base"]),
            .configure(["base"]),
            .unpack(["provider"]),
            .unpack(["tweak"]),
        ])
    }

    /// Waiting gives way when it gets nowhere: the old tweak breaks the new
    /// base, so the new tweak replaces it before base can be configured.
    @Test func waitingGivesWayWhenItGetsNowhere() throws {
        let old = pkg("tweak", "1", ["breaks": "base (>= 2)"], installed: true)
        let tweak = pkg("tweak", "2", ["depends": "provider"])
        let provider = pkg("provider", "1", ["pre-depends": "base (>= 2)"])
        let result = try solve([tweak, provider, pkg("base", "2")], installed: [old], actions: [.install(tweak)])
        #expect(result.stages.prefix(4) == [
            .unpack(["base"]),
            .unpack(["tweak"]),
            .configure(["base"]),
            .unpack(["provider"]),
        ])
    }

    /// dpkg removes what a failed removal left half installed; only a
    /// package that needs a reinstall has to be installed again first.
    @Test func unfinishedRemovalIsRepairedByRemovingItAgain() throws {
        let half = pkg("half", "1", ["status": "deinstall ok half-installed"], installed: true)
        #expect(try solve([], installed: [half], actions: [.remove("half")]).stages == [.remove(["half"])])
        let broken = pkg("broken", "1", ["status": "install reinstreq half-installed"], installed: true)
        let failure = #expect(throws: ResolutionFailure.self) {
            try solve([], installed: [broken], actions: [.remove("broken")])
        }
        #expect(failure?.reason == .unfinishedInstall(package: "broken"))
    }

    /// dpkg defers a removal while a package that depends on it is leaving
    /// too, so the dependant's prerm still finds what it depends on.
    @Test func dependantsAreRemovedBeforeTheirDependencies() throws {
        let installed = [
            pkg("zapp", "1", ["depends": "library"], installed: true),
            pkg("library", installed: true),
            pkg("aardvark", "1", ["depends": "zapp"], installed: true),
        ]
        let result = try solve([], installed: installed, actions: [.remove("library")])
        #expect(result.stages == [.remove(["aardvark", "zapp", "library"])])
    }

    /// The helper leaves a package needing reinstallation when a script it
    /// ran to back out failed, and tells the user to install it again. That
    /// install is the repair; every other plan still stops at the package.
    @Test func unfinishedInstallIsRepairedByInstallingItAgain() throws {
        let broken = pkg("broken", "1", ["status": "install reinstreq half-installed"], installed: true)
        let again = pkg("broken", "1")
        let result = try solve([again], installed: [broken], actions: [.install(again)])
        #expect(result.stages == [.unpack(["broken"]), .configure(["broken"])])
        let other = pkg("other")
        do {
            _ = try solve([again, other], installed: [broken], actions: [.install(other)])
            Issue.record("A package half installed must be repaired before anything else is planned")
        } catch let failure as ResolutionFailure {
            #expect(failure.reason == .unfinishedInstall(package: "broken"))
        }
    }
}
