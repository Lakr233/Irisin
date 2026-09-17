import CryptoKit
@testable import IrisinAdapter
import IrisinProtocol
import XCTest

/// Stands in for a real adapter: rootful in, rootless out, the control
/// paragraph's `Architecture:` rewritten and nothing else. It proves the
/// registry and the staging hook, not any conversion.
private struct StubAdapter: PackageAdapter {
    let source = BootstrapArchitecture.rootful
    let target = BootstrapArchitecture.rootless

    func canAttemptInstall(control: [String: String]) -> Bool {
        control["package"] != "com.example.refused"
    }

    func adapt(preparedPackageAt directory: URL) throws -> String {
        let manifest = try PreparedPackage.read(from: directory)
        let control = manifest.control.replacingOccurrences(
            of: "Architecture: \(source.rawValue)",
            with: "Architecture: \(target.rawValue)"
        )
        return try PreparedPackage(control: control, controlFiles: manifest.controlFiles, entries: manifest.entries)
            .write(to: directory)
    }
}

final class PackageAdaptersTests: XCTestCase {
    private let registry = PackageAdapters(adapters: [StubAdapter()])

    func testInstallableArchitecturesFollowTheAdapterList() {
        XCTAssertEqual(registry.installable(on: "iphoneos-arm64"), ["iphoneos-arm64", "iphoneos-arm"])
        XCTAssertEqual(registry.installable(on: "iphoneos-arm64e"), ["iphoneos-arm64e"])
        XCTAssertEqual(PackageAdapters(adapters: []).installable(on: "iphoneos-arm64e"), ["iphoneos-arm64e"])
    }

    /// What ships: roothide sees the rootless catalogue, rootless sees only
    /// its own, and a rootless package that is not what the conversion
    /// takes stops there, its tree untouched, rather than reaching the
    /// helper as it was built.
    func testShippedAdapters() throws {
        XCTAssertEqual(PackageAdapters.installed.installable(on: "iphoneos-arm64e"), ["iphoneos-arm64e", "iphoneos-arm64"])
        XCTAssertEqual(PackageAdapters.installed.installable(on: "iphoneos-arm64"), ["iphoneos-arm64"])
        XCTAssertEqual(PackageAdapters.installed.impliedPreDepends(on: "iphoneos-arm64e"), "rootless-compat(>= 0.9)")
        XCTAssertNil(PackageAdapters.installed.impliedPreDepends(on: "iphoneos-arm64"))
        let directory = try prepared(architecture: "iphoneos-arm64")
        let before = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try PackageAdapters.installed.adapt(preparedPackageAt: directory, on: "iphoneos-arm64e")) {
            XCTAssertEqual($0 as? AdaptationFailure, .notSimple(package: "com.example.tweak", path: "Library/MobileSubstrate/DynamicLibraries/Tweak.dylib"))
        }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), before)
        XCTAssertNil(try PackageAdapters.installed.adapt(preparedPackageAt: directory, on: "iphoneos-arm64"))
    }

    func testAdapterSelection() {
        let rootful = ["package": "com.example.tweak", "architecture": "iphoneos-arm"]
        XCTAssertNotNil(registry.adapter(for: rootful, on: "iphoneos-arm64"))
        XCTAssertNil(registry.adapter(for: rootful, on: "iphoneos-arm64e"), "no adapter targets roothide")
        XCTAssertNil(registry.adapter(for: ["architecture": "all"], on: "iphoneos-arm64"))
        XCTAssertNil(registry.adapter(for: ["architecture": "iphoneos-arm64"], on: "iphoneos-arm64"))
    }

    /// The field is a list, as dpkg and the catalogue read it. A package
    /// that named two architectures was offered for the one an adapter
    /// rewrites, asked about as compatibility mode — and then installed as
    /// built, because nothing matched the whole field.
    func testAdapterSelectionReadsTheArchitectureFieldAsAList() {
        XCTAssertNotNil(registry.adapter(for: ["architecture": "iphoneos-arm iphoneos-armv7"], on: "iphoneos-arm64"))
        XCTAssertNotNil(registry.adapter(for: ["architecture": "iphoneos-armv7, iphoneos-arm"], on: "iphoneos-arm64"))
        XCTAssertNil(
            registry.adapter(for: ["architecture": "iphoneos-arm iphoneos-arm64"], on: "iphoneos-arm64"),
            "one of the names is this bootstrap's own, so it needs no adapter"
        )
        XCTAssertNil(registry.adapter(for: ["architecture": "iphoneos-arm all"], on: "iphoneos-arm64"))
        XCTAssertNil(registry.adapter(for: [:], on: "iphoneos-arm64"))
    }

    /// Refused is not the same as fitting: the tree its adapter will not
    /// convert must not go to the helper as it was built.
    func testAPackageTheAdapterRefusesIsNotInstalledAsBuilt() throws {
        let directory = try prepared(architecture: "iphoneos-arm", package: "com.example.refused")
        XCTAssertThrowsError(try registry.adapt(preparedPackageAt: directory, on: "iphoneos-arm64")) {
            XCTAssertEqual($0 as? AdaptationFailure, .incompatible(package: "com.example.refused"))
        }
    }

    func testAdaptRewritesTheManifestAndReturnsItsDigest() throws {
        let directory = try prepared(architecture: "iphoneos-arm")
        let digest = try XCTUnwrap(registry.adapt(preparedPackageAt: directory, on: "iphoneos-arm64"))
        let bytes = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(digest, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let rewritten = try PreparedPackage.read(from: directory)
        XCTAssertEqual(try DebianControl.parse(rewritten.control)["architecture"], "iphoneos-arm64")
        XCTAssertEqual(rewritten.entries, try PreparedPackage.read(from: prepared(architecture: "iphoneos-arm")).entries)
    }

    func testPackagesThatFitAreLeftAlone() throws {
        for architecture in ["all", "iphoneos-arm64"] {
            let directory = try prepared(architecture: architecture)
            let before = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            XCTAssertNil(try registry.adapt(preparedPackageAt: directory, on: "iphoneos-arm64"))
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), before)
        }
        // built for a bootstrap nothing converts: left for the helper as before
        XCTAssertNil(try registry.adapt(preparedPackageAt: prepared(architecture: "iphoneos-arm64e"), on: "iphoneos-arm64"))
    }

    func testWritingBackUnchangedReproducesThePreparedDigest() throws {
        let directory = try prepared(architecture: "iphoneos-arm")
        let before = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let digest = try PreparedPackage.read(from: directory).write(to: directory)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), before)
        XCTAssertEqual(digest, SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined())
    }

    /// A prepared tree the way `ArchiveStream.prepareDebianPackage` lays it
    /// out: a sorted-keys manifest and one blob.
    private func prepared(architecture: String, package: String = "com.example.tweak") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("irisin-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let blob = Data("hello".utf8)
        try blob.write(to: directory.appendingPathComponent("blob-1"))
        let file = PreparedFile(
            name: "blob-1",
            sha256: SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined(),
            md5: Insecure.MD5.hash(data: blob).map { String(format: "%02x", $0) }.joined(),
            size: Int64(blob.count)
        )
        let manifest = PreparedPackage(
            control: "Package: \(package)\nVersion: 1.0\nArchitecture: \(architecture)\n",
            controlFiles: [:],
            entries: [PreparedEntry(
                path: "Library/MobileSubstrate/DynamicLibraries/Tweak.dylib",
                kind: .file, file: file, mode: 0o644, uid: 0, gid: 0, modificationTime: 0
            )]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}
