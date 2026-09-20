import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

/// ElleKit replaces `Library/MobileSubstrate/DynamicLibraries` with an
/// absolute link to `usr/lib/TweakInject`, and every tweak ships that path
/// as a directory.
struct BootstrapLinkTests {
    private static func directory(_ path: String) -> PreparedEntry {
        PreparedEntry(path: path, kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0)
    }

    /// ElleKit's payload, under a rootless prefix when there is one.
    private static func loader(_ prefix: String) -> [PreparedEntry] {
        [
            directory(prefix + "Library/MobileSubstrate"),
            directory(prefix + "usr/lib/TweakInject"),
            PreparedEntry(
                path: prefix + "Library/MobileSubstrate/DynamicLibraries",
                kind: .symbolicLink,
                linkTarget: "/" + prefix + "usr/lib/TweakInject",
                mode: 0o777,
                uid: 0,
                gid: 0,
                modificationTime: 0
            ),
        ]
    }

    /// A tweak's payload, with the prefix's own directories as a rootless
    /// archive has them.
    private static func tweak(_ fixture: NativeInstallFixture, _ identity: String, prefix: String) throws
        -> InstallerJob.Transaction.Item
    {
        try fixture.package(
            identity,
            files: [prefix + "Library/MobileSubstrate/DynamicLibraries/\(identity).dylib": identity],
            links: (prefix.isEmpty ? [] : [directory("var"), directory("var/jb")]) + [
                directory(prefix + "Library/MobileSubstrate"),
                directory(prefix + "Library/MobileSubstrate/DynamicLibraries"),
            ]
        )
    }

    private func exists(_ fixture: NativeInstallFixture, _ path: String) -> Bool {
        var info = stat()
        return lstat(fixture.root.appendingPathComponent(path).path, &info) == 0
    }

    /// A script that turns a directory into a link out of the bootstrap,
    /// between the pass that resolved a path and the pass that writes it.
    /// `location` remembers the last directory it walked rather than walking
    /// it again for every file a package ships, and what it remembers cannot
    /// survive a maintainer script (`MaintainerScripts.forgetPaths`): the
    /// walk is what keeps a package's files inside the bootstrap, so a
    /// stale answer is a write wherever the link points.
    @Test func aScriptThatLinksADirectoryOutOfTheBootstrapIsSeenBeforeTheWrite() throws {
        // the harness runs a script against its own root, which no layout
        // rewrites: what is being proved is `location`, the same for all
        let fixture = try NativeInstallFixture()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("irisin-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let preinst = """
        #!/bin/sh
        mkdir -p "$DPKG_ROOT/Library/MobileSubstrate"
        ln -s "\(outside.path)" "$DPKG_ROOT/Library/MobileSubstrate/DynamicLibraries"
        """
        let package = try fixture.package(
            "tweak",
            files: ["Library/MobileSubstrate/DynamicLibraries/tweak.dylib": "tweak"],
            controls: ["preinst": preinst]
        )
        #expect(throws: (any Error).self) { try fixture.run(install: [package]) }
        var info = stat()
        #expect(lstat(outside.appendingPathComponent("tweak.dylib").path, &info) != 0)
    }

    /// roothide's vroot writes an absolute target as the kernel path it
    /// means, and so does the helper; the simulator keeps `/var/jb` in the
    /// link and resolves it to its mount.
    @Test(arguments: [false, true])
    func tweakAfterTheLoaderLandsInTweakInject(mounted: Bool) throws {
        let fixture = try NativeInstallFixture()
        let layout = mounted
            ? BootstrapLayout(kind: .rootless(prefix: BootstrapLayout.rootlessPrefix), mount: fixture.root.path)
            : BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        let prefix = mounted ? "var/jb/" : ""
        try fixture.run(install: [fixture.package("ellekit", links: Self.loader(prefix))], layout: layout)
        let link = fixture.root.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries").path
        let text = mounted ? "/var/jb/usr/lib/TweakInject" : fixture.root.path + "/usr/lib/TweakInject"
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == text)

        try fixture.run(install: [Self.tweak(fixture, "tweak", prefix: prefix)], layout: layout)
        #expect(try fixture.text("usr/lib/TweakInject/tweak.dylib") == "tweak")
        #expect(try fixture.status("tweak") == "install ok installed")

        try fixture.run(remove: ["tweak"], layout: layout)
        #expect(!exists(fixture, "usr/lib/TweakInject/tweak.dylib"))
        // the directory entry is ElleKit's link, and ElleKit still lists it
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == text)
        #expect(try fixture.status("ellekit") == "install ok installed")
    }

    /// dpkg's `tarobject`: a link whose path already leads to the directory
    /// it names is left alone, and another package listing the path needs
    /// no Replaces. The tweak unpacked first, then ElleKit's preinst moved
    /// its files and linked the directory, as it did on the iPad.
    @Test func loaderAfterTheTweakKeepsBothClaims() throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        try fixture.run(install: [Self.tweak(fixture, "tweak", prefix: "")], layout: layout)
        let libraries = fixture.root.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries")
        let injected = fixture.root.appendingPathComponent("usr/lib/TweakInject")
        try FileManager.default.createDirectory(at: injected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: libraries, to: injected)
        try FileManager.default.createSymbolicLink(atPath: libraries.path, withDestinationPath: injected.path)

        try fixture.run(install: [fixture.package("ellekit", links: Self.loader(""))], layout: layout)
        #expect(try fixture.status("ellekit") == "install ok installed")
        let lists = try ["tweak", "ellekit"].map { try fixture.text("Library/dpkg/info/\($0).list") }
        #expect(lists.allSatisfy { $0.contains("/Library/MobileSubstrate/DynamicLibraries\n") })
        #expect(try fixture.text("usr/lib/TweakInject/tweak.dylib") == "tweak")
    }

    /// dpkg's `pkg_remove_old_files`: an upgrade that moves a dylib from
    /// `DynamicLibraries` to `TweakInject` does not remove the old path,
    /// which is the new file through ElleKit's link.
    @Test func upgradeKeepsTheOldPathOfTheNewFile() throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        try fixture.run(install: [fixture.package("ellekit", links: Self.loader(""))], layout: layout)
        try fixture.run(install: [Self.tweak(fixture, "tweak", prefix: "")], layout: layout)
        let moved = try fixture.package("tweak", version: "2", files: ["usr/lib/TweakInject/tweak.dylib": "moved"])
        try fixture.run(install: [moved], layout: layout)
        #expect(try fixture.text("usr/lib/TweakInject/tweak.dylib") == "moved")
    }

    /// roothide bridges the untouched filesystem back in at `/rootfs`, and a
    /// package may name a directory there: its own PatchLoader ships
    /// `/rootfs/var`. That directory is the system's, so it is neither
    /// created nor removed, and the bridge itself is left alone.
    @Test func rootfsDirectoriesAreLeftToTheSystem() throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        let bridge = fixture.root.appendingPathComponent("rootfs")
        try FileManager.default.createSymbolicLink(atPath: bridge.path, withDestinationPath: "/")
        let loader = try fixture.package(
            "com.roothide.patchloader",
            files: ["usr/lib/roothidepatch.dylib": "patch"],
            links: [Self.directory("rootfs"), Self.directory("rootfs/var")]
        )
        try fixture.run(install: [loader], layout: layout)
        #expect(try fixture.text("usr/lib/roothidepatch.dylib") == "patch")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bridge.path) == "/")

        try fixture.run(remove: ["com.roothide.patchloader"], layout: layout)
        #expect(try fixture.status("com.roothide.patchloader") == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bridge.path) == "/")
    }

    /// A failed unpack puts back a file whose directory the upgrade had
    /// already removed, and the next transaction starts clean.
    @Test func rollbackRecreatesARemovedDirectory() throws {
        let fixture = try NativeInstallFixture()
        let gone = Self.directory("usr/share/gone")
        try fixture.run(install: [fixture.package("upgrading", files: ["usr/share/gone/file": "one"], links: [gone])])
        let failing = "#!/bin/sh\n[ \"$1\" != disappear ]\n"
        try fixture.run(install: [fixture.package("other", files: ["usr/share/taken": "other"], controls: ["postrm": failing])])
        // taking other's only file makes it disappear, and its postrm refuses
        let upgrade = try fixture.package("upgrading", version: "2", files: ["usr/share/taken": "two"], fields: ["replaces": "other"])
        #expect(throws: PackageStepFailure.self) { try fixture.run(install: [upgrade]) }
        #expect(try fixture.text("usr/share/gone/file") == "one")
        try fixture.run(install: [fixture.package("unrelated", files: ["usr/share/unrelated": "u"])])
        #expect(try fixture.status("unrelated") == "install ok installed")
    }

    /// A link to a different directory is replaced, as dpkg replaces it.
    @Test func linkToAnotherDirectoryIsReplaced() throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        let libraries = fixture.root.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries")
        let elsewhere = fixture.root.appendingPathComponent("usr/lib/Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libraries.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: libraries.path, withDestinationPath: elsewhere.path)
        try fixture.run(install: [fixture.package("ellekit", links: Self.loader(""))], layout: layout)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: libraries.path)
                == fixture.root.path + "/usr/lib/TweakInject"
        )
    }

    /// dpkg's `filesavespackage`: a directory only the other package lists
    /// keeps it from disappearing, while one a third package lists does not.
    @Test func ownDirectorySavesAPackage() throws {
        let fixture = try NativeInstallFixture()
        let shared = Self.directory("usr/share/shared")
        try fixture.run(install: [
            fixture.package("keeper", files: ["usr/share/shared/file": "k"], links: [shared, Self.directory("usr/share/own")]),
            // a file of its own keeps the witness when the leaver ships its directory
            fixture.package("witness", files: ["usr/share/other/witness": "w"], links: [Self.directory("usr/share/other")]),
        ])
        let taker = try fixture.package("taker", files: ["usr/share/shared/file": "t"], fields: ["replaces": "keeper"], links: [shared])
        try fixture.run(install: [taker])
        #expect(try fixture.status("keeper") == "install ok installed")

        // everything the leaver has is the successor's or the witness's
        try fixture.run(install: [
            fixture.package("leaver", files: ["usr/share/leaving": "l"], links: [Self.directory("usr/share/other")]),
        ])
        let successor = try fixture.package("successor", files: ["usr/share/leaving": "s"], fields: ["replaces": "leaver"])
        try fixture.run(install: [successor])
        #expect(try fixture.status("leaver") == nil)
    }

    /// roothide keeps the jbroot's `/var` in an app group container, linked
    /// from `private/var`; a package's preferences land there. Any other
    /// way out of the root is refused.
    @Test func roothideVarIsOutsideTheRoot() throws {
        let fixture = try NativeInstallFixture()
        let group = fixture.root.deletingLastPathComponent().appendingPathComponent("app group " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: group) }
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let manager = FileManager.default
        try manager.createDirectory(at: fixture.root.appendingPathComponent("private"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: fixture.root.appendingPathComponent("private/var").path, withDestinationPath: group.path)
        try manager.createSymbolicLink(atPath: fixture.root.appendingPathComponent("var").path, withDestinationPath: "private/var")
        let outside = group.deletingLastPathComponent()
        try manager.createSymbolicLink(atPath: fixture.root.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))

        let package = try fixture.package(files: ["var/mobile/Library/Preferences/example.plist": "prefs"])
        try fixture.run(install: [package], layout: layout)
        #expect(try String(contentsOf: group.appendingPathComponent("mobile/Library/Preferences/example.plist"), encoding: .utf8) == "prefs")

        let filesystem = try PackageFilesystem(root: fixture.root, layout: layout, database: fixture.database)
        #expect(throws: PackageFailure.self) { try filesystem.location("/escape/file") }
        let none = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        #expect(throws: PackageFailure.self) { try none.location("/var/file") }
    }

    @Test func roothideLinkTextIsTheKernelPath() {
        let layout = BootstrapLayout(kind: .roothide(jbroot: "/private/var/containers/Bundle/Application/.jbroot-0123"))
        #expect(layout.linkText("/usr/lib/TweakInject") == "/private/var/containers/Bundle/Application/.jbroot-0123/usr/lib/TweakInject")
        #expect(layout.linkText("/rootfs/etc/hosts") == "/etc/hosts")
        #expect(layout.linkText("/rootfs") == "/")
        #expect(layout.linkText("../lib/libz.dylib") == "../lib/libz.dylib")
        #expect(layout.linkedPath("/usr/lib") == "/usr/lib")
        let mounted = BootstrapLayout(kind: .rootless(prefix: "/var/jb"), mount: "/mount")
        #expect(mounted.linkText("/var/jb/usr/lib") == "/var/jb/usr/lib")
        #expect(mounted.linkedPath("/var/jb/usr/lib") == "/mount/usr/lib")
    }
}
