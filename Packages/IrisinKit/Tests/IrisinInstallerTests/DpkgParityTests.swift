import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

/// What a real dpkg sharing the database would write, read or refuse:
/// each test names the dpkg function it mirrors.
struct DpkgParityTests {
    private let log = """
    #!/bin/sh
    printf '%s:%s\\n' "$DPKG_MAINTSCRIPT_NAME" "$*" >> "$DPKG_ROOT/script log"
    """

    /// dpkg's `varbufrecord`: a value's lines are continued with a space,
    /// and `\r\n` ends one, which `String` would take for a character.
    @Test func paragraphLinesEndAtEveryNewline() {
        #expect(PackageDatabase.paragraph(["package": "x", "description": "a\r\nStatus: b"]) == "Package: x\nDescription: a\r\n Status: b\n")
    }

    /// dpkg keeps a field it does not know as the stanza spelled it and
    /// where it stood among the others: what a vphone's dpkg 1.22.6 wrote
    /// for a tweak's control file, read back and written again.
    @Test func arbitraryFieldsKeepTheirSpellingAndOrder() throws {
        let stanza = """
        Package: example.package
        Status: install ok installed
        Section: Tweaks
        Maintainer: someone
        Architecture: iphoneos-arm64
        Version: 1.0.4
        Description: A tweak
        Name: Example
        Author: someone
        Icon: https://example.com/icon.png
        SileoDepiction: https://example.com/depiction.json

        """
        let fixture = try NativeInstallFixture()
        try Data(stanza.utf8).write(to: fixture.database.appendingPathComponent("status"))
        let database = try PackageDatabase(directory: fixture.database)
        try database.consolidate()
        #expect(try fixture.text("Library/dpkg/status") == stanza)
        // a field nothing spelled follows them, capitalised by word
        #expect(PackageDatabase.paragraph(["package": "x", "tag": "a", "sileodepiction": "b"], names: ["SileoDepiction"]) == "Package: x\nSileoDepiction: b\nTag: a\n")
    }

    // MARK: process_archive

    /// dpkg's list starts at the root, `/.`, and `write_filehash_except`
    /// writes the md5sums of a package that ships none: every regular file
    /// in the archive's order, conffiles left out, no leading slash.
    @Test func unpackWritesTheRootEntryAndTheHashesDpkgWould() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(
            files: ["usr/share/example": "one", "etc/example": "conf"],
            controls: ["conffiles": "/etc/example\n"]
        )
        try fixture.run(install: [package])
        #expect(try fixture.text("Library/dpkg/info/example.package.list").hasPrefix("/.\n"))
        #expect(try fixture.text("Library/dpkg/info/example.package.md5sums") == "f97c5d29941bfb1b2fdab0874906ab82  usr/share/example\n")
        // one the package ships is installed as it is
        let shipped = try fixture.package("shipper.package", files: ["usr/share/shipped": "x"], controls: ["md5sums": "its own\n"])
        try fixture.run(install: [shipped])
        #expect(try fixture.text("Library/dpkg/info/shipper.package.md5sums") == "its own\n")
    }

    /// dpkg's `tarobject` treats an archive directory that already exists as
    /// shared and returns before changing its metadata. Its own package ships
    /// the administrative directory and creates any missing subdirectories.
    @Test func packageMayShipDatabaseDirectories() throws {
        let fixture = try NativeInstallFixture()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o751],
            ofItemAtPath: fixture.database.path
        )
        let entries = [
            PreparedEntry(path: "Library/dpkg", kind: .directory, mode: 0o700, uid: 0, gid: 0, modificationTime: 0),
            PreparedEntry(path: "Library/dpkg/info", kind: .directory, mode: 0o700, uid: 0, gid: 0, modificationTime: 0),
            PreparedEntry(path: "Library/dpkg/parts", kind: .directory, mode: 0o700, uid: 0, gid: 0, modificationTime: 0),
        ]

        try fixture.run(install: [fixture.package("dpkg", files: ["usr/bin/dpkg": "binary"], links: entries)])

        let databaseAttributes = try FileManager.default.attributesOfItem(atPath: fixture.database.path)
        let partsAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.database.appendingPathComponent("parts").path
        )
        #expect(databaseAttributes[.posixPermissions] as? Int == 0o751)
        #expect(partsAttributes[.posixPermissions] as? Int == 0o700)
        #expect(try fixture.status("dpkg") == "install ok installed")
    }

    /// dpkg's package list includes its administrative directories. Removing
    /// the package removes its tools, but the database holding that removal
    /// must remain available for the next transaction.
    @Test func removingPackageLeavesDatabaseDirectories() throws {
        let fixture = try NativeInstallFixture()
        let entries = [
            PreparedEntry(path: "Library/dpkg", kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0),
            PreparedEntry(path: "Library/dpkg/info", kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0),
            PreparedEntry(path: "Library/dpkg/parts", kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0),
        ]
        try fixture.run(install: [fixture.package("dpkg", files: ["usr/bin/dpkg": "binary"], links: entries)])

        try fixture.run(remove: ["dpkg"], allowSystemRemoval: true)

        #expect(try fixture.status("dpkg") == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.database.path))
        #expect(FileManager.default.fileExists(atPath: fixture.database.appendingPathComponent("info").path))
        #expect(FileManager.default.fileExists(atPath: fixture.database.appendingPathComponent("parts").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usr/bin/dpkg").path))
    }

    @Test func packageMayNotShipDatabaseFiles() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package("hostile", files: ["Library/dpkg/status": "replacement"])

        #expect(throws: PackageStepFailure.self) {
            try fixture.run(install: [package])
        }
        #expect(try fixture.status("hostile") == nil)
    }

    @Test(arguments: [PreparedEntry.Kind.symbolicLink, .hardLink])
    func packageMayNotShipDatabaseLinks(_ kind: PreparedEntry.Kind) throws {
        let fixture = try NativeInstallFixture()
        let entry = PreparedEntry(
            path: "Library/dpkg/redirect",
            kind: kind,
            linkTarget: "status",
            mode: 0o777,
            uid: 0,
            gid: 0,
            modificationTime: 0
        )
        let package = try fixture.package("hostile", links: [entry])

        #expect(throws: PackageStepFailure.self) {
            try fixture.run(install: [package])
        }
        #expect(try fixture.status("hostile") == nil)
    }

    private func seed(_ fixture: NativeInstallFixture, _ paragraphs: [[String: String]]) throws {
        let text = paragraphs.map { PackageDatabase.paragraph($0) }.joined(separator: "\n")
        try Data(text.utf8).write(to: fixture.database.appendingPathComponent("status"))
    }

    // MARK: removal_bulk

    @Test func removalKeepsConfigFilesWithPostrmThenPurges() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(
            files: ["usr/share/example": "one", "etc/example": "conf"],
            controls: ["postrm": log, "conffiles": "/etc/example\n", "triggers": "interest /usr/share/things\n"]
        )
        try fixture.run(install: [package])
        try fixture.run(remove: [package.identity])
        let record = try #require(PackageDatabase(directory: fixture.database).records[package.identity])
        #expect(record["status"] == "deinstall ok config-files")
        // the version the postinst last configured survives for the next install
        #expect(record["config-version"] == "1")
        #expect(record["triggers-pending"] == nil)
        // dpkg keeps the list and the postrm for the purge and nothing else
        #expect(try Set(PackageDatabase(directory: fixture.database).infoMembers(package.identity)) == ["list", "postrm"])
        #expect(try fixture.text("Library/dpkg/info/example.package.list") == "/.\n/etc/example\n")
        #expect(try fixture.text("etc/example") == "conf")
        #expect(try fixture.text("script log") == "postrm:remove\n")
        try fixture.run(remove: [package.identity])
        #expect(try fixture.status() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("etc/example").path))
        #expect(try fixture.text("script log") == "postrm:remove\npostrm:purge\n")
        #expect(try PackageDatabase(directory: fixture.database).infoMembers(package.identity).isEmpty)
    }

    @Test func removalNeverWritesReinstreq() throws {
        let fixture = try NativeInstallFixture()
        let prerm = "#!/bin/sh\ngrep -q reinstreq \"$DPKG_ADMINDIR/status\" && exit 9\nexit 0\n"
        let postrm = "#!/bin/sh\ngrep -q reinstreq \"$DPKG_ADMINDIR/status\" && exit 9\nexit 0\n"
        let package = try fixture.package(files: ["usr/share/example": "one"], controls: ["prerm": prerm, "postrm": postrm])
        try fixture.run(install: [package])
        try fixture.run(remove: [package.identity])
        #expect(try fixture.status() == "deinstall ok config-files")
    }

    /// A removal whose postrm fails still records the configured version,
    /// so the next install tells its postinst what was there.
    @Test func failedRemovalKeepsTheConfiguredVersion() throws {
        let fixture = try NativeInstallFixture()
        let postrm = "#!/bin/sh\n[ \"$1\" != remove ]\n"
        try fixture.run(install: [fixture.package(files: ["usr/share/example": "one"], controls: ["postrm": postrm])])
        #expect(throws: PackageStepFailure.self) { try fixture.run(remove: ["example.package"]) }
        let record = try PackageDatabase(directory: fixture.database).records["example.package"]
        #expect(record?["status"] == "deinstall ok half-installed")
        #expect(record?["config-version"] == "1")
    }

    // MARK: modstatdb_note / trig_record_activation

    @Test func fileTriggerNeverLeavesPendingOnAnUnconfiguredRecord() throws {
        let fixture = try NativeInstallFixture()
        let watcher = try fixture.package(
            "watcher.package",
            controls: ["postinst": log, "triggers": "interest /usr/share/things\n"]
        )
        try fixture.run(install: [watcher])
        // the status file dpkg would read at any point: never a Triggers-Pending on
        // a package whose state is not triggers-pending or triggers-awaited
        let checker = """
        #!/bin/sh
        awk 'BEGIN{RS=""} /Triggers-Pending/ && !/triggers-(pending|awaited)/ {exit 1}' "$DPKG_ADMINDIR/status" || exit 7
        """
        let shipper = try fixture.package(
            "shipper.package",
            files: ["usr/share/things/one": "x"],
            controls: ["preinst": checker, "postinst": checker, "triggers": "interest /usr/share/things\n"]
        )
        try fixture.run(install: [shipper])
        #expect(try fixture.status("watcher.package") == "install ok installed")
        #expect(try fixture.status("shipper.package") == "install ok installed")
        // one postinst triggered call, the trigger names in one argument
        #expect(try fixture.text("script log") == "postinst:configure \npostinst:triggered /usr/share/things\n")
        let status = try fixture.text("Library/dpkg/status")
        #expect(!status.contains("Triggers-"))
    }

    @Test func triggeredArgumentJoinsEveryTriggerName() throws {
        let fixture = try NativeInstallFixture()
        let watcher = try fixture.package(
            "watcher.package",
            controls: ["postinst": log, "triggers": "interest /usr/share/a\ninterest /usr/share/b\n"]
        )
        try fixture.run(install: [watcher])
        let shipper = try fixture.package("shipper.package", files: ["usr/share/a/one": "x", "usr/share/b/two": "y"])
        try fixture.run(install: [shipper])
        #expect(try fixture.text("script log") == "postinst:configure \npostinst:triggered /usr/share/a /usr/share/b\n")
    }

    @Test func failingTriggeredPostinstLeavesAPackageToConfigureNotATriggerToRerun() throws {
        let fixture = try NativeInstallFixture()
        let postinst = "#!/bin/sh\ntest \"$1\" = triggered && exit 4\nexit 0\n"
        let watcher = try fixture.package("watcher.package", controls: ["postinst": postinst, "triggers": "interest /usr/share/things\n"])
        try fixture.run(install: [watcher])
        let shipper = try fixture.package("shipper.package", files: ["usr/share/things/one": "x"])
        #expect(throws: (any Error).self) { try fixture.run(install: [shipper]) }
        let record = try PackageDatabase(directory: fixture.database).records["watcher.package"]
        #expect(record?["status"] == "install ok half-configured")
        #expect(record?["triggers-pending"] == nil)
        // the next transaction is not held hostage by the broken postinst
        try fixture.run(install: [fixture.package("unrelated.package")])
        #expect(try fixture.status("unrelated.package") == "install ok installed")
    }

    @Test func configuredVersionOnlyGatesPreDepends() throws {
        let fixture = try NativeInstallFixture()
        try seed(fixture, [["package": "owner", "version": "2", "architecture": "all", "status": "install ok unpacked", "config-version": "1"]])
        // a second file keeps the owner from disappearing when the first is taken
        try Data("/usr/share/shared\n/usr/share/kept\n".utf8).write(to: fixture.database.appendingPathComponent("info/owner.list"))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("usr/share"), withIntermediateDirectories: true)
        try Data("k".utf8).write(to: fixture.root.appendingPathComponent("usr/share/kept"))
        // Replaces judges the unpacked version alone, as dpkg's does_replace does
        let taker = try fixture.package("taker", files: ["usr/share/shared": "t"], fields: ["replaces": "owner (>= 2)"])
        try fixture.run(install: [taker])
        #expect(try fixture.text("usr/share/shared") == "t")
        let hostile = try fixture.package("hostile", fields: ["conflicts": "owner (>= 2)"])
        #expect(throws: (any Error).self) { try fixture.run(install: [hostile]) }
    }

    @Test func awaitedTriggersSurviveAnUpgrade() throws {
        let fixture = try NativeInstallFixture()
        try seed(fixture, [
            ["package": "pend.package", "version": "1", "architecture": "all", "status": "install ok triggers-pending", "triggers-pending": "some-trigger"],
            ["package": "waiter", "version": "1", "architecture": "all", "status": "install ok triggers-awaited", "triggers-awaited": "pend.package"],
        ])
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixture.database.appendingPathComponent("info/pend.package.postinst"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.database.appendingPathComponent("info/pend.package.postinst").path)
        try fixture.run(install: [fixture.package("waiter", version: "2")])
        // processing pend.package's trigger at the end released the waiter
        let records = try PackageDatabase(directory: fixture.database).records
        #expect(records["waiter"]?["status"] == "install ok installed")
        #expect(records["pend.package"]?["status"] == "install ok installed")
    }

    @Test func explicitTriggerInterestFileListsOnePackagePerLine() throws {
        let fixture = try NativeInstallFixture()
        let one = try fixture.package("one.package", controls: ["triggers": "interest my-trigger\n"])
        let two = try fixture.package("two.package", controls: ["triggers": "interest-noawait my-trigger\n"])
        try fixture.run(install: [one, two])
        #expect(try fixture.text("Library/dpkg/triggers/my-trigger") == "one.package\ntwo.package/noawait\n")
    }

    @Test func configureDropsPendingTriggersAndClearsAwaiters() throws {
        let fixture = try NativeInstallFixture()
        // a stale record another tool left: b awaits a, which pends a trigger
        try seed(fixture, [
            ["package": "pkg-a", "version": "1", "architecture": "all", "status": "install ok triggers-pending", "triggers-pending": "some-trigger"],
            ["package": "pkg-b", "version": "1", "architecture": "all", "status": "install ok triggers-awaited", "triggers-awaited": "pkg-a"],
        ])
        try fixture.run(install: [fixture.package("pkg-a", version: "2", controls: ["postinst": log])])
        let records = try PackageDatabase(directory: fixture.database).records
        #expect(records["pkg-a"]?["status"] == "install ok installed")
        #expect(records["pkg-a"]?["triggers-pending"] == nil)
        #expect(records["pkg-b"]?["status"] == "install ok installed")
        #expect(records["pkg-b"]?["triggers-awaited"] == nil)
        // a configure takes the pending triggers with it: no postinst triggered
        #expect(try fixture.text("script log") == "postinst:configure 1\n")
    }

    // MARK: Config-Version

    @Test func unpackedWitnessNeedsItsConfiguredVersionToSatisfyPreDepends() throws {
        let fixture = try NativeInstallFixture()
        try seed(fixture, [["package": "base", "version": "2", "architecture": "all", "status": "install ok unpacked", "config-version": "1"]])
        let strict = try fixture.package("strict", fields: ["pre-depends": "base (>= 2)"])
        #expect(throws: (any Error).self) { try fixture.run(install: [strict]) }
        let lenient = try fixture.package("lenient", fields: ["pre-depends": "base (>= 1)"])
        try fixture.run(install: [lenient])
        #expect(try fixture.status("lenient") == "install ok installed")
    }

    @Test func reinstallOverConfigFilesTellsPostinstThePreviousVersion() throws {
        let fixture = try NativeInstallFixture()
        let first = try fixture.package(controls: ["postinst": log, "postrm": log])
        try fixture.run(install: [first])
        try fixture.run(remove: [first.identity])
        let second = try fixture.package(version: "2", controls: ["postinst": log, "postrm": log])
        try fixture.run(install: [second])
        #expect(try fixture.text("script log") == "postinst:configure \npostrm:remove\npostinst:configure 1\n")
    }

    // MARK: cleanup handlers

    @Test func failedUnpackAfterPreinstRunsTheAbortScripts() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package("owner.package", files: ["usr/share/taken": "theirs"])])
        // the conflict is found after the preinst, as it is by dpkg's tar pass
        let fresh = try fixture.package("fresh.package", files: ["usr/share/taken": "mine"], controls: ["preinst": log, "postrm": log])
        #expect(throws: (any Error).self) { try fixture.run(install: [fresh]) }
        #expect(try fixture.text("script log") == "preinst:install\npostrm:abort-install\n")
        #expect(try fixture.status("fresh.package") == nil)
        try Data().write(to: fixture.root.appendingPathComponent("script log"))
        let old = try fixture.package("upgrading.package", controls: ["prerm": log, "postinst": log])
        try fixture.run(install: [old])
        let new = try fixture.package("upgrading.package", version: "2", files: ["usr/share/taken": "mine"], controls: ["preinst": log, "postrm": log])
        #expect(throws: (any Error).self) { try fixture.run(install: [new]) }
        #expect(try fixture.text("script log") == "postinst:configure \nprerm:upgrade 2\npreinst:upgrade 1 2\npostrm:abort-upgrade 1 2\npostinst:abort-upgrade 2\n")
        #expect(try fixture.status("upgrading.package") == "install ok installed")
    }

    @Test func abortInstallOverConfigFilesCarriesBothVersions() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package(controls: ["postrm": log])])
        try fixture.run(remove: ["example.package"])
        let failing = try fixture.package(version: "2", controls: ["preinst": "#!/bin/sh\nexit 3\n", "postrm": log])
        #expect(throws: (any Error).self) { try fixture.run(install: [failing]) }
        #expect(try fixture.text("script log") == "postrm:remove\npostrm:abort-install 1 2\n")
        #expect(try fixture.status() == "install ok config-files")
    }

    @Test func prermUpgradeOnlyRunsForAConfiguredOldVersion() throws {
        let fixture = try NativeInstallFixture()
        try seed(fixture, [["package": "example.package", "version": "1", "architecture": "all", "status": "install ok unpacked"]])
        for member in ["prerm", "postrm"] {
            let script = fixture.database.appendingPathComponent("info/example.package." + member)
            try Data(log.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        try fixture.run(install: [fixture.package(version: "2")])
        // no prerm upgrade; the old postrm still hears upgrade
        #expect(try fixture.text("script log") == "postrm:upgrade 2\n")
    }

    @Test func oldPostrmUpgradeRunsBeforeOldFilesGo() throws {
        let fixture = try NativeInstallFixture()
        let postrm = "#!/bin/sh\ntest -e \"$DPKG_ROOT/usr/share/old\" && echo present >> \"$DPKG_ROOT/script log\"\nexit 0\n"
        try fixture.run(install: [fixture.package(files: ["usr/share/old": "x"], controls: ["postrm": postrm])])
        try fixture.run(install: [fixture.package(version: "2", files: ["usr/share/new": "y"])])
        #expect(try fixture.text("script log") == "present\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usr/share/old").path))
    }

    // MARK: tarobject

    @Test func configFilesOwnerGivesUpItsPathWithoutReplaces() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package("old.package", files: ["etc/shared": "old"], controls: ["conffiles": "/etc/shared\n", "postrm": log])])
        try fixture.run(remove: ["old.package"])
        #expect(try fixture.status("old.package") == "deinstall ok config-files")
        try fixture.run(install: [fixture.package("new.package", files: ["etc/shared": "new"])])
        #expect(try fixture.text("etc/shared") == "new")
        #expect(try fixture.text("Library/dpkg/info/old.package.list") == "/.\n")
    }

    @Test func packageWhoseFilesAreAllTakenOverDisappears() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package("old.package", files: ["usr/share/only": "old"], controls: ["postrm": log])])
        let replacing = try fixture.package("new.package", files: ["usr/share/only": "new"], fields: ["replaces": "old.package"])
        try fixture.run(install: [replacing])
        #expect(try fixture.status("old.package") == nil)
        #expect(try fixture.text("script log") == "postrm:disappear new.package 1\n")
        #expect(try PackageDatabase(directory: fixture.database).infoMembers("old.package").isEmpty)
    }

    private func divertTool(_ fixture: NativeInstallFixture) throws {
        try Data("/usr/bin/tool\n/usr/bin/tool.distrib\ndiverter\n".utf8)
            .write(to: fixture.database.appendingPathComponent("diversions"))
    }

    /// `filesavespackage`: a path the diverter diverted is not the same file
    /// in both packages, so the diverter keeps it and does not disappear.
    @Test func divertedPathSavesTheDiverter() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package("diverter", files: ["usr/bin/tool": "diverter"], controls: ["postrm": log])])
        try divertTool(fixture)
        try fixture.run(install: [fixture.package("tool", files: ["usr/bin/tool": "tool"])])
        #expect(try fixture.status("diverter") == "install ok installed")
        #expect(try fixture.text("usr/bin/tool.distrib") == "tool")
        #expect(try fixture.text("Library/dpkg/info/diverter.list").contains("/usr/bin/tool\n"))
    }

    /// `pkg_remove_files_from_others`: the diverter takes nothing from the
    /// list of the package whose file it diverted, which stays installed.
    @Test func diverterLeavesTheDivertedPathToItsOwner() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package("tool", files: ["usr/bin/tool": "tool"], controls: ["postrm": log])])
        try divertTool(fixture)
        try FileManager.default.moveItem(
            at: fixture.root.appendingPathComponent("usr/bin/tool"),
            to: fixture.root.appendingPathComponent("usr/bin/tool.distrib")
        )
        try fixture.run(install: [fixture.package("diverter", files: ["usr/bin/tool": "diverter"])])
        #expect(try fixture.status("tool") == "install ok installed")
        #expect(try fixture.text("Library/dpkg/info/tool.list").contains("/usr/bin/tool\n"))
    }

    @Test func directoryEntryAcceptsASymbolicLinkToADirectory() throws {
        let fixture = try NativeInstallFixture()
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("usr").path, withDestinationPath: "real")
        let directory = PreparedEntry(path: "usr", kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0)
        try fixture.run(install: [fixture.package(files: ["usr/example": "x"], links: [directory])])
        #expect(try fixture.text("real/example") == "x")
    }

    // MARK: pkg_infodb_update

    @Test func anyControlMemberBecomesAnInfoFile() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(controls: ["extrainst_": "#!/bin/sh\n", "postrm": log])
        try fixture.run(install: [package])
        #expect(FileManager.default.fileExists(atPath: fixture.database.appendingPathComponent("info/example.package.extrainst_").path))
        try fixture.run(install: [fixture.package(version: "2", controls: ["postrm": log])])
        #expect(!FileManager.default.fileExists(atPath: fixture.database.appendingPathComponent("info/example.package.extrainst_").path))
    }

    @Test func scriptWithoutInterpreterLineRunsUnderSh() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(controls: ["postinst": "echo ran >> \"$DPKG_ROOT/script log\"\n"])
        try fixture.run(install: [package])
        #expect(try fixture.text("script log") == "ran\n")
    }

    // MARK: dump.c

    @Test func statusRecordIsWrittenInDpkgOrderWithoutArchiveFields() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(fields: ["filename": "pool/x.deb", "size": "12", "md5sum": "abc", "sha256": "def", "depends": "nothing | example.package"])
        try fixture.run(install: [package])
        let status = try fixture.text("Library/dpkg/status")
        #expect(status.hasPrefix("Package: example.package\nStatus: install ok installed\nArchitecture: all\nVersion: 1\nDepends: "))
        #expect(!status.contains("Filename"))
        #expect(!status.contains("Md5sum"))
        #expect(!status.contains("Size:"))
        // an arbitrary field dpkg does not know follows the ones it does
        #expect(status.hasSuffix("Description: Synthetic test package\nSha256: def\n"))
    }

    @Test func conffilesFieldRoundTripsBothFlags() throws {
        let parsed = try Conffiles(status: "/etc/a 0123 obsolete remove-on-upgrade\n/etc/b 4567 remove-on-upgrade\n/etc/c 89ab")
        #expect(parsed.obsolete == ["/etc/a"])
        #expect(parsed.removeOnUpgrade == ["/etc/a", "/etc/b"])
        #expect(parsed.status == "/etc/a 0123 obsolete remove-on-upgrade\n/etc/b 4567 remove-on-upgrade\n/etc/c 89ab")
    }

    @Test func removeOnUpgradeConffileGoesOrIsKeptAsDpkgOld() throws {
        let fixture = try NativeInstallFixture()
        let files = ["etc/keep": "k", "etc/drop": "d"]
        try fixture.run(install: [fixture.package(files: files, controls: ["conffiles": "/etc/keep\n/etc/drop\n"])])
        try fixture.run(install: [fixture.package(version: "2", files: ["etc/keep": "k"], controls: ["conffiles": "/etc/keep\nremove-on-upgrade /etc/drop\n"])])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("etc/drop").path))
        let record = try PackageDatabase(directory: fixture.database).records["example.package"]
        #expect(record?["conffiles"]?.contains("/etc/drop") == true)
        #expect(record?["conffiles"]?.contains("remove-on-upgrade") == true)
        // in the field, as dpkg keeps it, but not in the list of files it has
        #expect(try fixture.text("Library/dpkg/info/example.package.list") == "/.\n/etc/keep\n")
        try Data("local".utf8).write(to: fixture.root.appendingPathComponent("etc/drop"))
        try fixture.run(install: [fixture.package(version: "3", files: ["etc/keep": "k"], controls: ["conffiles": "/etc/keep\nremove-on-upgrade /etc/drop\n"])])
        #expect(try fixture.text("etc/drop.dpkg-old") == "local")
    }

    @Test func pathNoLongerAConffileLeavesTheField() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package(files: ["etc/example": "one"], controls: ["conffiles": "/etc/example\n"])])
        try fixture.run(install: [fixture.package(version: "2", files: ["etc/example": "two"])])
        #expect(try PackageDatabase(directory: fixture.database).records["example.package"]?["conffiles"] == nil)
        #expect(try fixture.text("etc/example") == "two")
    }

    @Test func conffileBehindAnAdministratorsSymlinkIsWrittenThrough() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package(files: ["etc/example": "one"], controls: ["conffiles": "/etc/example\n"])])
        let real = fixture.root.appendingPathComponent("etc/real")
        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("etc/example"), to: real)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("etc/example").path, withDestinationPath: "real")
        try fixture.run(install: [fixture.package(version: "2", files: ["etc/example": "two"], controls: ["conffiles": "/etc/example\n"])])
        #expect(try fixture.text("etc/real") == "two")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.root.appendingPathComponent("etc/example").path) == "real")
    }

    /// `pkg_remove_old_files`: an old conffile that is the new one through a
    /// directory link hands its hash over, so an unchanged file takes the
    /// new version, and it leaves the field.
    @Test func conffileBehindADirectoryLinkHandsItsHashOver() throws {
        let fixture = try NativeInstallFixture()
        try fixture.run(install: [fixture.package(files: ["etc/old/conf": "one"], controls: ["conffiles": "/etc/old/conf\n"])])
        let old = fixture.root.appendingPathComponent("etc/old")
        try FileManager.default.moveItem(at: old, to: fixture.root.appendingPathComponent("etc/new"))
        try FileManager.default.createSymbolicLink(atPath: old.path, withDestinationPath: "new")
        try fixture.run(install: [fixture.package(version: "2", files: ["etc/new/conf": "two"], controls: ["conffiles": "/etc/new/conf\n"])])
        #expect(try fixture.text("etc/new/conf") == "two")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("etc/new/conf.dpkg-dist").path))
        let conffiles = try PackageDatabase(directory: fixture.database).records["example.package"]?["conffiles"]
        #expect(conffiles?.contains("/etc/old/conf") == false)
    }

    // MARK: db-fsys-override

    @Test func statoverrideAcceptsNumericAccounts() throws {
        let fixture = try NativeInstallFixture()
        try Data("#\(getuid()) #\(getgid()) 600 /usr/share/example\n".utf8).write(to: fixture.database.appendingPathComponent("statoverride"))
        try fixture.run(install: [fixture.package(files: ["usr/share/example": "x"])])
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.appendingPathComponent("usr/share/example").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    // MARK: depisok

    @Test func aBrokenDependencyElsewhereDoesNotBlockAnUnrelatedInstall() throws {
        let fixture = try NativeInstallFixture()
        try seed(fixture, [["package": "broken", "version": "1", "architecture": "all", "status": "install ok installed", "depends": "missing.package"]])
        try fixture.run(install: [fixture.package()])
        #expect(try fixture.status() == "install ok installed")
        #expect(throws: (any Error).self) { try fixture.run(install: [fixture.package("other", fields: ["depends": "missing.package"])]) }
    }

    // MARK: versiondescribe

    @Test func versionsAreSpelledTheWayDpkgSpellsThem() {
        #expect(DebianVersion.canonical("0:1.0-1") == "1.0-1")
        #expect(DebianVersion.canonical(" 1.0 ") == "1.0")
        #expect(DebianVersion.canonical("+2:1.0") == "2:1.0")
        #expect(DebianVersion.canonical("0:1:0") == "0:1:0")
        #expect(DebianVersion.canonical("1.0-0") == "1.0-0")
        #expect(DebianVersion.canonical("99999999999:1") == nil)
    }

    // MARK: cu_installnew

    @Test func journalReplayLeavesAFileAnotherToolRewrote() throws {
        let fixture = try NativeInstallFixture()
        let path = fixture.root.appendingPathComponent("original")
        try Data("before".utf8).write(to: path)
        let filesystem = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try filesystem.remove(path)
        // dpkg reinstalled the package in the meantime
        try Data("rewritten".utf8).write(to: path)
        let reopened = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try reopened.recover()
        #expect(try String(contentsOf: path, encoding: .utf8) == "rewritten")
        // nothing intervened: the removal is undone
        let again = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try again.remove(path)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database).recover()
        #expect(try String(contentsOf: path, encoding: .utf8) == "rewritten")
    }
}
