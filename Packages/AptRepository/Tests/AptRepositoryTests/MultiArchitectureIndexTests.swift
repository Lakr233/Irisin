@testable import AptRepository
import Foundation
import Testing

/// One repository listing the same package for several architectures: each
/// version keeps the build that fits the bootstrap best, and a build for
/// another bootstrap is dropped.
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

    /// Read on roothide, unless said otherwise.
    private func read(_ stanzas: [String], device: String = roothide) -> [String: Package] {
        _ = TestEnvironment.root
        return invokePackages(
            withContext: stanzas.joined(separator: "\n\n"),
            fromRepo: URL(string: "https://example.org"),
            device: device
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

    @Test func aVersionBuiltForAnotherBootstrapIsDropped() {
        let builds = [stanza("foo", "1.0", Self.roothide), stanza("foo", "2.0", Self.rootless)]
        for order in [builds, builds.reversed()] {
            let foo = read(Array(order))["foo"]
            #expect(foo?.payload.keys.sorted() == ["1.0"])
        }
    }

    @Test func aPackageNothingInstallsIsNotListed() {
        let packages = read([stanza("foo", "1.0", Self.rootful), stanza("foo", "2.0", Self.rootless)])
        #expect(packages["foo"] == nil)
    }

    /// An index whose every entry is for another bootstrap is an empty
    /// catalogue, not a page that is no catalogue at all.
    @Test func anIndexOfForeignPackagesStillCountsItsEntries() {
        let read = readPackageIndex(
            [stanza("foo", "1.0", Self.rootless), stanza("bar", "1.0", Self.rootful)].joined(separator: "\n\n"),
            device: Self.roothide
        )
        #expect(read.packages.isEmpty)
        #expect(read.entries == 2)
        #expect(readPackageIndex("<html>captive portal</html>", device: Self.roothide).entries == 0)
    }

    @Test func nativeBeatsAll() {
        let builds = [stanza("foo", "1.0", "all"), stanza("foo", "1.0", Self.roothide)]
        #expect(architecture(of: read(builds)["foo"], "1.0") == Self.roothide)
        #expect(architecture(of: read(builds.reversed())["foo"], "1.0") == Self.roothide)
        #expect(architecture(of: read([stanza("foo", "1.0", "all"), stanza("foo", "1.0", Self.rootless)])["foo"], "1.0") == "all")
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
        let packages = read([stanza("foo", "1.0", Self.roothide), stanza("Bar", "1.0", "all"), stanza("foo", "1.0", Self.rootless)])
        #expect(packages.keys.sorted() == ["bar", "foo"])
        #expect(packages["bar"]?.repoRef?.absoluteString == "https://example.org")
    }

    // MARK: versions(supportingAnyOf:)

    @Test func versionsAreFilteredByTheirOwnBuild() {
        let foo = Package(identity: "foo", payload: [
            "1.0": ["package": "foo", "version": "1.0", "architecture": Self.roothide],
            "1.5": ["package": "foo", "version": "1.5", "architecture": "all"],
            "2.0": ["package": "foo", "version": "2.0", "architecture": Self.rootless],
        ])
        #expect(foo.versions(supportingAnyOf: [Self.roothide])?.payload.keys.sorted() == ["1.0", "1.5"])
        #expect(foo.versions(supportingAnyOf: [Self.roothide])?.latestVersion == "1.5")
        #expect(foo.versions(supportingAnyOf: [Self.roothide, Self.rootless]) == foo)
    }

    // MARK: update(over:device:)

    @Test func anUpdateIsANewerVersionBuiltForTheDevice() throws {
        let foo = try #require(read([stanza("foo", "1.5", Self.roothide), stanza("foo", "1.2", "all")])["foo"])
        #expect(foo.update(over: "1.0", device: Self.roothide)?.latestVersion == "1.5")
        #expect(foo.update(over: "1.5", device: Self.roothide) == nil)
        #expect(foo.update(over: "2.0", device: Self.roothide) == nil)
    }

    /// What a list row compares the installed version with.
    @Test func aRowIsJudgedOnTheVersionsBuiltForTheDevice() throws {
        let foo = try #require(read([stanza("foo", "1.5", Self.roothide)])["foo"])
        #expect(foo.version(comparedWith: "1.0", device: Self.roothide) == "1.5")
        #expect(foo.version(comparedWith: "1.5", device: Self.roothide) == "1.5")
        // the installed version, when the record has it, is never behind itself
        let held = Package(identity: "foo", payload: [
            "1.5": ["package": "foo", "version": "1.5", "architecture": Self.roothide],
            "2.0": ["package": "foo", "version": "2.0", "architecture": Self.rootless],
        ])
        #expect(held.version(comparedWith: "2.0", device: Self.roothide) == "2.0")
    }
}
