import CIrisinDB
import Darwin
import Foundation
@testable import IrisinInstaller
import Testing

/// A bootstrap's account files, written as `pwd_mkdb` and base write them,
/// and read back as libiosexec's `getpwent.c` and `getgrent.c` read them.
final class BootstrapAccountsFixture {
    let root: URL
    private let owned: Bool

    /// In `root` when given, which whoever made it removes.
    init(root: URL? = nil) throws {
        owned = root == nil
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("bootstrap accounts " + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.root.appendingPathComponent("etc"), withIntermediateDirectories: true)
    }

    deinit {
        if owned {
            try? FileManager.default.removeItem(at: root)
        }
    }

    var layout: BootstrapLayout {
        .init(kind: .roothide(jbroot: root.path))
    }

    /// A record as `__hashpw` reads one: the name, the password, the uid and
    /// gid as native ints, the change time, the class, gecos, home and shell,
    /// then the expiry.
    static func record(_ name: String, uid: UInt32, gecos: String = "") -> [UInt8] {
        var bytes: [UInt8] = []
        func text(_ value: String) {
            bytes += Array(value.utf8) + [0]
        }
        func integer(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value) { bytes += $0 }
        }
        text(name)
        text("*")
        integer(uid)
        integer(uid)
        integer(Int(0))
        text("")
        text(gecos)
        text("/var/empty")
        text("/usr/bin/false")
        integer(Int(0))
        return bytes
    }

    /// `etc/<file>`, a db(3) hash keyed by `_PW_KEYBYNAME` and the name.
    func users(_ records: [String: [UInt8]], file: String = "pwd.db") throws {
        let path = root.appendingPathComponent("etc/" + file).path
        guard let database = dbopen(path, O_RDWR | O_CREAT | O_TRUNC, 0o644, DB_HASH, nil) else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = database.pointee.close(database) }
        for (name, record) in records {
            var key = [UInt8(ascii: "1")] + Array(name.utf8)
            var value = record
            let stored = key.withUnsafeMutableBytes { key in
                value.withUnsafeMutableBytes { value in
                    var keyEntry = DBT(data: key.baseAddress, size: key.count)
                    var valueEntry = DBT(data: value.baseAddress, size: value.count)
                    return database.pointee.put(database, &keyEntry, &valueEntry, 0)
                }
            }
            guard stored == 0 else { throw POSIXError(.EIO) }
        }
    }

    func users(_ ids: [String: UInt32], file: String = "pwd.db") throws {
        try users(ids.reduce(into: [:]) { $0[$1.key] = Self.record($1.key, uid: $1.value) }, file: file)
    }

    func groups(_ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent("etc/group"))
    }
}

struct BootstrapAccountsTests {
    /// redis-tools' postinst adds `redis` to the bootstrap, and iOS never
    /// hears of it: the vphone whose statoverride stopped every install.
    @Test func namesAreTheBootstrapsOwn() throws {
        let fixture = try BootstrapAccountsFixture()
        try fixture.users(["redis": 1001])
        try fixture.groups("redis:*:1001:\n")
        let accounts = BootstrapAccounts(layout: fixture.layout)
        #expect(accounts.user("redis") == 1001)
        #expect(accounts.group("redis") == 1001)
        #expect(getpwnam("redis") == nil)
    }

    /// A rootless bootstrap's files are under its prefix, which the
    /// simulator mounts in a directory of its own.
    @Test func rootlessReadsUnderItsPrefix() throws {
        let fixture = try BootstrapAccountsFixture()
        try fixture.users(["redis": 1001])
        try fixture.groups("redis:*:1002:\n")
        let accounts = BootstrapAccounts(layout: .init(kind: .rootless(prefix: "/var/jb"), mount: fixture.root.path))
        #expect(accounts.user("redis") == 1001)
        #expect(accounts.group("redis") == 1002)
    }

    /// libiosexec never falls back to the system's lookup: a bootstrap that
    /// has its files answers alone, and `daemon` is not one of its users.
    @Test func theSystemIsNeverMergedIn() throws {
        let fixture = try BootstrapAccountsFixture()
        try fixture.users(["redis": 1001])
        try fixture.groups("redis:*:1001:\n")
        #expect(getpwnam("daemon") != nil)
        #expect(getgrnam("daemon") != nil)
        let accounts = BootstrapAccounts(layout: fixture.layout)
        #expect(accounts.user("daemon") == nil)
        #expect(accounts.group("daemon") == nil)
    }

    /// libiosexec opens nothing and answers nothing: a bootstrap without
    /// its files knows no names, `root` included, whatever iOS knows.
    @Test(arguments: [false, true]) func aBootstrapWithoutTheFilesKnowsNoNames(asRoot: Bool) throws {
        let fixture = try BootstrapAccountsFixture()
        let accounts = BootstrapAccounts(layout: fixture.layout, asRoot: asRoot)
        #expect(getpwnam("root") != nil)
        #expect(accounts.user("root") == nil)
        #expect(accounts.group("wheel") == nil)
    }

    /// Rootful and the Mac harness: libiosexec is the system's lookup there.
    @Test func withoutABootstrapTheSystemAnswers() {
        let accounts = BootstrapAccounts(layout: .init(kind: .none))
        #expect(accounts.user("root") == 0)
        #expect(accounts.group("wheel") == 0)
    }

    /// A file that is there and cannot be read answers nothing either.
    @Test func anUnreadableDatabaseIsNotTheSystems() throws {
        let fixture = try BootstrapAccountsFixture()
        try Data("not a hash".utf8).write(to: fixture.root.appendingPathComponent("etc/pwd.db"))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("etc/group"), withIntermediateDirectories: true)
        let accounts = BootstrapAccounts(layout: fixture.layout)
        #expect(accounts.user("root") == nil)
        #expect(accounts.group("wheel") == nil)
    }

    /// `__initdb`: root opens `_PATH_SMP_DB`, and `_PATH_MP_DB` only when
    /// that does not open; anyone else opens `_PATH_MP_DB` alone. The
    /// database that opens answers alone.
    @Test func rootReadsTheShadowDatabaseFirst() throws {
        let fixture = try BootstrapAccountsFixture()
        try fixture.users(["redis": 1, "shadowed": 3], file: "spwd.db")
        try fixture.users(["redis": 2, "plain": 4])
        let root = BootstrapAccounts(layout: fixture.layout, asRoot: true)
        #expect(root.user("redis") == 1)
        #expect(root.user("plain") == nil)
        let mobile = BootstrapAccounts(layout: fixture.layout, asRoot: false)
        #expect(mobile.user("redis") == 2)
        #expect(mobile.user("shadowed") == nil)
        // a shadow database that does not open hands over to the other
        try Data("not a hash".utf8).write(to: fixture.root.appendingPathComponent("etc/spwd.db"))
        #expect(BootstrapAccounts(layout: fixture.layout, asRoot: true).user("redis") == 2)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("etc/spwd.db"))
        #expect(BootstrapAccounts(layout: fixture.layout, asRoot: true).user("plain") == 4)
    }

    /// `_pwhashbyname` refuses a name longer than `MAXLOGNAME`, and the
    /// buffer `getpwnam` keeps is 1024 bytes: a longer record is not found.
    @Test func longNamesAndLongRecordsAreNotFound() throws {
        let fixture = try BootstrapAccountsFixture()
        let long = String(repeating: "a", count: Int(MAXLOGNAME) + 1)
        let fits = String(repeating: "b", count: Int(MAXLOGNAME))
        let base = BootstrapAccountsFixture.record("full", uid: 7).count
        try fixture.users([
            long: BootstrapAccountsFixture.record(long, uid: 1),
            fits: BootstrapAccountsFixture.record(fits, uid: 2),
            "full": BootstrapAccountsFixture.record("full", uid: 3, gecos: String(repeating: "g", count: 1024 - base)),
            "over": BootstrapAccountsFixture.record("over", uid: 4, gecos: String(repeating: "g", count: 1025 - base)),
            "cut": Array("cut".utf8) + [0, 0x2A, 0, 1, 0],
        ])
        let accounts = BootstrapAccounts(layout: fixture.layout)
        #expect(accounts.user(long) == nil)
        #expect(accounts.user(fits) == 2)
        #expect(accounts.user("full") == 3)
        #expect(accounts.user("over") == nil)
        // libiosexec reads past the end of this one; Irisin finds nothing
        #expect(accounts.user("cut") == nil)
    }

    /// `grscan`, line by line: the first line with the name whose gid is a
    /// whole decimal number below `GID_MAX`, as `strtoul` reads one.
    @Test func groupLinesAreReadAsGrscanReadsThem() throws {
        let fixture = try BootstrapAccountsFixture()
        let tooLong = "long:*:5:" + String(repeating: "m", count: 1100) + "\n"
        try fixture.groups("""
        redis:*:x:
        redis:*:1001:redis
        three:*:3
        short:*
        spaced:*: 7:
        signed:*:+8:
        trailing:*:9x:
        negative:*:-1:
        maximum:*:2147483647:
        below:*:2147483646:
        \(tooLong)long:*:6:
        empty:*::
        last:*:10:
        """)
        let accounts = BootstrapAccounts(layout: fixture.layout)
        #expect(accounts.group("redis") == 1001)
        #expect(accounts.group("three") == 3)
        #expect(accounts.group("short") == nil)
        #expect(accounts.group("spaced") == 7)
        #expect(accounts.group("signed") == 8)
        #expect(accounts.group("trailing") == nil)
        #expect(accounts.group("negative") == nil)
        #expect(accounts.group("maximum") == nil)
        #expect(accounts.group("below") == 2_147_483_646)
        #expect(accounts.group("long") == 6)
        #expect(accounts.group("empty") == nil)
        // no newline after it, so `grscan` skips it
        #expect(accounts.group("last") == nil)
        #expect(accounts.group("red") == nil)
    }

    /// One instance answers as it first did; the next reading of the
    /// database sees what a preinst added in between.
    @Test func anAddedAccountIsSeenByTheNextInstance() throws {
        let fixture = try BootstrapAccountsFixture()
        try fixture.users(["root": 0])
        try fixture.groups("wheel:*:0:root\n")
        let before = BootstrapAccounts(layout: fixture.layout)
        #expect(before.user("redis") == nil)
        #expect(before.group("redis") == nil)
        try fixture.users(["root": 0, "redis": 1001])
        try fixture.groups("wheel:*:0:root\nredis:*:1001:\n")
        #expect(before.user("redis") == nil)
        #expect(before.group("redis") == nil)
        let after = BootstrapAccounts(layout: fixture.layout)
        #expect(after.user("redis") == 1001)
        #expect(after.group("redis") == 1001)
    }
}
