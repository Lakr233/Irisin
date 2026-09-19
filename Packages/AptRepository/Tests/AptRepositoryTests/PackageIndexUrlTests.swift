@testable import AptRepository
import Foundation
import Testing

/// Which Packages indexes a suite is probed for, and in what order, given
/// what its Release offers.
struct PackageIndexUrlTests {
    private let suite = URL(string: "https://example.org/dists/stable")!
    private static let rootless = ["iphoneos-arm64", "iphoneos-arm64e", "iphoneos-arm"]
    private static let roothide = ["iphoneos-arm64e", "iphoneos-arm64", "iphoneos-arm"]

    private func candidates(
        distribution: String? = "stable",
        components: [String] = ["main"],
        release: [String: String],
        architectures: [String] = rootless,
        installable: Set<String>? = nil
    ) -> [[String]] {
        Repository.packageIndexUrls(
            suiteUrl: distribution == nil ? URL(string: "https://example.org")! : suite,
            distribution: distribution,
            components: components,
            release: release,
            architectures: architectures,
            // no adapter unless the test names one: the device's own alone
            installable: installable ?? [architectures[0]]
        ).map { $0.map(\.absoluteString) }
    }

    private func index(_ architecture: String, component: String = "main") -> String {
        "https://example.org/dists/stable/\(component)/binary-\(architecture)/Packages"
    }

    @Test func flatRepositoryHasOneIndex() {
        #expect(candidates(distribution: nil, release: [:]) == [["https://example.org/Packages"]])
    }

    @Test func silentReleaseLeavesTheWholeChainInOrder() {
        #expect(candidates(release: [:])
            == [[index("iphoneos-arm64")], [index("iphoneos-arm64e")], [index("iphoneos-arm")]])
        #expect(candidates(release: [:], architectures: Self.roothide)
            == [[index("iphoneos-arm64e")], [index("iphoneos-arm64")], [index("iphoneos-arm")]])
    }

    @Test func releaseDropsWhatItDoesNotOffer() {
        // BigBoss: rootless reads its own index, roothide the rootless one,
        // and neither asks for the rootful one first
        let bigBoss = ["architectures": "iphoneos-arm iphoneos-arm64"]
        #expect(candidates(release: bigBoss) == [[index("iphoneos-arm64")], [index("iphoneos-arm")]])
        #expect(candidates(release: bigBoss, architectures: Self.roothide)
            == [[index("iphoneos-arm64")], [index("iphoneos-arm")]])
    }

    @Test func deviceArchitectureComesFirstWhenOffered() {
        #expect(candidates(release: ["architectures": "iphoneos-arm64 iphoneos-arm64e"], architectures: Self.roothide)
            == [[index("iphoneos-arm64e")], [index("iphoneos-arm64")]])
    }

    @Test func legacyDirectoryIsReachedThroughTheChain() {
        // Procursus keeps a rootless suite in binary-iphoneos-arm, and a
        // rootful repository has nothing else: both are read, not failed
        #expect(candidates(release: ["architectures": "iphoneos-arm"]) == [[index("iphoneos-arm")]])
    }

    @Test func releaseNamingNothingKnownLeavesTheWholeChain() {
        #expect(candidates(release: ["architectures": "all amd64"]).count == 3)
    }

    // MARK: what an adapter installs is read with the device's own

    private static let adapting: Set<String> = ["iphoneos-arm64e", "iphoneos-arm64"]

    @Test func installableArchitecturesAreReadTogetherDeviceFirst() {
        #expect(candidates(release: [:], architectures: Self.roothide, installable: Self.adapting)
            == [[index("iphoneos-arm64e"), index("iphoneos-arm64")], [index("iphoneos-arm")]])
        #expect(candidates(
            release: ["architectures": "iphoneos-arm64 iphoneos-arm64e"],
            architectures: Self.roothide,
            installable: Self.adapting
        ) == [[index("iphoneos-arm64e"), index("iphoneos-arm64")]])
    }

    @Test func aReleaseWithoutTheDeviceLeavesTheAdaptableAlone() {
        let bigBoss = ["architectures": "iphoneos-arm iphoneos-arm64"]
        #expect(candidates(release: bigBoss, architectures: Self.roothide, installable: Self.adapting)
            == [[index("iphoneos-arm64")], [index("iphoneos-arm")]])
    }

    @Test func nothingInstallableOfferedLeavesTheChain() {
        #expect(candidates(release: ["architectures": "iphoneos-arm"], architectures: Self.roothide, installable: Self.adapting)
            == [[index("iphoneos-arm")]])
    }

    @Test func architecturesComeBeforeComponentsInOneEntry() {
        #expect(candidates(
            components: ["main", "extra"],
            release: ["architectures": "iphoneos-arm64 iphoneos-arm64e"],
            architectures: Self.roothide,
            installable: Self.adapting
        ) == [[
            index("iphoneos-arm64e"), index("iphoneos-arm64e", component: "extra"),
            index("iphoneos-arm64"), index("iphoneos-arm64", component: "extra"),
        ]])
    }

    @Test func oneIndexPerComponentInEveryCandidate() {
        #expect(candidates(components: ["main", "extra"], release: ["architectures": "iphoneos-arm64"])
            == [[index("iphoneos-arm64"), index("iphoneos-arm64", component: "extra")]])
    }
}

struct RepositorySourceUrlTests {
    @Test func schemeIsAddedOnce() {
        #expect(RepositorySource.url(from: "apt.example.org/")?.absoluteString == "https://apt.example.org")
        #expect(RepositorySource.url(from: "http://apt.example.org")?.absoluteString == "http://apt.example.org")
    }

    @Test func doubledSchemeCollapsesAndBareSchemeIsRefused() {
        #expect(RepositorySource.url(from: "https://https://apt.example.org")?.absoluteString == "https://apt.example.org")
        #expect(RepositorySource.url(from: "https://http://apt.example.org")?.absoluteString == "http://apt.example.org")
        #expect(RepositorySource.url(from: "https://") == nil)
    }
}
