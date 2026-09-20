import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

struct PackageInstallerTests {
    @Test func installUpgradeAndRemovePreserveCompatibleDatabase() throws {
        let fixture = try NativeInstallFixture()
        let first = try fixture.package(files: ["usr/share/example": "one"])
        try fixture.run(install: [first])
        #expect(try fixture.text("usr/share/example") == "one")
        #expect(try fixture.status() == "install ok installed")
        let second = try fixture.package(version: "2", files: ["usr/share/new-example": "two"])
        try fixture.run(install: [second])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usr/share/example").path))
        #expect(try fixture.text("usr/share/new-example") == "two")
        try fixture.run(remove: [first.identity])
        // no postrm and no conffiles: dpkg purges outright, and the record goes
        #expect(try fixture.status() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usr/share/new-example").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.database.appendingPathComponent("info/example.package.list").path))
    }

    @Test func essentialPackageLeavesOnlyWhenTheTransactionAllowsIt() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package(fields: ["essential": "yes"])])
        #expect(throws: (any Error).self) { try fixture.run(remove: ["example.package"]) }
        #expect(try fixture.status() == "install ok installed")
        try fixture.run(remove: ["example.package"], allowSystemRemoval: true)
        #expect(try fixture.status() == nil)
    }

    @Test func scriptsReceiveArgumentsEnvironmentAndPathsWithSpaces() throws {
        let fixture = try NativeInstallFixture()
        let script = """
        #!/bin/sh
        set -eu
        test "$DPKG_MAINTSCRIPT_ARCH" = all
        test "$DPKG_MAINTSCRIPT_PACKAGE" = example.package
        test "$DPKG_ADMINDIR" = "$DPKG_ROOT/Library/dpkg"
        printf '%s:%s\\n' "$DPKG_MAINTSCRIPT_NAME" "$1" >> "$DPKG_ROOT/script log"
        """
        let package = try fixture.package(controls: ["preinst": script, "postinst": script, "prerm": script, "postrm": script])
        try fixture.run(install: [package])
        try fixture.run(remove: [package.identity])
        #expect(try fixture.text("script log") == "preinst:install\npostinst:configure\nprerm:remove\npostrm:remove\n")
    }

    @Test func failedPostinstLeavesHalfConfigured() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(files: ["usr/share/example": "installed"], controls: ["postinst": "#!/bin/sh\nexit 23\n"])
        #expect(throws: (any Error).self) { try fixture.run(install: [package]) }
        #expect(try fixture.status() == "install ok half-configured")
        #expect(try fixture.text("usr/share/example") == "installed")
    }

    /// A configured package that drops to a lower state keeps the version it
    /// was configured at: the postinst that runs next hears it.
    @Test func failedTriggerKeepsTheConfiguredVersion() throws {
        let fixture = try NativeInstallFixture()
        let postinst = """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$DPKG_ROOT/postinst log"
        [ "$1" != triggered ] || [ ! -e "$DPKG_ROOT/fail" ]
        """
        let interested = try fixture.package("watcher", controls: ["postinst": postinst, "triggers": "interest /usr/share/watched\n"])
        try fixture.run(install: [interested])
        try Data().write(to: fixture.root.appendingPathComponent("fail"))
        let activator = try fixture.package("activator", files: ["usr/share/watched/file": "x"])
        #expect(throws: (any Error).self) { try fixture.run(install: [activator]) }
        #expect(try fixture.status("watcher") == "install ok half-configured")
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("fail"))
        try fixture.run(install: [fixture.package("watcher", controls: ["postinst": postinst])])
        #expect(try fixture.status("watcher") == "install ok installed")
        #expect(try fixture.text("postinst log").hasSuffix("configure 1\n"))
    }

    @Test func failedPreinstLeavesExistingVersionUntouched() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package(files: ["usr/share/example": "old"])])
        let package = try fixture.package(version: "2", files: ["usr/share/example": "new"], controls: ["preinst": "#!/bin/sh\nexit 7\n"])
        #expect(throws: (any Error).self) { try fixture.run(install: [package]) }
        #expect(try fixture.status() == "install ok installed")
        #expect(try fixture.text("usr/share/example") == "old")
    }

    @Test func locallyModifiedConffileGetsVendorUpdateBesideIt() throws {
        let fixture = try NativeInstallFixture()
        let controls = ["conffiles": "/etc/example\n"]
        try fixture.run(install: [fixture.package(files: ["etc/example": "vendor one"], controls: controls)])
        try Data("local".utf8).write(to: fixture.root.appendingPathComponent("etc/example"))
        try fixture.run(install: [fixture.package(version: "2", files: ["etc/example": "vendor two"], controls: controls)])
        #expect(try fixture.text("etc/example") == "local")
        #expect(try fixture.text("etc/example.dpkg-dist") == "vendor two")
        try fixture.run(remove: ["example.package"])
        #expect(try fixture.text("etc/example") == "local")
    }

    @Test func locallyDeletedConffileStaysDeletedWhenVendorVersionIsUnchanged() throws {
        let fixture = try NativeInstallFixture()
        let controls = ["conffiles": "/etc/example\n"]
        try fixture.run(install: [fixture.package(files: ["etc/example": "vendor"], controls: controls)])
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("etc/example"))
        try fixture.run(install: [fixture.package(version: "2", files: ["etc/example": "vendor"], controls: controls)])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("etc/example").path))
    }

    @Test func ownershipCollisionRequiresReplaces() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package("first.package", files: ["usr/share/example": "first"])])
        let second = try fixture.package("second.package", files: ["usr/share/example": "second"])
        #expect(throws: (any Error).self) { try fixture.run(install: [second]) }
        #expect(try fixture.text("usr/share/example") == "first")
        let replacing = try fixture.package("second.package", files: ["usr/share/example": "second"], fields: ["replaces": "first.package"])
        try fixture.run(install: [replacing])
        #expect(try fixture.text("usr/share/example") == "second")
        // its only file taken over, the first package disappeared, as it does to dpkg
        #expect(try fixture.status("first.package") == nil)
    }

    /// A control file spelling its name in mixed case installs under the
    /// lowercase identity the app and the repository index use, and a
    /// dependency on that identity is satisfied in the same transaction.
    @Test func mixedCasePackageNameInstallsUnderTransactionIdentity() throws {
        let fixture = try NativeInstallFixture()
        let theme = try fixture.package("com.example.violawhite", spelledAs: "com.example.violaWhite", files: ["usr/share/theme": "white"])
        let dependent = try fixture.package("com.example.dependent", fields: ["depends": "com.example.violawhite"])
        try fixture.run(install: [theme, dependent])
        #expect(try fixture.text("usr/share/theme") == "white")
        #expect(try fixture.status("com.example.violawhite") == "install ok installed")
        #expect(try fixture.status("com.example.violaWhite") == nil)
        #expect(try fixture.text("Library/dpkg/status").contains("Package: com.example.violawhite\n"))
        try fixture.run(remove: ["com.example.dependent", "com.example.violawhite"])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usr/share/theme").path))
    }

    /// A status record some other tool wrote in mixed case is the lowercase
    /// package, as it is to dpkg: a mixed-case Depends finds it, and removing
    /// it by the lowercase identity retires that record instead of adding one.
    @Test func mixedCaseInstalledRecordIsTheLowercasePackage() throws {
        let fixture = try NativeInstallFixture()
        let foreign = "Package: com.example.violaWhite\nStatus: install ok installed\nVersion: 1\nArchitecture: all\n"
        try Data(foreign.utf8).write(to: fixture.database.appendingPathComponent("status"))
        let dependent = try fixture.package("com.example.dependent", fields: ["depends": "com.example.violaWhite (>= 1)"])
        try fixture.run(install: [dependent])
        #expect(try fixture.status("com.example.dependent") == "install ok installed")
        try fixture.run(remove: ["com.example.dependent", "com.example.violawhite"])
        // purged, having neither postrm nor conffiles: one record retired, none added
        #expect(try fixture.status("com.example.violawhite") == nil)
        let status = try fixture.text("Library/dpkg/status")
        #expect(!status.contains("Package: com.example.viola"))
    }

    @Test func invalidFinalDependenciesFailBeforeWritingFiles() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(files: ["usr/share/example": "invalid"], fields: ["depends": "missing.package"])
        #expect(throws: (any Error).self) { try fixture.run(install: [package]) }
        #expect(try fixture.status() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usr/share/example").path))
    }

    @Test func rootlessPayloadGoesIntoResolvedBootstrap() throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: .rootless(prefix: "/bootstrap"))
        let package = try fixture.package(files: ["bootstrap/usr/share/example": "rootless"])
        try fixture.run(install: [package], layout: layout)
        #expect(try fixture.text("usr/share/example") == "rootless")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("bootstrap").path))
    }

    /// The simulator's arrangement: packages and the database say `/var/jb`,
    /// an empty directory stands in for it, and the runner finds the
    /// database it creates through the layout alone.
    @Test func mountedRootlessPrefixLandsInTheMount() throws {
        let fixture = try NativeInstallFixture()
        try FileManager.default.removeItem(at: fixture.database.deletingLastPathComponent())
        let layout = BootstrapLayout(kind: .rootless(prefix: BootstrapLayout.rootlessPrefix), mount: fixture.root.path)
        #expect(layout.resolve("/var/jb/Library/dpkg") == fixture.database.path)
        #expect(layout.resolve("/var/jbx") == "/var/jbx")
        let package = try fixture.package(files: ["var/jb/usr/share/example": "mounted"])
        let runner = InstallerRunner(installRoot: fixture.root.path, layout: layout) { _ in }
        let transaction = InstallerJob.Transaction(install: [package], remove: [], statusDigest: PackageArchive.sha256(Data()))
        #expect(runner.run(.transaction(transaction)) == 0)
        #expect(try fixture.text("usr/share/example") == "mounted")
        #expect(try fixture.status() == "install ok installed")
        #expect(try fixture.text("Library/dpkg/info/example.package.list").contains("/var/jb/usr/share/example"))
    }

    @Test func roothidePayloadUsesJbroot() throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        try fixture.run(install: [fixture.package(files: ["usr/share/example": "roothide"])], layout: layout)
        #expect(try fixture.text("usr/share/example") == "roothide")
    }

    /// A conffile replaced by a link is written through the link as the
    /// kernel follows it on roothide: into the jbroot, and never into a
    /// file outside it, which fails the install instead.
    @Test func roothideConffileLinkIsFollowedAsTheKernelFollowsIt() throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        func package(_ version: String) throws -> InstallerJob.Transaction.Item {
            try fixture.package(version: version, files: ["etc/example": version], controls: ["conffiles": "/etc/example\n"])
        }
        try fixture.run(install: [package("1")], layout: layout)
        let example = fixture.root.appendingPathComponent("etc/example")
        let real = fixture.root.appendingPathComponent("etc/real")
        try FileManager.default.moveItem(at: example, to: real)
        try FileManager.default.createSymbolicLink(atPath: example.path, withDestinationPath: real.path)
        try fixture.run(install: [package("2")], layout: layout)
        #expect(try fixture.text("etc/real") == "2")

        let system = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("system".utf8).write(to: system)
        defer { try? FileManager.default.removeItem(at: system) }
        try FileManager.default.removeItem(at: example)
        try FileManager.default.createSymbolicLink(atPath: example.path, withDestinationPath: system.path)
        #expect(throws: (any Error).self) { try fixture.run(install: [package("3")], layout: layout) }
        #expect(try String(contentsOf: system, encoding: .utf8) == "system")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path + system.path))
    }

    /// A bootstrap that has not written a status file, an info directory or
    /// a triggers directory yet is empty, not broken: the first install
    /// creates all three.
    @Test func freshDatabaseDirectoryWorks() throws {
        let fixture = try NativeInstallFixture()
        try FileManager.default.removeItem(at: fixture.database)
        try FileManager.default.createDirectory(at: fixture.database, withIntermediateDirectories: true)
        let package = try fixture.package(files: ["usr/share/example": "first"], controls: ["postinst": "#!/bin/sh\nexit 0\n"])
        try fixture.run(install: [package])
        #expect(try fixture.status() == "install ok installed")
        #expect(try fixture.text("usr/share/example") == "first")
        #expect(FileManager.default.fileExists(atPath: fixture.database.appendingPathComponent("info/example.package.list").path))
        try fixture.run(remove: [package.identity])
        #expect(try fixture.status() == nil)
    }

    @Test func dryRunLeavesDatabaseAndPayloadUntouched() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(files: ["usr/share/example": "unused"])
        try fixture.run(install: [package], dryRun: true)
        #expect(try fixture.text("Library/dpkg/status").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usr/share/example").path))
    }

    // MARK: - extended_states

    @Test func dependencyIsMarkedWithItsRecordedArchitecture() throws {
        let fixture = try NativeInstallFixture()
        let dependency = try fixture.package("example.dependency", fields: ["architecture": "iphoneos-arm64"])
        try fixture.run(install: [dependency, fixture.package()], autoInstalled: [dependency.identity])
        #expect(fixture.markings() == "Package: example.dependency\nArchitecture: iphoneos-arm64\nAuto-Installed: 1\n")
    }

    @Test func nothingAutomaticWritesNothing() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package()])
        #expect(fixture.markings() == nil)
    }

    @Test func removalAndManualInstallDropTheMarkAndKeepOtherParagraphs() throws {
        let fixture = try NativeInstallFixture()
        let others = "Package: other.package\nArchitecture: iphoneos-arm64\nAuto-Installed: 1\n\nnot a field\n"
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("var/lib/apt"), withIntermediateDirectories: true)
        try Data(others.utf8).write(to: fixture.root.appendingPathComponent("var/lib/apt/extended_states"))
        let marked = others + "\nPackage: example.package\nArchitecture: all\nAuto-Installed: 1\n"
        try fixture.run(install: [fixture.package()], autoInstalled: ["example.package"])
        #expect(fixture.markings() == marked)
        try fixture.run(remove: ["example.package"])
        #expect(fixture.markings() == others)
        try fixture.run(install: [fixture.package()], autoInstalled: ["example.package"])
        #expect(fixture.markings() == marked)
        try fixture.run(install: [fixture.package(version: "2")])
        #expect(fixture.markings() == others)
    }

    @Test func dryRunWritesNoMarks() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package()], autoInstalled: ["example.package"], dryRun: true)
        #expect(fixture.markings() == nil)
    }

    /// A package that names `/var` — every rootless tweak an adapter
    /// rewrites does, for the mirror under it — is removed without
    /// unlinking the jbroot's own `var`, a link to the container that holds
    /// the bootstrap's state. The path stays in the package's list, the way
    /// dpkg keeps a directory it could not remove.
    @Test func removingAPackageThatNamedVarKeepsTheJbrootsVarLink() throws {
        let fixture = try NativeInstallFixture()
        let manager = FileManager.default
        let group = fixture.root.deletingLastPathComponent().appendingPathComponent("app group " + UUID().uuidString)
        defer { try? manager.removeItem(at: group) }
        try manager.createDirectory(at: group, withIntermediateDirectories: true)
        try manager.createDirectory(at: fixture.root.appendingPathComponent("private"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            atPath: fixture.root.appendingPathComponent("private/var").path,
            withDestinationPath: group.path
        )
        try manager.createSymbolicLink(
            atPath: fixture.root.appendingPathComponent("var").path,
            withDestinationPath: "private/var"
        )
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        let package = try fixture.package(
            files: ["var/mobile/Library/pkgmirror/example": "the original library"],
            links: [PreparedEntry(path: "var", kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0)]
        )

        try fixture.run(install: [package], layout: layout)
        #expect(try String(contentsOf: group.appendingPathComponent("mobile/Library/pkgmirror/example"), encoding: .utf8) == "the original library")
        try fixture.run(remove: [package.identity], layout: layout)

        var info = stat()
        #expect(lstat(fixture.root.appendingPathComponent("var").path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFLNK)
        #expect(!manager.fileExists(atPath: group.appendingPathComponent("mobile/Library/pkgmirror/example").path))
        #expect(manager.fileExists(atPath: group.path))
    }

    @Test func failedTransactionStillMarksWhatItInstalled() throws {
        let fixture = try NativeInstallFixture()
        let dependency = try fixture.package("example.dependency")
        let failing = try fixture.package(controls: ["postinst": "#!/bin/sh\nexit 23\n"])
        #expect(throws: (any Error).self) {
            try fixture.run(install: [dependency, failing], autoInstalled: [dependency.identity])
        }
        #expect(try fixture.status(dependency.identity) == "install ok installed")
        #expect(fixture.markings() == "Package: example.dependency\nArchitecture: all\nAuto-Installed: 1\n")
    }
}
