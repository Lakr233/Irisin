import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

struct NativeRecoveryTests {
    @Test func deviceVirtualIdentitySurvivesDatabaseRewrite() throws {
        let fixture = try NativeInstallFixture()
        let identity = "gsc.device-supports-liquid-detection_-corrosion-mitigation"
        let fields = ["package": identity, "version": "1", "architecture": "all", "essential": "yes", "status": "install ok installed"]
        try Data(PackageDatabase.paragraph(fields).utf8).write(to: fixture.database.appendingPathComponent("status"))
        let database = try PackageDatabase(directory: fixture.database)
        try database.consolidate()
        #expect(try PackageDatabase(directory: fixture.database).records[identity] == fields)
    }

    @Test func statusRewritePreservesMultilineDescription() throws {
        let fixture = try NativeInstallFixture()
        let description = "Summary\nLong description\n.\n  Indented content"
        let fields = ["package": "example", "version": "1", "architecture": "all", "status": "install ok installed", "description": description]
        try Data(PackageDatabase.paragraph(fields).utf8).write(to: fixture.database.appendingPathComponent("status"))
        let database = try PackageDatabase(directory: fixture.database)
        try database.consolidate()
        #expect(try PackageDatabase(directory: fixture.database).records["example"]?["description"] == description)
    }

    @Test func interruptedFileChangesRestoreOnNextOpen() throws {
        let fixture = try NativeInstallFixture()
        let path = fixture.root.appendingPathComponent("original")
        try Data("before".utf8).write(to: path)
        let filesystem = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try filesystem.backup(path)
        try Data("interrupted".utf8).write(to: path)
        let reopened = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try reopened.recover()
        #expect(try String(contentsOf: path, encoding: .utf8) == "before")
    }

    /// A file goes back with its own bits. Neither a clone nor a copy carries
    /// setuid or setgid over, and the bootstrap's `sudo`, `su` and `ping`
    /// have them: a rolled-back transaction that left them behind would
    /// leave the account unable to become root.
    @Test func aRestoredFileKeepsItsSetuidBit() throws {
        let fixture = try NativeInstallFixture()
        let path = fixture.root.appendingPathComponent("sudo")
        try Data("before".utf8).write(to: path)
        #expect(chmod(path.path, 0o4755) == 0)
        let filesystem = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try filesystem.backup(path)
        try Data("after".utf8).write(to: path)
        #expect(chmod(path.path, 0o0755) == 0)
        try filesystem.rollback()
        var info = stat()
        #expect(lstat(path.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o4755)
        #expect(try String(contentsOf: path, encoding: .utf8) == "before")
    }

    @Test func failedRollbackRetainsRecoveryJournal() throws {
        let fixture = try NativeInstallFixture()
        let path = fixture.root.appendingPathComponent("original")
        try Data("before".utf8).write(to: path)
        let filesystem = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try filesystem.backup(path)
        let journals = fixture.database.appendingPathComponent("irisin-journal")
        let journal = try #require(FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: journal.appendingPathComponent("0"))
        #expect(throws: (any Error).self) { try filesystem.rollback() }
        #expect(FileManager.default.fileExists(atPath: journal.appendingPathComponent("files.json").path))
        #expect(try String(contentsOf: path, encoding: .utf8) == "before")
    }

    /// The one journal an open filesystem has written to.
    private func record(_ fixture: NativeInstallFixture) throws -> URL {
        let journals = fixture.database.appendingPathComponent("irisin-journal")
        let journal = try #require(FileManager.default.contentsOfDirectory(at: journals, includingPropertiesForKeys: nil).first)
        return journal.appendingPathComponent("files.json")
    }

    /// A run the kernel stopped while appending leaves its last line cut
    /// short. That line is the write that never finished, so the record
    /// before it is the state the replay uses, and every earlier place
    /// still comes back.
    @Test func aCutShortFinalJournalLineIsTheAppendThatDiedWithTheRun() throws {
        let fixture = try NativeInstallFixture()
        let first = fixture.root.appendingPathComponent("first")
        let second = fixture.root.appendingPathComponent("second")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let filesystem = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try filesystem.backup(first)
        try filesystem.backup(second)
        try Data("interrupted".utf8).write(to: first)
        try Data("interrupted".utf8).write(to: second)
        try filesystem.noteWritten(second)
        let record = try record(fixture)
        let lines = try Data(contentsOf: record).split(separator: 0x0A)
        #expect(lines.count == 3)
        let whole = lines[0].count + 1 + lines[1].count + 1
        let handle = try FileHandle(forWritingTo: record)
        try handle.truncate(atOffset: UInt64(whole + lines[2].count / 2))
        try handle.close()

        let reopened = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try reopened.recover()
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    /// A journal file with no line in it is the run that died between its
    /// first copy aside and its first record. Nothing at the destination
    /// had changed yet, so the next run starts clean instead of refusing
    /// this journal, and every one after it, for good.
    @Test func aJournalWithNoRecordInItLeavesTheNextRunClean() throws {
        let fixture = try NativeInstallFixture()
        let path = fixture.root.appendingPathComponent("original")
        try Data("before".utf8).write(to: path)
        let filesystem = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try filesystem.backup(path)
        let record = try record(fixture)
        try Data().write(to: record)
        let reopened = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try reopened.recover()
        #expect(try String(contentsOf: path, encoding: .utf8) == "before")
        #expect(!FileManager.default.fileExists(atPath: record.deletingLastPathComponent().path))
    }

    /// A line that is not the last one cannot be a write that was cut off.
    /// The journal is damaged, and the run says so and keeps it rather than
    /// walk away from destinations it cannot account for.
    @Test func aDamagedEarlierJournalLineStopsTheRun() throws {
        let fixture = try NativeInstallFixture()
        let first = fixture.root.appendingPathComponent("first")
        let second = fixture.root.appendingPathComponent("second")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let filesystem = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try filesystem.backup(first)
        try filesystem.backup(second)
        try Data("interrupted".utf8).write(to: first)
        let record = try record(fixture)
        var damaged = try Data(contentsOf: record)
        damaged[0] = UInt8(ascii: "x")
        try damaged.write(to: record)
        let reopened = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        #expect(throws: PackageFailure.self) { try reopened.recover() }
        #expect(FileManager.default.fileExists(atPath: record.path))
        #expect(try String(contentsOf: first, encoding: .utf8) == "interrupted")
    }

    /// A destination noted more than once is one record, and the line that
    /// wins is the last one. An earlier line would either leave the file
    /// the transaction put back in place (the removal it noted first) or
    /// overwrite what another tool has written since (the copy aside).
    @Test func theLastLineForAPlaceIsTheOneReplayed() throws {
        let fixture = try NativeInstallFixture()
        let path = fixture.root.appendingPathComponent("original")
        try Data("before".utf8).write(to: path)
        let filesystem = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try filesystem.remove(path)
        try Data("during".utf8).write(to: path)
        try filesystem.noteWritten(path)
        #expect(try Data(contentsOf: record(fixture)).split(separator: 0x0A).count == 3)
        let reopened = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try reopened.recover()
        #expect(try String(contentsOf: path, encoding: .utf8) == "before")

        // the same three lines, with another tool's file at the path: the
        // last record's digest no longer matches, so the replay leaves it
        let again = try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database)
        try again.remove(path)
        try Data("during".utf8).write(to: path)
        try again.noteWritten(path)
        try Data("elsewhere".utf8).write(to: path)
        try PackageFilesystem(root: fixture.root, layout: .init(kind: .none), database: fixture.database).recover()
        #expect(try String(contentsOf: path, encoding: .utf8) == "elsewhere")
    }

    /// A blank line or a bare `/` stops dpkg on any package; `/.` is the
    /// root as dpkg writes it, once, at the head of every list.
    @Test func fileListNeverContainsEmptyOrBareRootEntries() throws {
        let fixture = try NativeInstallFixture()
        let database = try PackageDatabase(directory: fixture.database)
        try database.writeInfo("example", member: "list", text: "\n/\n/.\n")
        #expect(try fixture.text("Library/dpkg/info/example.list") == "/.\n")
        try database.writeInfo("example", member: "list", text: "/usr/share/example\n\n")
        #expect(try fixture.text("Library/dpkg/info/example.list") == "/.\n/usr/share/example\n")
    }

    @Test func standardPendingUpdateIsIncorporated() throws {
        let fixture = try NativeInstallFixture()
        let updates = fixture.database.appendingPathComponent("updates")
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        let record = "Package: example\nVersion: 1\nArchitecture: all\nStatus: install ok unpacked\n\n"
        try Data(record.utf8).write(to: updates.appendingPathComponent("0000"))
        let database = try PackageDatabase(directory: fixture.database)
        #expect(database.records["example"]?["status"] == "install ok unpacked")
        try database.consolidate()
        #expect(!FileManager.default.fileExists(atPath: updates.appendingPathComponent("0000").path))
        #expect(try PackageDatabase(directory: fixture.database).records["example"]?["version"] == "1")
    }

    @Test func hardLinkChainUsesNewContentsDuringUpgrade() throws {
        let fixture = try NativeInstallFixture()
        let links = [
            PreparedEntry(path: "usr/share/aa", kind: .hardLink, linkTarget: "usr/share/bb", mode: 0o644, uid: 0, gid: 0, modificationTime: 0),
            PreparedEntry(path: "usr/share/bb", kind: .hardLink, linkTarget: "usr/share/cc", mode: 0o644, uid: 0, gid: 0, modificationTime: 0),
        ]
        try fixture.run(install: [fixture.package(files: ["usr/share/cc": "old"], links: links)])
        try fixture.run(install: [fixture.package(version: "2", files: ["usr/share/cc": "new"], links: links)])
        #expect(try fixture.text("usr/share/aa") == "new")
        #expect(try fixture.text("usr/share/bb") == "new")
        #expect(try fixture.text("usr/share/cc") == "new")
    }

    @Test func triggersConfigureInterestedPackage() throws {
        let fixture = try NativeInstallFixture()
        let script = "#!/bin/sh\nif [ \"$1\" = triggered ]; then printf '%s' \"$2\" > \"$DPKG_ROOT/trigger-result\"; fi\n"
        let interested = try fixture.package("interested.package", controls: ["triggers": "interest-noawait example-event\n", "postinst": script])
        try fixture.run(install: [interested])
        let activating = try fixture.package(controls: ["triggers": "activate example-event\n"])
        try fixture.run(install: [activating])
        #expect(try fixture.text("trigger-result") == "example-event")
        #expect(try fixture.status("interested.package") == "install ok installed")
        #expect(try fixture.status() == "install ok installed")
    }

    @Test func triggerProcessingPreservesHeldSelection() {
        var fields = ["status": "hold ok triggers-pending"]
        PackageDatabase.setState("installed", in: &fields)
        #expect(fields["status"] == "hold ok installed")
    }
}
