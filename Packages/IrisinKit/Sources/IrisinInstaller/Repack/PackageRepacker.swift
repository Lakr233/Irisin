import CryptoKit
import Darwin
import Foundation
import IrisinPreparation
import IrisinProtocol

/// `dpkg-repack`, natively: a `.deb` built from what dpkg says a package
/// installed, as close to the one that was downloaded as an installed package
/// can say.
///
/// The control file is the status record without what only installation
/// wrote, and the control members are the info files. The data archive is the
/// list, in its order, each path as it is on disk now: its mode, owner, time
/// and bytes, a link's text as the archive spelled it (`archivedLinkText`).
/// What was read is held against what dpkg recorded: a file that differs goes
/// in as it is, and a listed path that is gone stays out, each said in a
/// notice and counted in `Repacked`. `md5sums` is dpkg's copy, the original's
/// own bytes, while it says what the archive holds, and is made from what went
/// in once it does not, so the package always agrees with itself.
///
/// What an installed package cannot say is what differs from the download by
/// design: the control fields in dpkg's order, the compression (always zstd,
/// as Procursus's packages are, at a level of its own) and an `md5sums` the
/// original may not have shipped, which dpkg then wrote itself.
///
/// Root reads, since a package may ship what mobile cannot read, and the
/// package leaves through the descriptor the client opened, never a path. The
/// members are built in a directory of root's: they hold those files too.
final class PackageRepacker {
    /// The client removed the file: nobody is waiting for the package.
    struct Abandoned: Error, CustomStringConvertible {
        let description = "The file it was writing was removed"
    }

    /// One thing the data archive holds, decided before anything is read so
    /// the progress has a total.
    private struct Item {
        let entry: PreparedEntry
        /// Where a regular file's bytes are.
        var location: URL?
        var size: Int64 = 0
    }

    private static let workPrefix = "irisin-repack-"

    private let layout: BootstrapLayout
    private let directory: URL
    private let filesystem: PackageFilesystem
    private let output: Int32
    private let emit: (InstallerEvent) -> Void

    init(
        root: URL,
        layout: BootstrapLayout,
        databaseDirectory: URL,
        output: Int32,
        emit: @escaping (InstallerEvent) -> Void
    ) throws {
        self.layout = layout
        directory = databaseDirectory
        filesystem = try PackageFilesystem(root: root, layout: layout, database: databaseDirectory)
        self.output = output
        self.emit = emit
    }

    func run(_ identity: String) throws -> InstallerEvent.Repacked {
        // as a transaction takes them: a package being replaced reads as
        // neither version
        let frontend: DpkgLock
        let backend: DpkgLock
        do {
            frontend = try DpkgLock(path: directory.appendingPathComponent("lock-frontend").path)
            backend = try DpkgLock(path: directory.appendingPathComponent("lock").path)
        } catch {
            throw PackageFailure("Another operation is using the package database")
        }
        defer {
            backend.close()
            frontend.close()
        }

        let database = try PackageDatabase(directory: directory)
        guard let fields = database.records[identity], PackageDatabase.isConfigured(fields),
              let version = fields["version"], let architecture = fields["architecture"]
        else { throw PackageFailure("\(identity) is not fully installed") }
        let time = recordedTime(of: identity, in: database)

        // what a helper that was killed left: under these locks, nobody's
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where name.hasPrefix(Self.workPrefix)
        {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let work = directory.appendingPathComponent(Self.workPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: work,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: work) }

        // the owners a statoverride set are on disk: its accounts are not read
        let overrides = try PackageOverrides(directory: directory, layout: layout, statoverrides: false)
        let (items, leftOut) = try plan(identity, database: database, overrides: overrides, time: time)
        for path in leftOut {
            emit(.notice("Left out \(path)"))
        }

        let declared = try Conffiles.declarations(infoText(database, identity, "conffiles"))
        let data = work.appendingPathComponent("data.tar.zst")
        let digests = try writeData(items, identity: identity, to: data)

        let recorded = try recordedDigests(database, identity, fields: fields)
        // a file that became a link has a digest on record and none here
        let changed = items.map(\.entry.path).filter { path in
            recorded[path] != nil && digests[path] != recorded[path]
        }
        for path in changed {
            emit(.notice("Changed since installation: /\(path)"))
        }

        let control = work.appendingPathComponent("control.tar.zst")
        try writeControl(
            identity,
            fields: fields,
            database: database,
            items: items,
            digests: digests,
            conffiles: declared.keep,
            time: time,
            to: control
        )
        try checkAbandoned()
        try DebianPackageWriter.write(control: control, data: data, time: time, to: output)
        fsync(output)

        // the epoch alone goes: a version with one may have colons of its own
        let name = version.split(separator: ":", maxSplits: 1).last.map(String.init) ?? version
        return .init(
            fileName: [identity, name, architecture].joined(separator: "_") + ".deb",
            leftOut: leftOut.count,
            changed: changed.count
        )
    }

    /// When dpkg last wrote the package's list: what the package's own
    /// members are dated, so two repacks of one installation are one file.
    private func recordedTime(of identity: String, in database: PackageDatabase) -> Int64 {
        var info = stat()
        return lstat(database.info(identity, "list").path, &info) == 0 ? Int64(info.st_mtimespec.tv_sec) : 0
    }

    private func infoText(_ database: PackageDatabase, _ identity: String, _ member: String) throws -> String? {
        let url = database.info(identity, member)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func checkAbandoned() throws {
        var info = stat()
        guard fstat(output, &info) == 0, info.st_nlink > 0 else { throw Abandoned() }
    }

    // MARK: - The list, as it is on disk

    /// What goes in the data archive, in the list's order, and the listed
    /// paths that do not. `/.` is the archive's own `./`.
    private func plan(
        _ identity: String,
        database: PackageDatabase,
        overrides: PackageOverrides,
        time: Int64
    ) throws -> (items: [Item], leftOut: [String]) {
        let paths = try database.files(identity)
        let parents = Self.parents(of: paths)
        var items = [Item(entry: Self.directory("", mode: 0o755, time: time))]
        var leftOut: [String] = []
        var firstNamed: [FileIdentity: String] = [:]
        let inherited = inheritedGroup
        for path in paths {
            let relative = try PreparedPackage.relativePath(String(decoding: path.utf8.dropFirst(), as: UTF8.self))
            // the tar layout above a rootless prefix or the /rootfs bridge:
            // what is there is the system's, and the archive only walks it
            if filesystem.isScaffolding(path), parents.contains(path) || isDirectory(layout.resolve(path)) {
                items.append(Item(entry: Self.directory(relative, mode: 0o755, time: time)))
                continue
            }
            // a list has no kinds: asked as a directory, a path in dpkg's own
            // directories is answered rather than refused. One the installer
            // would not have placed, which dpkg did, is read where it says.
            let actual = overrides.path(path, owner: identity)
            let location = (try? filesystem.location(actual, for: Self.anyDirectory))
                ?? URL(fileURLWithPath: layout.resolve(actual))
            var info = stat()
            guard lstat(location.path, &info) == 0 else {
                guard errno == ENOENT || errno == ENOTDIR else {
                    throw PackageFailure("Cannot read \(path): \(String(cString: strerror(errno)))")
                }
                leftOut.append(path)
                continue
            }
            // a link the bootstrap keeps where the archive has a directory,
            // /var/jb/var or ElleKit's DynamicLibraries: written as a link,
            // it would replace that link when the package is installed
            if info.st_mode & S_IFMT == S_IFLNK, parents.contains(path),
               let target = filesystem.physical(location.path, followingLast: true)
            {
                var followed = stat()
                if stat(target, &followed) == 0, followed.st_mode & S_IFMT == S_IFDIR {
                    info = followed
                }
            }
            let entry = { (kind: PreparedEntry.Kind, link: String?) in
                let group = info.st_gid == inherited ? 0 : info.st_gid
                return PreparedEntry(
                    path: relative,
                    kind: kind,
                    linkTarget: link,
                    mode: UInt32(info.st_mode & 0o7777),
                    uid: info.st_uid,
                    gid: group,
                    userName: info.st_uid == 0 ? "root" : nil,
                    groupName: group == 0 ? "wheel" : nil,
                    modificationTime: Int64(info.st_mtimespec.tv_sec)
                )
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                items.append(Item(entry: entry(.directory, nil)))
            case S_IFLNK:
                try items.append(Item(entry: entry(.symbolicLink, layout.archivedLinkText(linkText(at: location)))))
            case S_IFREG:
                if info.st_nlink > 1, let file = FileIdentity(location) {
                    if let first = firstNamed[file] {
                        items.append(Item(entry: entry(.hardLink, first)))
                        continue
                    }
                    firstNamed[file] = relative
                }
                items.append(Item(entry: entry(.file, nil), location: location, size: Int64(info.st_size)))
            default:
                // a socket or a pipe a program left in a listed place
                leftOut.append(path)
            }
        }
        return (items, leftOut)
    }

    /// The group of the place a RootHide root sits, the app containers'. What
    /// is made there takes its parent's group, and what no installer has
    /// chowned keeps it: `usr` and `Library`, which predate every package, and
    /// a daemon's plist once RootHide has rewritten it. No archive named it.
    private var inheritedGroup: gid_t? {
        guard case let .roothide(jbroot) = layout.kind else { return nil }
        var info = stat()
        guard stat(jbroot, &info) == 0, info.st_gid != 0 else { return nil }
        return info.st_gid
    }

    private static let anyDirectory = PreparedEntry(path: "", kind: .directory, mode: 0, uid: 0, gid: 0, modificationTime: 0)

    private static func directory(_ path: String, mode: UInt32, time: Int64) -> PreparedEntry {
        PreparedEntry(
            path: path,
            kind: .directory,
            mode: mode,
            uid: 0,
            gid: 0,
            userName: "root",
            groupName: "wheel",
            modificationTime: time
        )
    }

    /// Every path that has something listed below it, in bytes.
    private static func parents(of paths: [String]) -> Set<String> {
        var parents = Set<String>()
        for path in paths {
            var bytes = Substring(path).utf8
            while let slash = bytes.lastIndex(of: 0x2F), slash != bytes.startIndex {
                bytes = bytes[..<slash]
                guard parents.insert(String(decoding: bytes, as: UTF8.self)).inserted else { break }
            }
        }
        return parents
    }

    private func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private func linkText(at location: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = readlink(location.path, &buffer, Int(PATH_MAX))
        guard length >= 0 else { throw PackageFailure("Cannot read the link \(location.path)") }
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Members

    /// The data archive; answers the MD5 of every regular file and hard link
    /// by archive path.
    private func writeData(_ items: [Item], identity: String, to url: URL) throws -> [String: String] {
        let total = items.reduce(0) { $0 + $1.size }
        let writer = try DebianTarWriter(writingTo: url)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 18, alignment: 1)
        defer { buffer.deallocate() }
        var digests: [String: String] = [:]
        var completed: Int64 = 0
        var percent: Int64 = -1
        func report() {
            let current = total > 0 ? completed * 100 / total : 100
            if current != percent {
                percent = current
                emit(.packageProgress(identity: identity, completed: Int(completed), total: Int(total)))
            }
        }
        report()
        for item in items {
            try checkAbandoned()
            guard let location = item.location else {
                try writer.begin(item.entry)
                if item.entry.kind == .hardLink, let target = item.entry.linkTarget {
                    digests[item.entry.path] = digests[target]
                }
                continue
            }
            let file = open(location.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else {
                throw PackageFailure("Cannot read /\(item.entry.path): \(String(cString: strerror(errno)))")
            }
            defer { close(file) }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw PackageFailure("Cannot read /\(item.entry.path)")
            }
            try writer.begin(item.entry, size: Int64(info.st_size))
            var remaining = Int64(info.st_size)
            var digest = Insecure.MD5()
            while remaining > 0 {
                let count = read(file, buffer.baseAddress, min(buffer.count, Int(remaining)))
                if count < 0, errno == EINTR {
                    continue
                }
                guard count >= 0 else {
                    throw PackageFailure("Cannot read /\(item.entry.path): \(String(cString: strerror(errno)))")
                }
                guard count > 0 else { break }
                let bytes = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[..<count])
                digest.update(bufferPointer: bytes)
                try writer.write(bytes)
                remaining -= Int64(count)
                completed += Int64(count)
                report()
                try checkAbandoned()
            }
            digests[item.entry.path] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        try writer.finish()
        return digests
    }

    /// What dpkg recorded for each file: `md5sums`, and for a conffile, which
    /// that leaves out, the Conffiles field. Archive paths.
    private func recordedDigests(
        _ database: PackageDatabase,
        _ identity: String,
        fields: [String: String]
    ) throws -> [String: String] {
        var recorded: [String: String] = [:]
        for line in try infoText(database, identity, "md5sums")?.split(separator: "\n") ?? [] {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let path = try? PreparedPackage.relativePath(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            recorded[path] = String(parts[0])
        }
        for (path, digest) in try Conffiles(status: fields["conffiles"]).hashes {
            recorded[String(decoding: path.utf8.dropFirst(), as: UTF8.self)] = digest
        }
        return recorded
    }

    private func writeControl(
        _ identity: String,
        fields: [String: String],
        database: PackageDatabase,
        items: [Item],
        digests: [String: String],
        conffiles: Set<String>,
        time: Int64,
        to url: URL
    ) throws {
        var members: [String: Data] = [:]
        var record = fields
        for field in ["status", "conffiles", "config-version", "triggers-pending", "triggers-awaited"] {
            record[field] = nil
        }
        members["control"] = Data(PackageDatabase.paragraph(record, names: database.fieldNames[identity] ?? []).utf8)
        // regular files and hard links in the archive's order, conffiles left
        // out, as dpkg writes them for a package that ships none
        let sums = items.compactMap { item -> String? in
            guard let digest = digests[item.entry.path], !conffiles.contains("/" + item.entry.path) else { return nil }
            return digest + "  " + item.entry.path
        }
        // dpkg's copy is the original's own, order and all, while it says what
        // the archive holds
        if let recorded = try infoText(database, identity, "md5sums"),
           Set(recorded.split(separator: "\n").map(String.init)) == Set(sums)
        {
            members["md5sums"] = Data(recorded.utf8)
        } else {
            members["md5sums"] = Data(sums.map { $0 + "\n" }.joined().utf8)
        }
        // a conffile that is in no archive any more, deleted or taken over by
        // another package, and dpkg-deb refuses a package that declares one
        if let declared = try infoText(database, identity, "conffiles") {
            let archived = Set(items.map { "/" + $0.entry.path })
            let kept = declared.split(separator: "\n").filter { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                return text.hasPrefix("remove-on-upgrade ") || archived.contains(text)
            }
            if !kept.isEmpty {
                members["conffiles"] = Data((kept.joined(separator: "\n") + "\n").utf8)
            }
        }
        var modes: [String: UInt32] = [:]
        for member in try database.infoMembers(identity) where member != "list" && members[member] == nil {
            guard member != "conffiles" else { continue }
            let path = database.info(identity, member)
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            members[member] = try Data(contentsOf: path)
            modes[member] = UInt32(info.st_mode & 0o777)
        }
        let writer = try DebianTarWriter(writingTo: url)
        try writer.begin(Self.directory("", mode: 0o755, time: time))
        // control first, as dpkg-deb lists it, then by name
        for name in ["control"] + members.keys.filter({ $0 != "control" }).sorted() {
            try writer.add(
                PreparedEntry(
                    path: name,
                    kind: .file,
                    mode: modes[name] ?? 0o644,
                    uid: 0,
                    gid: 0,
                    userName: "root",
                    groupName: "wheel",
                    modificationTime: time
                ),
                contents: members[name] ?? Data()
            )
        }
        try writer.finish()
    }
}
