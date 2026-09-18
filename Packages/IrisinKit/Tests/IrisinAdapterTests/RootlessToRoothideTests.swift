import CryptoKit
@testable import IrisinAdapter
import IrisinProtocol
import XCTest

/// The whole conversion over a prepared tree built here. What each step
/// makes of its input is held to the device's tools elsewhere
/// (`MachOBinaryTests`, `RootlessToRoothideTextTests`, and the conformance
/// test over real packages); this is the assembly.
final class RootlessToRoothideTests: XCTestCase {
    private let tweak = "var/jb/Library/MobileSubstrate/DynamicLibraries/Fixture.dylib"

    func testSimpleTweak() throws {
        let library = try fixture("input/Fixture.dylib")
        let directory = try prepared(entries: [
            .directory("var"), .directory("var/jb"), .directory("var/jb/Library"),
            .file(tweak, library, mode: 0o755),
            .file("var/jb/Library/MobileSubstrate/DynamicLibraries/Fixture.plist", Data("{ Filter = {}; }".utf8)),
            .file("var/jb/Library/MobileSubstrate/.DS_Store", Data("finder".utf8)),
            // no entry for any directory above it: the script's repacking lists them all
            .file("var/jb/Library/PreferenceBundles/Fixture.bundle/FixtureBundle", fixture("input/FixtureBundle"), mode: 0o755),
            .file("var/jb/Library/PreferenceBundles/Fixture.bundle/icon.png", library),
            .link("var/jb/usr/lib/libfixture.dylib", to: "/var/jb/Library/MobileSubstrate/DynamicLibraries/Fixture.dylib"),
        ], control: [
            "postinst": Data("#!/bin/sh\nchown mobile /var/jb/Library/Fixture /Library/Fixture\n".utf8),
            "md5sums": Data("0  var/jb/x\n".utf8),
        ])
        let before = try PreparedPackage.read(from: directory)
        let digest = try XCTUnwrap(PackageAdapters.installed.adapt(preparedPackageAt: directory, on: "iphoneos-arm64e"))
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(digest, SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined())
        let adapted = try PreparedPackage.read(from: directory)
        let mirror = "var/mobile/Library/pkgmirror"

        XCTAssertEqual(adapted.entries.map(\.path), [
            "Library",
            "Library/MobileSubstrate",
            "Library/MobileSubstrate/DynamicLibraries",
            "Library/MobileSubstrate/DynamicLibraries/Fixture.dylib",
            "Library/MobileSubstrate/DynamicLibraries/Fixture.dylib.roothidepatch",
            "Library/MobileSubstrate/DynamicLibraries/Fixture.plist",
            "Library/PreferenceBundles",
            "Library/PreferenceBundles/Fixture.bundle",
            "Library/PreferenceBundles/Fixture.bundle/FixtureBundle",
            "Library/PreferenceBundles/Fixture.bundle/FixtureBundle.roothidepatch",
            "Library/PreferenceBundles/Fixture.bundle/icon.png",
            "usr",
            "usr/lib",
            "usr/lib/libfixture.dylib",
            "var",
            "var/mobile",
            "var/mobile/Library",
            mirror,
            "\(mirror)/DEBIAN.com.example.fixture",
            "\(mirror)/DEBIAN.com.example.fixture/control",
            "\(mirror)/DEBIAN.com.example.fixture/md5sums",
            "\(mirror)/DEBIAN.com.example.fixture/postinst",
            "\(mirror)/Library",
            "\(mirror)/Library/MobileSubstrate",
            "\(mirror)/Library/MobileSubstrate/DynamicLibraries",
            "\(mirror)/Library/MobileSubstrate/DynamicLibraries/Fixture.dylib",
            "\(mirror)/Library/MobileSubstrate/DynamicLibraries/Fixture.plist",
            "\(mirror)/Library/PreferenceBundles",
            "\(mirror)/Library/PreferenceBundles/Fixture.bundle",
            "\(mirror)/Library/PreferenceBundles/Fixture.bundle/FixtureBundle",
            "\(mirror)/Library/PreferenceBundles/Fixture.bundle/icon.png",
            "\(mirror)/usr",
            "\(mirror)/usr/lib",
            "\(mirror)/usr/lib/libfixture.dylib",
        ])
        let entries = Dictionary(uniqueKeysWithValues: adapted.entries.map { ($0.path, $0) })
        func original(_ path: String) -> PreparedFile? {
            before.entries.first { $0.path == path }?.file
        }

        // the library is what the device's tools make of it, under a new
        // blob numbered past everything in the directory; its mirror is the
        // package's own
        let patched = try XCTUnwrap(entries["Library/MobileSubstrate/DynamicLibraries/Fixture.dylib"]?.file)
        XCTAssertEqual(patched.name, "blob-91")
        XCTAssertEqual(try contents(patched, in: directory), try fixture("expected/Fixture.dylib"))
        XCTAssertEqual(entries["Library/MobileSubstrate/DynamicLibraries/Fixture.dylib"]?.mode, 0o755)
        XCTAssertEqual(entries["\(mirror)/Library/MobileSubstrate/DynamicLibraries/Fixture.dylib"]?.file, original(tweak))
        XCTAssertEqual(
            try contents(XCTUnwrap(entries["Library/PreferenceBundles/Fixture.bundle/FixtureBundle"]?.file), in: directory),
            try fixture("expected/FixtureBundle")
        )
        // a name the patcher never opens
        XCTAssertEqual(entries["Library/PreferenceBundles/Fixture.bundle/icon.png"]?.file, original("var/jb/Library/PreferenceBundles/Fixture.bundle/icon.png"))

        let mark = try XCTUnwrap(entries["Library/MobileSubstrate/DynamicLibraries/Fixture.dylib.roothidepatch"])
        XCTAssertEqual(mark.kind, .symbolicLink)
        XCTAssertEqual(mark.linkTarget, "/usr/lib/DynamicPatches/AutoPatches.dylib")
        XCTAssertEqual([mark.uid, mark.gid, mark.mode], [0, 0, 0o755])
        // the helper translates an absolute target; the patcher leaves it, and so does this
        XCTAssertEqual(entries["usr/lib/libfixture.dylib"]?.linkTarget, "/var/jb/Library/MobileSubstrate/DynamicLibraries/Fixture.dylib")

        for entry in adapted.entries where entry.path.hasPrefix(mirror) {
            XCTAssertEqual([entry.uid, entry.gid, entry.mode], [501, 501, 0o755], entry.path)
        }
        XCTAssertEqual([entries["var/mobile"]?.uid, entries["Library/PreferenceBundles"]?.uid], [0, 0])

        XCTAssertEqual(adapted.control, """
        Package: com.example.fixture
        Version: 1.0
        Architecture: iphoneos-arm64e
        Pre-Depends: rootless-compat(>= 0.9)

        """)
        XCTAssertEqual(try contents(XCTUnwrap(adapted.controlFiles["control"]), in: directory), Data(adapted.control.utf8))
        XCTAssertEqual(entries["\(mirror)/DEBIAN.com.example.fixture/control"]?.file, before.controlFiles["control"])
        XCTAssertEqual(
            try contents(XCTUnwrap(adapted.controlFiles["postinst"]), in: directory),
            Data("#!/bin/sh\nchown mobile /Library/Fixture /rootfs/Library/Fixture\n".utf8)
        )
        XCTAssertEqual(adapted.controlFiles["md5sums"], before.controlFiles["md5sums"])

        // every blob the manifest names is there and is what the manifest says: the helper checks
        for file in adapted.entries.compactMap(\.file) + adapted.controlFiles.values {
            let data = try contents(file, in: directory)
            XCTAssertEqual(file.size, Int64(data.count))
            XCTAssertEqual(file.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(file.md5, Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
    }

    func testTheSamePackageAdaptsToTheSameManifest() throws {
        let digests = try (0 ..< 2).map { _ in
            try RootlessToRoothide().adapt(preparedPackageAt: prepared(entries: [.file(tweak, fixture("input/Fixture.dylib"))]))
        }
        XCTAssertEqual(digests[0], digests[1])
    }

    /// A theme: nothing for the compat layer to load, so no Pre-Depends and
    /// nothing it would bring in. A Mach-O under a name the patcher never
    /// opens (`icon.png`) is no code either.
    func testAPackageWithNoMachOGetsNoCompatLayer() throws {
        let entries: [Entry] = try [
            .file("var/jb/Library/Themes/Fixture.theme/Info.plist", Data("{}".utf8)),
            .file("var/jb/Library/Themes/Fixture.theme/IconBundles/icon.png", fixture("input/Fixture.dylib")),
            .file("var/jb/Library/Themes/.DS_Store", fixture("input/Fixture.dylib")),
        ]
        let theme = try prepared(entries: entries)
        XCTAssertTrue(try PackageAdapters.installed.addsNoPreDepends(adaptingPreparedPackageAt: theme, on: "iphoneos-arm64e"))
        let adapted = try PreparedPackage.read(from: theme)
        XCTAssertEqual(adapted.control, "Package: com.example.fixture\nVersion: 1.0\nArchitecture: iphoneos-arm64e\n")
        XCTAssertFalse(adapted.entries.contains { $0.path.hasSuffix(".roothidepatch") })

        let code = try prepared(entries: entries + [.file(tweak, fixture("input/Fixture.dylib"))])
        XCTAssertFalse(try PackageAdapters.installed.addsNoPreDepends(adaptingPreparedPackageAt: code, on: "iphoneos-arm64e"))
        // on rootless no adapter adds anything, so there is nothing to leave out
        XCTAssertFalse(try PackageAdapters.installed.addsNoPreDepends(adaptingPreparedPackageAt: code, on: "iphoneos-arm64"))
    }

    /// ldid signs a file under its own name, so one blob the archive shares
    /// between two names comes out as two.
    func testOneBlobUnderTwoNames() throws {
        let directory = try prepared(entries: [
            .file("var/jb/usr/lib/FixtureBundle", fixture("input/FixtureBundle")),
            .file("var/jb/usr/lib/Other", nil),
            .file("var/jb/usr/lib/again/Other", nil),
        ])
        _ = try RootlessToRoothide().adapt(preparedPackageAt: directory)
        let files = try PreparedPackage.read(from: directory).entries.filter { !$0.path.hasPrefix("var/") }.compactMap(\.file)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(try contents(files[0], in: directory), try fixture("expected/FixtureBundle"))
        XCTAssertNotEqual(files[0], files[1])
        XCTAssertEqual(files[1], files[2])
    }

    func testWhatIsNotASimpleTweakIsRefused() throws {
        let library = try fixture("input/Fixture.dylib")
        var program = library // a fat program whose first slice is armv7
        program.replaceSubrange(16384 ..< 16388, with: [0xCE, 0xFA, 0xED, 0xFE])
        program[98304 + 12] = 2
        var malformed = try fixture("input/FixtureBundle")
        malformed.replaceSubrange(20 ..< 24, with: [0xFF, 0xFF, 0xFF, 0x7F])
        let ok = Data("x".utf8)
        let cases: [(String, [Entry], [String: Data])] = try [
            ("Library/Fixture.dylib", [.file("Library/Fixture.dylib", library)], [:]),
            ("var/jb", [.link("var/jb", to: "/")], [:]),
            ("var", [.link("var", to: "/private/var")], [:]),
            ("var/jb/usr/bin/fixture-tool", [.file("var/jb/usr/bin/fixture-tool", fixture("input/fixture-tool"))], [:]),
            (tweak, [.file(tweak, program)], [:]),
            ("var/jb/Applications/Fixture.app/Info.plist", [.file("var/jb/Applications/Fixture.app/Info.plist", ok)], [:]),
            ("var/jb/Library/LaunchDaemons/fixture.plist", [.file("var/jb/Library/LaunchDaemons/fixture.plist", ok)], [:]),
            ("var/jb/Library/libSandy/Fixture.plist", [.file("var/jb/Library/libSandy/Fixture.plist", ok)], [:]),
            ("var/jb/usr/lib/fixture.sh", [.file("var/jb/usr/lib/fixture.sh", ok, mode: 0o4755)], [:]),
            ("var/jb/usr/lib/Fixture.dylib", [.file(tweak, library), .hardLink("var/jb/usr/lib/Fixture.dylib", to: tweak)], [:]),
            ("DEBIAN/extrainst_", [.file(tweak, library)], ["extrainst_": library]),
            ("DEBIAN/conffiles", [.file("var/jb/etc/fixture.conf", ok)], ["conffiles": Data("/var/jb/etc/fixture.conf\n".utf8)]),
            // where the payload would land once `var/jb/` is gone
            ("var/jb/var/mobile/Library/pkgmirror", [.file(tweak, library), .file("var/jb/var/mobile/Library/pkgmirror", ok)], [:]),
            ("var/jb/var/mobile/Library/pkgmirror/x", [.file("var/jb/var/mobile/Library/pkgmirror/x", ok)], [:]),
            ("var/jb/var/jb/x", [.file("var/jb/var/jb/x", ok)], [:]),
            ("var/jb/rootfs/private/var/x", [.file("var/jb/rootfs/private/var/x", ok)], [:]),
            ("var/jb/DEBIAN/postinst", [.file("var/jb/DEBIAN/postinst", ok)], [:]),
            // a path beneath one of the package's own links, in either order
            ("var/jb/Library/Escape/x", [.link("var/jb/Library/Escape", to: "/rootfs/private/var"), .file("var/jb/Library/Escape/x", ok)], [:]),
            ("var/jb/Library/Escape", [.file("var/jb/Library/Escape/x", ok), .link("var/jb/Library/Escape", to: "/rootfs/private/var")], [:]),
            ("var/jb/Library/Escape/x", [.file("var/jb/Library/Escape", ok), .file("var/jb/Library/Escape/x", ok)], [:]),
            // the mark the adapter writes beside a library, already taken
            (tweak + ".roothidepatch", [.link(tweak + ".roothidepatch", to: "/elsewhere"), .file(tweak, library)], [:]),
        ]
        for (path, entries, control) in cases {
            let directory = try prepared(entries: entries, control: control)
            let before = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let failure = AdaptationFailure.notSimple(package: "com.example.fixture", path: path)
            XCTAssertThrowsError(try RootlessToRoothide().adapt(preparedPackageAt: directory), path) {
                XCTAssertEqual($0 as? AdaptationFailure, failure, path)
            }
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), before, path)
        }

        let directory = try prepared(entries: [.file(tweak, malformed)])
        XCTAssertThrowsError(try RootlessToRoothide().adapt(preparedPackageAt: directory)) {
            XCTAssertEqual($0 as? AdaptationFailure, .malformedBinary(package: "com.example.fixture", path: tweak))
        }
    }

    /// Links are carried as the package spells them, in the payload and in
    /// the mirror: a link to a library is not a library and gets no mark,
    /// and an empty conffiles list is no conffiles.
    func testLinksAndDirectoriesAreCarriedAsTheyAre() throws {
        let directory = try prepared(entries: [
            .file("var/jb/usr/lib/Fixture.dylib", fixture("input/Fixture.dylib")),
            .link("var/jb/usr/lib/libfixture.dylib", to: "Fixture.dylib"),
            .link("var/jb/usr/lib/system", to: "/rootfs/usr/lib/libSystem.B.dylib"),
            // listed after what is inside it: its own mode is what unpacking leaves
            .directory("var/jb/usr/lib", mode: 0o700),
        ], control: ["conffiles": Data("\n \n".utf8)])
        _ = try RootlessToRoothide().adapt(preparedPackageAt: directory)
        let entries = try Dictionary(uniqueKeysWithValues: PreparedPackage.read(from: directory).entries.map { ($0.path, $0) })
        let mirror = "var/mobile/Library/pkgmirror/"
        XCTAssertNotNil(entries["usr/lib/Fixture.dylib.roothidepatch"])
        XCTAssertNil(entries["usr/lib/libfixture.dylib.roothidepatch"])
        XCTAssertNil(entries["usr/lib/system.roothidepatch"])
        for (path, target) in ["usr/lib/libfixture.dylib": "Fixture.dylib", "usr/lib/system": "/rootfs/usr/lib/libSystem.B.dylib"] {
            XCTAssertEqual(entries[path]?.kind, .symbolicLink)
            XCTAssertEqual(entries[path]?.linkTarget, target)
            XCTAssertEqual([entries[path]?.uid, entries[path]?.gid], [0, 0])
            XCTAssertEqual(entries[mirror + path]?.linkTarget, target)
            XCTAssertEqual([entries[mirror + path]?.uid, entries[mirror + path]?.gid], [501, 501])
        }
        XCTAssertEqual(entries["usr/lib"]?.mode, 0o700)
        XCTAssertEqual(entries[mirror + "usr/lib"]?.mode, 0o755)
        XCTAssertEqual(entries["usr"]?.mode, 0o755)
    }

    /// The patcher's own list, matched as it matches: anywhere in the name.
    func testPackagesThePatcherRefuses() throws {
        let adapter = RootlessToRoothide()
        XCTAssertTrue(adapter.canAttemptInstall(control: ["package": "com.example.fixture", "maintainer": "Someone"]))
        XCTAssertFalse(adapter.canAttemptInstall(control: ["package": "ellekit"]))
        XCTAssertFalse(adapter.canAttemptInstall(control: ["package": "com.opa334.altlist"]))
        XCTAssertFalse(adapter.canAttemptInstall(control: ["package": "zsh", "maintainer": "Procursus Team <support@procurs.us>"]))
        let directory = try prepared(entries: [.file(tweak, fixture("input/Fixture.dylib"))], package: "com.opa334.altlist")
        XCTAssertThrowsError(try PackageAdapters.installed.adapt(preparedPackageAt: directory, on: "iphoneos-arm64e")) {
            XCTAssertEqual($0 as? AdaptationFailure, .incompatible(package: "com.opa334.altlist"))
        }
    }

    // MARK: - A prepared tree

    private struct Entry {
        var path: String
        var kind: PreparedEntryKind
        /// nil shares the blob of the file before it, as an archive's hard
        /// link resolved to a copy would.
        var data: Data?
        var link: String?
        var mode: UInt32

        static func directory(_ path: String, mode: UInt32 = 0o755) -> Entry {
            Entry(path: path, kind: .directory, mode: mode)
        }

        static func file(_ path: String, _ data: Data?, mode: UInt32 = 0o644) -> Entry {
            Entry(path: path, kind: .file, data: data, mode: mode)
        }

        static func link(_ path: String, to target: String) -> Entry {
            Entry(path: path, kind: .symbolicLink, link: target, mode: 0o777)
        }

        static func hardLink(_ path: String, to target: String) -> Entry {
            Entry(path: path, kind: .hardLink, link: target, mode: 0o644)
        }
    }

    private func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.resourceURL?.appendingPathComponent(path)))
    }

    private func contents(_ file: PreparedFile, in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(file.name))
    }

    /// As `ArchiveStream.prepareDebianPackage` leaves it, the members of the
    /// archive itself included: blobs the manifest never names.
    private func prepared(entries: [Entry], control: [String: Data] = [:], package: String = "com.example.fixture") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("irisin-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var sequence = 0
        func store(_ data: Data) throws -> PreparedFile {
            sequence += 1
            try data.write(to: directory.appendingPathComponent("blob-\(sequence)"))
            return PreparedFile(
                name: "blob-\(sequence)",
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                md5: Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                size: Int64(data.count)
            )
        }
        let text = "Package: \(package)\nVersion: 1.0\nArchitecture: iphoneos-arm64\n"
        var controlFiles = try control.mapValues(store)
        controlFiles["control"] = try store(Data(text.utf8))
        var last: PreparedFile?
        let prepared = try entries.map { entry -> PreparedEntry in
            if entry.kind == .file {
                last = try entry.data.map(store) ?? last
            }
            return PreparedEntry(
                path: entry.path, kind: entry.kind, file: entry.kind == .file ? last : nil, linkTarget: entry.link,
                mode: entry.mode, uid: 0, gid: 0, modificationTime: 1_700_000_000
            )
        }
        try Data("2.0\n".utf8).write(to: directory.appendingPathComponent("blob-90"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(PreparedPackage(control: text, controlFiles: controlFiles, entries: prepared))
            .write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}
