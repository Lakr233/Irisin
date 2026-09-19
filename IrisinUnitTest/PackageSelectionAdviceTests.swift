import AptRepository
import Foundation
@testable import irisin
import Testing

struct PackageSelectionAdviceTests {
    private static let device = "iphoneos-arm64e"
    private static let foreign = "iphoneos-arm64"

    private static func package(_ version: String, _ architecture: String, repo: String?) -> Package {
        Package(
            identity: "test.advice",
            payload: [version: ["architecture": architecture, "filename": "pool/\(version).deb"]],
            repoRef: repo.flatMap { URL(string: "https://\($0).test/") }
        )
    }

    private static func advice(selected: Package, offers: [Package]) -> PackageSelectionAdvice {
        PackageSelectionAdvice(
            selected: selected,
            offers: offers,
            device: device,
            installable: [device, foreign]
        )
    }

    @Test
    func aloneInTheRepositoriesThereIsNothingToSay() {
        let selected = Self.package("1.0", Self.foreign, repo: "a")
        let advice = Self.advice(selected: selected, offers: [selected])
        #expect(advice.nativeAlternative(installedVersion: nil) == nil)
        #expect(advice.newerAlternative(installedVersion: nil, adaptedUpdates: true) == nil)
    }

    @Test
    func aBuildForThisSystemBeatsOneAnAdapterRewrites() {
        let selected = Self.package("2.0", Self.foreign, repo: "a")
        let native = Self.package("1.5", Self.device, repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, native])
        #expect(advice.nativeAlternative(installedVersion: nil) == native)
        // going on anyway compares adapted builds alone: no second alert
        // for the record just declined
        #expect(advice.newerAlternative(installedVersion: nil, adaptedUpdates: true) == nil)
    }

    /// One repository listing the package for both systems: the record holds
    /// the native version under the newer one an adapter rewrites.
    @Test
    func aNativeVersionUnderTheSelectedOneInTheSameRecordIsRecommended() {
        let selected = Self.package("2.0", Self.foreign, repo: "a")
        let native = Self.package("1.5", Self.device, repo: "a")
        let record = Package(
            identity: selected.identity,
            payload: selected.payload.merging(native.payload) { $1 },
            repoRef: selected.repoRef
        )
        let advice = Self.advice(selected: selected, offers: [record])
        #expect(advice.nativeAlternative(installedVersion: nil) == native)
        #expect(advice.nativeAlternative(installedVersion: "1.5") == native)
        // not one that would take the installed package down
        #expect(advice.nativeAlternative(installedVersion: "1.8") == nil)
        #expect(advice.newerAlternative(installedVersion: nil, adaptedUpdates: true) == nil)
    }

    @Test
    func theNewestNativeBuildIsTheOneRecommended() {
        let selected = Self.package("1.0", Self.foreign, repo: "a")
        let old = Self.package("1.0", Self.device, repo: "b")
        let new = Self.package("1.2", "all", repo: "c")
        let advice = Self.advice(selected: selected, offers: [old, new, selected])
        #expect(advice.nativeAlternative(installedVersion: nil) == new)
    }

    @Test
    func aNativeSelectionHearsNothingAboutArchitecture() {
        let selected = Self.package("1.0", Self.device, repo: "a")
        let other = Self.package("1.0", Self.device, repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, other])
        #expect(advice.nativeAlternative(installedVersion: nil) == nil)
        // the same version from another repository is a choice, not news
        #expect(advice.newerAlternative(installedVersion: nil, adaptedUpdates: true) == nil)
    }

    @Test
    func aNewerVersionIsReadFromTheSelectedRepositoryToo() {
        let record = Package(identity: "test.advice", payload: [
            "1.0": ["architecture": Self.device, "filename": "pool/1.0.deb"],
            "1.1": ["architecture": Self.device, "filename": "pool/1.1.deb"],
        ], repoRef: URL(string: "https://a.test/"))
        let selected = Self.package("1.0", Self.device, repo: "a")
        let advice = Self.advice(selected: selected, offers: [record])
        #expect(advice.newerAlternative(installedVersion: "1.0", adaptedUpdates: true)?.latestVersion == "1.1")
    }

    @Test
    func aDowngradeIsNotToldAboutNewerVersions() {
        let selected = Self.package("1.0", Self.device, repo: "a")
        let newer = Self.package("3.0", Self.device, repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, newer])
        #expect(advice.newerAlternative(installedVersion: "2.0", adaptedUpdates: true) == nil)
        #expect(advice.newerAlternative(installedVersion: "1.0", adaptedUpdates: true) == newer)
    }

    @Test
    func whatCannotInstallHereIsNeverRecommended() {
        let selected = Self.package("1.0", Self.device, repo: "a")
        let alien = Self.package("9.0", "iphoneos-arm", repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, alien])
        #expect(advice.newerAlternative(installedVersion: nil, adaptedUpdates: true) == nil)
    }

    @Test
    func anUpdateIsNeverAnsweredWithADowngrade() {
        let selected = Self.package("2.1", Self.foreign, repo: "a")
        let native = Self.package("1.5", Self.device, repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, native])
        #expect(advice.nativeAlternative(installedVersion: "2.0") == nil)
        #expect(advice.nativeAlternative(installedVersion: "1.5") == native)
        // a request that already goes down may land on the native record
        let down = Self.advice(selected: Self.package("1.8", Self.foreign, repo: "a"), offers: [native])
        #expect(down.nativeAlternative(installedVersion: "2.0") == native)
    }

    @Test
    func anAdaptedUpdateWaitsForCompatibilityUpdates() {
        let selected = Self.package("1.0", Self.foreign, repo: "a")
        let newer = Self.package("2.0", Self.foreign, repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, newer])
        #expect(advice.newerAlternative(installedVersion: "1.0", adaptedUpdates: false) == nil)
        #expect(advice.newerAlternative(installedVersion: "1.0", adaptedUpdates: true) == newer)
        // nothing installed: a first install, not an update
        #expect(advice.newerAlternative(installedVersion: nil, adaptedUpdates: false) == newer)
    }

    @Test
    func anOpenedFileIsHeldAgainstEveryRepository() {
        let file = Package(identity: "test.advice", payload: ["1.0": [
            "architecture": Self.foreign, "filename": "file:///tmp/package.deb",
        ]])
        let native = Self.package("1.0", Self.device, repo: "a")
        let advice = Self.advice(selected: file, offers: [native])
        #expect(advice.nativeAlternative(installedVersion: nil) == native)
    }

    @Test
    func atATieTheExactBuildThenTheSelectedRepositoryWins() {
        let selected = Self.package("1.0", Self.foreign, repo: "b")
        let all = Self.package("1.0", "all", repo: "a")
        let exact = Self.package("1.0", Self.device, repo: "c")
        #expect(Self.advice(selected: selected, offers: [all, exact])
            .nativeAlternative(installedVersion: nil) == exact)
        let kept = Package(identity: "test.advice", payload: ["1.0": [
            "architecture": Self.device, "filename": "pool/native.deb",
        ]], repoRef: selected.repoRef)
        #expect(Self.advice(selected: selected, offers: [exact, kept, Self.package("1.0", Self.device, repo: "a")])
            .nativeAlternative(installedVersion: nil) == kept)
    }

    @Test
    func aRecordWithNothingToDownloadIsNeverRecommended() {
        let selected = Self.package("1.0", Self.foreign, repo: "a")
        let hollow = Package(identity: "test.advice", payload: ["1.0": [
            "architecture": Self.device,
        ]], repoRef: URL(string: "https://b.test/"))
        #expect(Self.advice(selected: selected, offers: [hollow]).nativeAlternative(installedVersion: nil) == nil)
    }
}
