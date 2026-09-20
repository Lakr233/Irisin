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
        // root's, as `ln` made it, in the group tar made its directory with
        XCTAssertEqual([mark.uid, mark.gid, mark.mode], [0, 501, 0o755])
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
        XCTAssertNotNil(try PackageAdapters.installed.adapt(preparedPackageAt: theme, on: "iphoneos-arm64e"))
        XCTAssertNil(try PackageAdapters.installed.control(ofPreparedPackageAt: theme)["pre-depends"])
        let adapted = try PreparedPackage.read(from: theme)
        XCTAssertEqual(adapted.control, "Package: com.example.fixture\nVersion: 1.0\nArchitecture: iphoneos-arm64e\n")
        XCTAssertFalse(adapted.entries.contains { $0.path.hasSuffix(".roothidepatch") })

        let code = try prepared(entries: entries + [.file(tweak, fixture("input/Fixture.dylib"))])
        XCTAssertNotNil(try PackageAdapters.installed.adapt(preparedPackageAt: code, on: "iphoneos-arm64e"))
        // what the preview said it would be
        XCTAssertEqual(
            try PackageAdapters.installed.control(ofPreparedPackageAt: code)["pre-depends"],
            "rootless-compat(>= 0.9)"
        )
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

    /// An app is a directory of files and programs like any other: its
    /// bundle moves under the jailbreak root, each program is signed with
    /// roothide's entitlements merged into its own and marked for the
    /// compat layer, and the mirror keeps the package as it was shipped.
    func testApp() throws {
        let app = "var/jb/Applications/Fixture.app"
        let directory = try prepared(entries: [
            .file("\(app)/FixtureApp", fixture("input/FixtureApp"), mode: 0o755),
            .file("\(app)/Info.plist", Data("{ CFBundleIdentifier = com.example.fixture; }".utf8)),
            .file("\(app)/Frameworks/Fixture.dylib", fixture("input/Fixture.dylib"), mode: 0o755),
            .file("var/jb/usr/bin/fixture-tool", fixture("input/fixture-tool"), mode: 0o755),
        ], control: ["postinst": Data("#!/bin/sh\nuicache -p /var/jb/Applications/Fixture.app\n".utf8)])
        let before = try PreparedPackage.read(from: directory)
        _ = try XCTUnwrap(PackageAdapters.installed.adapt(preparedPackageAt: directory, on: "iphoneos-arm64e"))
        let adapted = try PreparedPackage.read(from: directory)
        let entries = Dictionary(uniqueKeysWithValues: adapted.entries.map { ($0.path, $0) })
        let mirror = "var/mobile/Library/pkgmirror"

        for (path, expected) in [
            "Applications/Fixture.app/FixtureApp": "FixtureApp",
            "Applications/Fixture.app/Frameworks/Fixture.dylib": "Fixture.dylib",
            "usr/bin/fixture-tool": "fixture-tool",
        ] {
            XCTAssertEqual(try contents(XCTUnwrap(entries[path]?.file, path), in: directory), try fixture("expected/\(expected)"), path)
            XCTAssertEqual(entries[path]?.mode, 0o755, path)
            XCTAssertEqual(entries[path + ".roothidepatch"]?.linkTarget, "/usr/lib/DynamicPatches/AutoPatches.dylib", path)
            XCTAssertEqual(entries["\(mirror)/\(path)"]?.file, before.entries.first { $0.path == "var/jb/" + path }?.file, path)
        }
        // plutil's XML, as for every property list
        XCTAssertEqual(
            try contents(XCTUnwrap(entries["Applications/Fixture.app/Info.plist"]?.file), in: directory),
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.fixture"], format: .xml, options: 0)
        )
        XCTAssertTrue(adapted.control.contains("Pre-Depends: rootless-compat(>= 0.9)\n"))
        XCTAssertEqual(
            try contents(XCTUnwrap(adapted.controlFiles["postinst"]), in: directory),
            Data("#!/bin/sh\nuicache -p /Applications/Fixture.app\n".utf8)
        )
    }

    /// A daemon's list and a libSandy profile have their paths respelled,
    /// and a list at the top is a daemon's to the patcher's pattern; any
    /// other list is only written as XML. The names of a hard link stay one
    /// file until ldid or sed writes one anew, the first of them in
    /// `dpkg-deb`'s walk the file; in the mirror they all stay one.
    func testDaemonsProfilesAndHardLinks() throws {
        let daemon = Data("{ Label = fixture; ProgramArguments = (/var/jb/usr/libexec/fixtured, \"--root=/var/jb\"); }".utf8)
        let profile = Data("{ Extensions = (/var/jb/Library/Fixture, /Library/Fixture, /, \"see /usr/lib\", /var/jb); }".utf8)
        let program = try fixture("input/fixture-tool")
        let script = Data("/var/jb/usr/bin/x /usr/lib\n".utf8)
        let directory = try prepared(entries: [
            .file("var/jb/Library/LaunchDaemons/fixtured.plist", daemon),
            .hardLink("var/jb/usr/share/fixture/b.plist", to: "var/jb/Library/LaunchDaemons/fixtured.plist"),
            .hardLink("var/jb/usr/share/fixture/a.plist", to: "var/jb/usr/share/fixture/b.plist"),
            .file("var/jb/Library/libSandy/Fixture.plist", profile),
            .file("var/jb/fixture.plist", daemon),
            .file("var/jb/usr/libexec/fixtured", program, mode: 0o755),
            .hardLink("var/jb/usr/bin/fixtured-link", to: "var/jb/usr/libexec/fixtured"),
            .file("var/jb/usr/share/fixture/inst", script),
            .hardLink("var/jb/usr/share/fixture/inst.copy", to: "var/jb/usr/share/fixture/inst"),
        ])
        _ = try RootlessToRoothide().adapt(preparedPackageAt: directory)
        let entries = try Dictionary(uniqueKeysWithValues: PreparedPackage.read(from: directory).entries.map { ($0.path, $0) })
        func text(_ path: String) throws -> Data {
            try contents(XCTUnwrap(entries[path]?.file, path), in: directory)
        }
        func xml(_ list: Any) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
        }

        let respelled = try xml(["Label": "fixture", "ProgramArguments": ["/usr/libexec/fixtured", "--root=/var/jb"]])
        XCTAssertEqual(try text("Library/LaunchDaemons/fixtured.plist"), respelled)
        XCTAssertEqual(try text("fixture.plist"), respelled)
        XCTAssertEqual(
            try text("Library/libSandy/Fixture.plist"),
            try xml(["Extensions": ["/Library/Fixture", "/rootfs/Library/Fixture", "/rootfs/", "see /usr/lib", "/var/jb"]])
        )
        // the daemon's name was written anew; the other two share plutil's XML
        XCTAssertEqual(try text("usr/share/fixture/a.plist"), try RootlessToRoothide.xml(daemon))
        XCTAssertEqual(entries["usr/share/fixture/b.plist"]?.kind, .hardLink)
        XCTAssertEqual(entries["usr/share/fixture/b.plist"]?.linkTarget, "usr/share/fixture/a.plist")
        // ldid signs each name of the program as a file of its own, under that name
        for path in ["usr/libexec/fixtured", "usr/bin/fixtured-link"] {
            XCTAssertEqual(entries[path]?.kind, .file, path)
            XCTAssertEqual(entries[path]?.mode, 0o755, path)
            XCTAssertNotNil(entries[path + ".roothidepatch"], path)
        }
        XCTAssertNotEqual(entries["usr/libexec/fixtured"]?.file, entries["usr/bin/fixtured-link"]?.file)
        // a payload file named like a script is edited as one; its other name is not
        XCTAssertEqual(try text("usr/share/fixture/inst"), Data("/usr/bin/x /rootfs/usr/lib\n".utf8))
        XCTAssertEqual(try text("usr/share/fixture/inst.copy"), script)

        let mirror = "var/mobile/Library/pkgmirror/"
        for (path, target) in [
            "usr/share/fixture/a.plist": "Library/LaunchDaemons/fixtured.plist",
            "usr/share/fixture/b.plist": "Library/LaunchDaemons/fixtured.plist",
            "usr/libexec/fixtured": "usr/bin/fixtured-link",
            "usr/share/fixture/inst.copy": "usr/share/fixture/inst",
        ] {
            XCTAssertEqual(entries[mirror + path]?.kind, .hardLink, path)
            XCTAssertEqual(entries[mirror + path]?.linkTarget, mirror + target, path)
            XCTAssertEqual(entries[mirror + path]?.mode, 0o755, path)
        }
        XCTAssertEqual(try text(mirror + "Library/LaunchDaemons/fixtured.plist"), daemon)
        XCTAssertEqual(try text(mirror + "usr/bin/fixtured-link"), program)
    }

    func testWhatIsNotASimpleTweakIsRefused() throws {
        let library = try fixture("input/Fixture.dylib")
        var symbols = library // a fat dSYM whose first slice is armv7
        symbols.replaceSubrange(16384 ..< 16388, with: [0xCE, 0xFA, 0xED, 0xFE])
        symbols[98304 + 12] = 10
        var malformed = try fixture("input/FixtureBundle")
        malformed.replaceSubrange(20 ..< 24, with: [0xFF, 0xFF, 0xFF, 0x7F])
        var armv7 = library // the same file a program: code, but not 64-bit throughout
        armv7.replaceSubrange(16384 ..< 16388, with: [0xCE, 0xFA, 0xED, 0xFE])
        armv7[98304 + 12] = 2
        let ok = Data("x".utf8)
        let cases: [(String, [Entry], [String: Data])] = try [
            ("Library/Fixture.dylib", [.file("Library/Fixture.dylib", library)], [:]),
            ("var/jb", [.link("var/jb", to: "/")], [:]),
            ("var", [.link("var", to: "/private/var")], [:]),
            (tweak, [.file(tweak, symbols)], [:]),
            ("DEBIAN/postinst", [.file(tweak, library)], ["postinst": fixture("input/fixture-tool")]),
            // a daemon's list the patcher's sed would make otherwise: no
            // property list, two keys made one, keys out of order, and a
            // path in the base64 of some data
            ("var/jb/Library/LaunchDaemons/fixture.plist", [.file("var/jb/Library/LaunchDaemons/fixture.plist", Data("{".utf8))], [:]),
            ("var/jb/Library/LaunchDaemons/fixture.plist", [.file("var/jb/Library/LaunchDaemons/fixture.plist", Data("{ \"/var/jb/x\" = 1; \"/x\" = 2; }".utf8))], [:]),
            ("var/jb/Library/fixture.plist", [.file("var/jb/Library/fixture.plist", Data("{ \"/b\" = 1; \"/var/jb/a\" = 2; }".utf8))], [:]),
            // bytes whose base64 is `/var/jb/`
            ("var/jb/Library/libSandy/Fixture.plist", [.file("var/jb/Library/libSandy/Fixture.plist", Data("{ k = <fef6abfe36ff>; }".utf8))], [:]),
            ("var/jb/usr/lib/fixture.sh", [.file("var/jb/usr/lib/fixture.sh", ok, mode: 0o4755)], [:]),
            // a hard link to nothing, and one whose script-named name sed
            // would read before or after plutil wrote its other name
            ("var/jb/usr/lib/Fixture.dylib", [.hardLink("var/jb/usr/lib/Fixture.dylib", to: tweak)], [:]),
            ("var/jb/usr/share/inst", [.file("var/jb/usr/share/x.plist", Data("{}".utf8)), .hardLink("var/jb/usr/share/inst", to: "var/jb/usr/share/x.plist")], [:]),
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
            // tar fails on a hard link to a name it has not unpacked yet
            ("var/jb/usr/share/a", [.hardLink("var/jb/usr/share/a", to: "var/jb/usr/share/b"), .file("var/jb/usr/share/b", ok)], [:]),
            // `find -delete` cannot remove a `.DS_Store` with more in it
            ("var/jb/usr/share/.DS_Store/keep", [.file("var/jb/usr/share/.DS_Store/keep", ok)], [:]),
            // `read` drops the blank, and the patcher asks about a file that is not there
            ("var/jb/usr/lib/sp.dylib ", [.file("var/jb/usr/lib/sp.dylib ", library)], [:]),
            // two spellings of one name, which `String` takes for one
            ("var/jb/usr/share/e\u{301}", [.file("var/jb/usr/share/\u{E9}", ok), .file("var/jb/usr/share/e\u{301}", ok)], [:]),
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

        // four bytes of a thin magic are a Mach-O to `file`, and ldid fails on it
        for binary in [malformed, armv7, Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C])] {
            let directory = try prepared(entries: [.file(tweak, binary)])
            XCTAssertThrowsError(try RootlessToRoothide().adapt(preparedPackageAt: directory)) {
                XCTAssertEqual($0 as? AdaptationFailure, .malformedBinary(package: "com.example.fixture", path: tweak))
            }
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

    /// install_name_tool writes a file anew as root: root's, in its
    /// directory's group, the umask's bits gone from its mode; ldid alone
    /// keeps both, and `ln` makes the mark root's in the same group. A
    /// directory the archive leaves out is root's, in the group of the one
    /// tar made it in at that moment: the patcher's (mobile's) until tar has
    /// left a listed directory and set the owner the archive gives it (`lib`
    /// before `share`, `usr` only once `top.dylib` comes).
    func testOwnersThePatchersToolsLeave() throws {
        let library = try fixture("input/Fixture.dylib")
        // its one `/var/jb/` name spelled otherwise, so only ldid opens it
        var bundle = try fixture("input/FixtureBundle")
        try bundle.replaceSubrange(XCTUnwrap(bundle.range(of: Data("/var/jb/".utf8))), with: Data("/var/JB/".utf8))
        let directory = try prepared(entries: [
            .directory("var"), .directory("var/jb"), .directory("var/jb/usr", group: 20), .directory("var/jb/usr/lib", group: 20),
            .file("var/jb/usr/lib/owned.dylib", library, mode: 0o775, owner: (501, 501)),
            .file("var/jb/usr/lib/wide.dylib", library, mode: 0o777),
            .file("var/jb/usr/lib/ldid.bundle", bundle, mode: 0o775, owner: (501, 20)),
            .file("var/jb/usr/share/n/notes", Data("n".utf8)),
            .file("var/jb/usr/lib/sub/notes", Data("n".utf8)),
            .file("var/jb/top.dylib", library, mode: 0o755),
            .file("var/jb/usr/games/notes", Data("n".utf8)),
        ])
        _ = try RootlessToRoothide().adapt(preparedPackageAt: directory)
        let entries = try Dictionary(uniqueKeysWithValues: PreparedPackage.read(from: directory).entries.map { ($0.path, $0) })
        let expected: [String: [UInt32]] = [
            "usr/lib/owned.dylib": [0, 20, 0o755], "usr/lib/wide.dylib": [0, 20, 0o755],
            "usr/lib/ldid.bundle": [501, 20, 0o775], "top.dylib": [0, 501, 0o755],
            "usr/lib/owned.dylib.roothidepatch": [0, 20, 0o755], "top.dylib.roothidepatch": [0, 501, 0o755],
            "usr/share": [0, 501, 0o755], "usr/share/n": [0, 501, 0o755], "usr/lib/sub": [0, 20, 0o755],
            "usr/games": [0, 20, 0o755],
        ]
        for (path, owner) in expected {
            let entry = try XCTUnwrap(entries[path], path)
            XCTAssertEqual([entry.uid, entry.gid, entry.mode], owner, path)
        }
    }

    /// Paths are bytes to the patcher's tools: a combining mark after a `/`
    /// hides it neither from the walk `dpkg-deb` makes, nor from `find
    /// -path`, nor from the check for a mirror of the package's own.
    func testPathsAreBytes() throws {
        let library = try fixture("input/Fixture.dylib")
        let directory = try prepared(entries: [
            .file("var/jb/usr/share/c/x-z", Data("x".utf8)),
            .hardLink("var/jb/usr/share/c/x/\u{301}y", to: "var/jb/usr/share/c/x-z"),
            .file("var/jb/usr/share/c/Foo.lproj/\u{301}lib.dylib", library),
            .file("var/jb/usr/share/n/var/mobile/Library/pkgmirror/tool.dylib", library),
        ])
        _ = try RootlessToRoothide().adapt(preparedPackageAt: directory)
        let entries = try Dictionary(uniqueKeysWithValues: PreparedPackage.read(from: directory).entries.map { ($0.path, $0) })
        XCTAssertEqual(entries["usr/share/c/x/\u{301}y"]?.kind, .file)
        XCTAssertEqual(entries["usr/share/c/x-z"]?.kind, .hardLink)
        XCTAssertEqual(entries["usr/share/c/x-z"]?.linkTarget, "usr/share/c/x/\u{301}y")
        for path in ["usr/share/c/Foo.lproj/\u{301}lib.dylib", "usr/share/n/var/mobile/Library/pkgmirror/tool.dylib"] {
            XCTAssertNotNil(entries[path], path)
            XCTAssertNil(entries[path + ".roothidepatch"], path)
        }
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
        var kind: PreparedEntry.Kind
        /// nil shares the blob of the file before it, as an archive's hard
        /// link resolved to a copy would.
        var data: Data?
        var link: String?
        var mode: UInt32
        var owner: (uid: UInt32, gid: UInt32) = (0, 0)

        static func directory(_ path: String, mode: UInt32 = 0o755, group: UInt32 = 0) -> Entry {
            Entry(path: path, kind: .directory, mode: mode, owner: (0, group))
        }

        static func file(_ path: String, _ data: Data?, mode: UInt32 = 0o644, owner: (UInt32, UInt32) = (0, 0)) -> Entry {
            Entry(path: path, kind: .file, data: data, mode: mode, owner: owner)
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
                mode: entry.mode, uid: entry.owner.uid, gid: entry.owner.gid, modificationTime: 1_700_000_000
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
