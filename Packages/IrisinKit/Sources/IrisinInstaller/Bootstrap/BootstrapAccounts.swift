import CIrisinDB
import Darwin

/// The users and groups a bootstrap's own programs know, by name.
///
/// dpkg names an account twice: the owner of a file in an archive, and the
/// owner in a statoverride. Procursus builds every program against
/// libiosexec, whose header turns `getpwnam` and `getgrnam` into
/// `ie_getpwnam` and `ie_getgrnam`, and on a rootless or roothide bootstrap
/// those read the bootstrap's files and never the system's: `redis`, made by
/// redis-tools' postinst, is there and nowhere in iOS. These are those two
/// readers again (libiosexec 1.3.1's `getpwent.c` and `getgrent.c`, which
/// roothide's fork has unchanged), decision for decision:
///
/// - A user is a record in `etc/spwd.db` when root asks, else in
///   `etc/pwd.db`: a db(3) hash that `pwd_mkdb` writes, keyed by
///   `_PW_KEYBYNAME` and the name; the record is the name, the password,
///   then the uid as a native `int`. A name longer than `MAXLOGNAME`, or a
///   record longer than the 1024 bytes `getpwnam` keeps, is not found.
/// - A group is the first line of `etc/group` with that name whose third
///   field is a whole decimal number below `GID_MAX`. A line with no
///   newline within its first 1023 bytes is skipped, and so is a last line
///   that does not end in one.
///
/// A bootstrap's files answer alone: a name they lack is unknown, whatever
/// iOS knows, and a bootstrap without them knows no names at all, as its
/// dpkg knows none. Without a bootstrap (rootful, the Mac harness)
/// libiosexec is the system's own lookup, and so is this. One rule is
/// Irisin's: a record too short to hold a uid is not found, where
/// libiosexec reads past its end.
///
/// Each instance remembers what it answered, so one is made per reading of
/// the dpkg database (`PackageOverrides`), after the preinst that may have
/// added an account.
final class BootstrapAccounts {
    private let userDatabases: [String]?
    private let groupFile: String?
    private var users: [String: UInt32?] = [:]
    private var groups: [String: UInt32?] = [:]

    /// `asRoot` is whether libiosexec would read the shadow database, which
    /// it decides by `geteuid`; the tests say it for themselves.
    init(layout: BootstrapLayout, asRoot: Bool = geteuid() == 0) {
        if layout.kind == .none {
            userDatabases = nil
            groupFile = nil
        } else {
            let file = { layout.resolve(layout.bootstrapPath("/etc/" + $0)) }
            // `_PATH_SMP_DB` for root, then `_PATH_MP_DB`
            userDatabases = asRoot ? [file("spwd.db"), file("pwd.db")] : [file("pwd.db")]
            groupFile = file("group")
        }
    }

    func user(_ name: String) -> UInt32? {
        if let known = users[name] {
            return known
        }
        let answer = userDatabases.map { Self.user(name, in: $0) } ?? Self.systemUser(name)
        users[name] = answer
        return answer
    }

    func group(_ name: String) -> UInt32? {
        if let known = groups[name] {
            return known
        }
        let answer = groupFile.map { Self.group(name, in: $0) } ?? Self.systemGroup(name)
        groups[name] = answer
        return answer
    }

    private static func systemUser(_ name: String) -> UInt32? {
        getpwnam(name)?.pointee.pw_uid
    }

    private static func systemGroup(_ name: String) -> UInt32? {
        getgrnam(name)?.pointee.gr_gid
    }

    /// `getpwnam_internal`: the first database that opens, then
    /// `_pwhashbyname` and `__hashpw`.
    private static func user(_ name: String, in databases: [String]) -> UInt32? {
        var opened: UnsafeMutablePointer<DB>?
        for path in databases where opened == nil {
            opened = dbopen(path, O_RDONLY, 0, DB_HASH, nil)
        }
        guard let database = opened else { return nil }
        defer { _ = database.pointee.close(database) }
        let bytes = Array(name.utf8)
        guard bytes.count <= Int(MAXLOGNAME) else { return nil }
        // `_PW_KEYBYNAME`, which Swift cannot import
        var key = [UInt8(ascii: "1")] + bytes
        return key.withUnsafeMutableBytes { key -> UInt32? in
            var keyEntry = DBT(data: key.baseAddress, size: key.count)
            var record = DBT()
            guard database.pointee.get(database, &keyEntry, &record, 0) == 0,
                  let start = record.data, record.size <= 1024
            else { return nil }
            let fields = UnsafeRawBufferPointer(start: start, count: record.size)
            // the name and the password, each up to its NUL
            var offset = 0
            for _ in 0 ..< 2 {
                guard let end = fields[offset...].firstIndex(of: 0) else { return nil }
                offset = end + 1
            }
            guard offset + MemoryLayout<UInt32>.size <= fields.count else { return nil }
            return fields.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
    }

    /// `getgrnam_gs`: `start_gr`, then `grscan` with a name.
    private static func group(_ name: String, in path: String) -> UInt32? {
        guard let file = fopen(path, "re") else { return nil }
        defer { fclose(file) }
        // `MAXLINELENGTH`
        var line = [CChar](repeating: 0, count: 1024)
        while fgets(&line, Int32(line.count), file) != nil {
            // a line too long for the buffer is skipped whole
            guard strchr(line, 0x0A) != nil else {
                var character = getc(file)
                while character != 0x0A, character != EOF {
                    character = getc(file)
                }
                continue
            }
            let gid = line.withUnsafeMutableBufferPointer { buffer -> UInt32? in
                var rest = buffer.baseAddress
                guard let entryName = strsep(&rest, ":\n"), strcmp(entryName, name) == 0 else { return nil }
                _ = strsep(&rest, ":\n")
                guard let field = strsep(&rest, ":\n") else { return nil }
                var end: UnsafeMutablePointer<CChar>?
                let value = strtoul(field, &end, 10)
                // `grscan` also wants something after the gid, which a line
                // that ends in a newline always has
                guard end != field, end?.pointee == 0, value < UInt(GID_MAX) else { return nil }
                return UInt32(value)
            }
            if let gid {
                return gid
            }
        }
        return nil
    }
}
