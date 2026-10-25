import AptRepository
import Foundation
@testable import irisin
import Testing

struct PackageSelectionAdviceTests {
    private static let device = "iphoneos-arm64e"

    private static func package(_ version: String, _ architecture: String, repo: String?) -> Package {
        Package(
            identity: "test.advice",
            payload: [version: ["architecture": architecture, "filename": "pool/\(version).deb"]],
            repoRef: repo.flatMap { URL(string: "https://\($0).test/") }
        )
    }

    private static func advice(selected: Package, offers: [Package]) -> PackageSelectionAdvice {
        PackageSelectionAdvice(selected: selected, offers: offers, device: device)
    }

    @Test
    func aloneInTheRepositoriesThereIsNothingToSay() {
        let selected = Self.package("1.0", Self.device, repo: "a")
        let advice = Self.advice(selected: selected, offers: [selected])
        #expect(advice.newerAlternative(installedVersion: nil) == nil)
    }

    @Test
    func theSameVersionFromAnotherRepositoryIsAChoiceNotNews() {
        let selected = Self.package("1.0", Self.device, repo: "a")
        let other = Self.package("1.0", Self.device, repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, other])
        #expect(advice.newerAlternative(installedVersion: nil) == nil)
    }

    @Test
    func aNewerVersionIsReadFromTheSelectedRepositoryToo() {
        let record = Package(identity: "test.advice", payload: [
            "1.0": ["architecture": Self.device, "filename": "pool/1.0.deb"],
            "1.1": ["architecture": Self.device, "filename": "pool/1.1.deb"],
        ], repoRef: URL(string: "https://a.test/"))
        let selected = Self.package("1.0", Self.device, repo: "a")
        let advice = Self.advice(selected: selected, offers: [record])
        #expect(advice.newerAlternative(installedVersion: "1.0")?.latestVersion == "1.1")
    }

    @Test
    func aDowngradeIsNotToldAboutNewerVersions() {
        let selected = Self.package("1.0", Self.device, repo: "a")
        let newer = Self.package("3.0", Self.device, repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, newer])
        #expect(advice.newerAlternative(installedVersion: "2.0") == nil)
        #expect(advice.newerAlternative(installedVersion: "1.0") == newer)
    }

    @Test
    func whatCannotInstallHereIsNeverRecommended() {
        let selected = Self.package("1.0", Self.device, repo: "a")
        let alien = Self.package("9.0", "iphoneos-arm64", repo: "b")
        let advice = Self.advice(selected: selected, offers: [selected, alien])
        #expect(advice.newerAlternative(installedVersion: nil) == nil)
    }

    @Test
    func atATieTheExactBuildThenTheSelectedRepositoryWins() {
        let selected = Self.package("1.0", Self.device, repo: "b")
        let all = Self.package("2.0", "all", repo: "a")
        let exact = Self.package("2.0", Self.device, repo: "c")
        #expect(Self.advice(selected: selected, offers: [all, exact])
            .newerAlternative(installedVersion: nil) == exact)
        let kept = Package(identity: "test.advice", payload: ["2.0": [
            "architecture": Self.device, "filename": "pool/kept.deb",
        ]], repoRef: selected.repoRef)
        #expect(Self.advice(selected: selected, offers: [exact, kept, Self.package("2.0", Self.device, repo: "a")])
            .newerAlternative(installedVersion: nil) == kept)
    }

    @Test
    func aRecordWithNothingToDownloadIsNeverRecommended() {
        let selected = Self.package("1.0", Self.device, repo: "a")
        let hollow = Package(identity: "test.advice", payload: ["2.0": [
            "architecture": Self.device,
        ]], repoRef: URL(string: "https://b.test/"))
        #expect(Self.advice(selected: selected, offers: [hollow]).newerAlternative(installedVersion: nil) == nil)
    }
}
