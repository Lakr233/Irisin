@testable import AptRepository
import Foundation
import Testing

/// Which Packages index a suite is read from, given what its Release offers.
struct PackageIndexUrlTests {
    private let suite = URL(string: "https://example.org/dists/iphoneos-arm64/1800")!

    private func urls(distribution: String?, components: [String] = ["main"], release: [String: String], device: String = "iphoneos-arm64") -> [String] {
        Repository.packageIndexUrls(
            suiteUrl: distribution == nil ? URL(string: "https://example.org")! : suite,
            distribution: distribution,
            components: components,
            release: release,
            device: device
        ).map(\.absoluteString)
    }

    @Test func flatRepositoryHasOneIndex() {
        #expect(urls(distribution: nil, release: [:]) == ["https://example.org/Packages"])
    }

    @Test func deviceArchitectureWhenOfferedOrUnknown() {
        #expect(urls(distribution: "iphoneos-arm64/1800", release: [:])
            == ["https://example.org/dists/iphoneos-arm64/1800/main/binary-iphoneos-arm64/Packages"])
        #expect(urls(distribution: "iphoneos-arm64/1800", release: ["architectures": "iphoneos-arm iphoneos-arm64"])
            == ["https://example.org/dists/iphoneos-arm64/1800/main/binary-iphoneos-arm64/Packages"])
    }

    @Test func procursusLegacyDirectoryForASuiteNamedAfterTheDevice() {
        #expect(urls(distribution: "iphoneos-arm64/1800", release: ["architectures": "iphoneos-arm"])
            == ["https://example.org/dists/iphoneos-arm64/1800/main/binary-iphoneos-arm/Packages"])
    }

    @Test func rootfulSuiteIsNotSubstituted() {
        // a legacy repository for another bootstrap keeps failing at the device's own path
        #expect(urls(distribution: "stable", release: ["architectures": "iphoneos-arm"])
            == ["https://example.org/dists/iphoneos-arm64/1800/main/binary-iphoneos-arm64/Packages"])
    }

    @Test func allAndForeignArchitecturesAreNeverChosen() {
        #expect(urls(distribution: "iphoneos-arm64/1800", release: ["architectures": "all iphoneos-arm64e"])
            == ["https://example.org/dists/iphoneos-arm64/1800/main/binary-iphoneos-arm64/Packages"])
    }

    @Test func oneIndexPerComponent() {
        #expect(urls(distribution: "iphoneos-arm64/1800", components: ["main", "extra"], release: [:]).count == 2)
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
