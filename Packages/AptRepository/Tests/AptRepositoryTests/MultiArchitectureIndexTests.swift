@testable import AptRepository
import Foundation
import Testing

/// One repository listing the same package for several architectures: each
/// version keeps the build that fits the bootstrap best.
struct MultiArchitectureIndexTests {
    private static let roothide = "iphoneos-arm64e"
    private static let rootless = "iphoneos-arm64"
    private static let rootful = "iphoneos-arm"

    private func stanza(_ identity: String, _ version: String, _ architecture: String?, mark: String = "") -> String {
        var lines = ["Package: \(identity)", "Version: \(version)"]
        if let architecture {
            lines.append("Architecture: \(architecture)")
        }
        lines.append("Filename: debs/\(identity)_\(version)_\(architecture ?? "none")\(mark).deb")
        return lines.joined(separator: "\n")
    }

    /// Read on roothide with the rootless adapter, unless said otherwise.
    private func read(
        _ stanzas: [String],
        device: String = roothide,
        installable: Set<String> = [roothide, rootless]
    ) -> [String: Package] {
        _ = TestEnvironment.root
        return invokePackages(
            withContext: stanzas.joined(separator: "\n\n"),
            fromRepo: URL(string: "https://example.org"),
            device: device,
            installable: installable
        )
    }

    private func architecture(of package: Package?, _ version: String) -> String? {
        package?.payload[version]?["architecture"]
    }

    @Test func theDeviceBuildOfAVersionWinsWhateverTheOrder() {
        let builds = [stanza("foo", "1.0", Self.rootless), stanza("foo", "1.0", Self.roothide), stanza("foo", "1.0", Self.rootful)]
        for order in [builds, builds.reversed()] {
            let foo = read(Array(order))["foo"]
            #expect(foo?.payload.count == 1)
            #expect(architecture(of: foo, "1.0") == Self.roothide)
        }
    }

    @Test func aNewerVersionOnlyAnAdapterInstallsStaysBesideAnOlderNativeOne() {
        let builds = [stanza("foo", "1.0", Self.roothide), stanza("foo", "2.0", Self.rootless)]
        for order in [builds, builds.reversed()] {
            let foo = read(Array(order))["foo"]
            #expect(foo?.latestVersion == "2.0")
            #expect(architecture(of: foo, "1.0") == Self.roothide)
            #expect(architecture(of: foo, "2.0") == Self.rootless)
        }
    }

    @Test func aBuildNothingInstallsGoesOnceAnotherVersionInstalls() {
        let builds = [stanza("foo", "3.0", Self.rootful), stanza("foo", "1.0", Self.rootless)]
        for order in [builds, builds.reversed()] {
            let foo = read(Array(order), device: Self.rootless, installable: [Self.rootless])["foo"]
            #expect(foo?.payload.keys.sorted() == ["1.0"])
            #expect(foo?.supports(architecture: Self.rootless) == true)
        }
    }

    @Test func aPackageNothingInstallsStillShowsUpWithEveryVersion() {
        let foo = read(
            [stanza("foo", "1.0", Self.rootful), stanza("foo", "2.0", Self.roothide)],
            device: Self.rootless,
            installable: [Self.rootless]
        )["foo"]
        #expect(foo?.payload.keys.sorted() == ["1.0", "2.0"])
        #expect(foo?.supports(anyOf: [Self.rootless]) == false)
    }

    @Test func nativeBeatsAllBeatsAdaptable() {
        let builds = [stanza("foo", "1.0", "all"), stanza("foo", "1.0", Self.rootless), stanza("foo", "1.0", Self.roothide)]
        #expect(architecture(of: read(builds)["foo"], "1.0") == Self.roothide)
        #expect(architecture(of: read(Array(builds.prefix(2)))["foo"], "1.0") == "all")
        #expect(architecture(of: read(Array(builds.prefix(2).reversed()))["foo"], "1.0") == "all")
    }

    @Test func aMissingFieldIsAll() {
        let foo = read([stanza("foo", "1.0", Self.rootless), stanza("foo", "1.0", nil)])["foo"]
        #expect(foo?.payload["1.0"]?["architecture"] == nil)
        #expect(foo?.architectures == ["all"])
    }

    @Test func ofTwoBuildsThatFitAlikeTheFirstReadStays() {
        let foo = read([stanza("foo", "1.0", Self.roothide, mark: "-first"), stanza("foo", "1.0", Self.roothide, mark: "-second")])["foo"]
        #expect(foo?.payload["1.0"]?["filename"]?.contains("-first") == true)
    }

    @Test func aFieldNamingSeveralArchitecturesIsReadAsAList() {
        let foo = read([stanza("foo", "1.0", Self.rootless), stanza("foo", "1.0", "\(Self.rootful) \(Self.roothide)")])["foo"]
        #expect(foo?.architectures == [Self.rootful, Self.roothide])
    }

    @Test func otherPackagesAreLeftAlone() {
        let packages = read([stanza("foo", "1.0", Self.roothide), stanza("Bar", "1.0", Self.rootless), stanza("foo", "1.0", Self.rootless)])
        #expect(packages.keys.sorted() == ["bar", "foo"])
        #expect(packages["bar"]?.repoRef?.absoluteString == "https://example.org")
    }

    // MARK: versions(supportingAnyOf:)

    @Test func versionsAreFilteredByTheirOwnBuild() throws {
        let foo = try #require(read([stanza("foo", "1.0", Self.roothide), stanza("foo", "1.5", "all"), stanza("foo", "2.0", Self.rootless)])["foo"])
        #expect(foo.versions(supportingAnyOf: [Self.roothide])?.payload.keys.sorted() == ["1.0", "1.5"])
        #expect(foo.versions(supportingAnyOf: [Self.roothide])?.latestVersion == "1.5")
        #expect(foo.versions(supportingAnyOf: [Self.roothide, Self.rootless]) == foo)
        let adapted = try #require(read([stanza("bar", "2.0", Self.rootless)])["bar"])
        #expect(adapted.versions(supportingAnyOf: [Self.roothide]) == nil)
    }
}
