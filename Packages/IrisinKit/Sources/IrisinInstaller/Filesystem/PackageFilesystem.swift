import Darwin
import Foundation
import IrisinProtocol

/// Maps archive paths into the bootstrap and prevents writes through escaping
/// parent symlinks. Leaf symlinks are replaced, never followed when writing.
/// Every path it hands out has its parent directories resolved
/// (`physicalPath`).
final class PackageFilesystem {
    /// The journal's list of backups, inside each transaction's directory.
    private static let recordName = "files.json"
    /// The kernel's `MAXSYMLINKS`.
    private static let linkLimit = 32

    let root: URL
    let layout: BootstrapLayout
    private let database: URL
    /// Where a package's files may physically land: the root, and under
    /// roothide the jbroot's `/var`, which the jailbreak keeps in an app
    /// group container and links to from `private/var`.
    private let storage: [String]
    private var backups: [PackageFileBackup] = []
    /// Where each destination is in `backups`, so that neither lookup below
    /// walks the list: a theme's four thousand files made both quadratic.
    private var places: [URL: Int] = [:]
    /// The directories `ensureDirectory` has seen to.
    private var ensured = Set<URL>()
    /// The last directory `location` walked, and what it led to.
    private var lastDirectory: (directory: String, physical: String)?
    private let journal: URL
    /// Kept open for the whole run, since every record is appended to it.
    private var handle: FileHandle?

    init(root: URL, layout: BootstrapLayout, database: URL) throws {
        let rootPath = Self.physicalPath(root.path, followingLast: true, layout: layout) ?? root.path
        self.root = URL(fileURLWithPath: rootPath)
        self.layout = layout
        self.database = URL(
            fileURLWithPath: Self.physicalPath(database.path, followingLast: true, layout: layout) ?? database.path
        )
        var storage = [rootPath]
        if case .roothide = layout.kind,
           let variable = Self.physicalPath(rootPath + "/private/var", followingLast: true, layout: layout)
        {
            storage.append(variable)
        }
        self.storage = storage
        journal = database.appendingPathComponent("irisin-journal").appendingPathComponent(UUID().uuidString)
    }

    func recover() throws {
        let directory = journal.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let interrupted = directory.appendingPathComponent(name)
            let record = interrupted.appendingPathComponent(Self.recordName)
            guard exists(record) else { continue }
            let saved = try Self.journalRecords(Data(contentsOf: record))
            backups = try saved.map { backup in
                // a journal spells a destination the way its own run did
                guard let path = physical(backup.destination.path, followingLast: false),
                      contains(path) || path.hasPrefix(database.path + "/info/")
                else { throw PackageFailure("Invalid recovery destination") }
                if let copy = backup.saved, copy.deletingLastPathComponent() != interrupted {
                    throw PackageFailure("Invalid recovery backup")
                }
                return PackageFileBackup(
                    destination: URL(fileURLWithPath: path),
                    saved: backup.saved,
                    installed: backup.installed,
                    removed: backup.removed
                )
            }
            places = Dictionary(backups.enumerated().map { ($1.destination, $0) }, uniquingKeysWith: { _, last in last })
            try rollback(interrupted: true)
            try FileManager.default.removeItem(at: interrupted)
        }
    }

    /// Where `path` leads once every symbolic link on the way is followed,
    /// the last one only when `followingLast`, in the kernel's spelling.
    /// What does not exist is kept as written. Nil when the links loop.
    ///
    /// The kernel follows the links the same way everywhere but in the
    /// simulator, whose links say `/var/jb` for a mount the Mac does not
    /// have. ElleKit's `Library/MobileSubstrate/DynamicLibraries` is such a
    /// link, and every tweak installed after it failed there.
    /// `under` is a path already known to have no link of its own: its
    /// components are taken as resolved and the kernel is not asked about
    /// them again. Every file a package ships is resolved under the root,
    /// whose own components were walked once, when this was made.
    static func physicalPath(
        _ path: String,
        followingLast: Bool,
        layout: BootstrapLayout,
        under base: String = "/"
    ) -> String? {
        /// split at every `/` byte, as the kernel splits: `String` would take
        /// one with a combining mark after it for a character of a name
        func components(_ path: String) -> [String] {
            path.utf8.split(separator: 0x2F).map { String(decoding: $0, as: UTF8.self) }
        }
        var pending = Array(components(path).reversed())
        var resolved = components(base)
        var missing = false
        var links = 0
        while let component = pending.popLast() {
            if component == "." {
                continue
            }
            if component == ".." {
                _ = resolved.popLast()
                continue
            }
            resolved.append(component)
            // nothing below a missing directory is a link
            guard !missing, followingLast || !pending.isEmpty else { continue }
            let current = "/" + resolved.joined(separator: "/")
            var info = stat()
            guard lstat(current, &info) == 0 else {
                missing = true
                continue
            }
            guard info.st_mode & S_IFMT == S_IFLNK else { continue }
            links += 1
            guard links <= linkLimit,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: current)
            else { return nil }
            resolved.removeLast()
            if target.utf8.first == 0x2F {
                resolved.removeAll()
            }
            pending += components(layout.linkedPath(target)).reversed()
        }
        return "/" + resolved.joined(separator: "/")
    }

    func physical(_ path: String, followingLast: Bool) -> String? {
        Self.physicalPath(path, followingLast: followingLast, layout: layout)
    }

    /// Whether a physical path is where a package's files may be.
    func contains(_ path: String) -> Bool {
        root.path == "/" || storage.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// What is at the path now, in the terms `PackageFileBackup.installed`
    /// records: the content's digest, a link's target, nil when nothing.
    private func fingerprint(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return try? PackageArchive.digest(url, md5: false)
        case S_IFLNK: return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map { "link:" + $0 }
        default: return "other"
        }
    }

    private func note(_ url: URL, installed: String?, removed: Bool) throws {
        guard let place = places[url] else { return }
        backups[place].installed = installed
        backups[place].removed = removed
        try append(place)
    }

    /// One record to the end of the journal, its place in the list with it.
    /// Rewriting the whole list for every file, as this did, cost a theme's
    /// four thousand entries a re-encode of everything before them and four
    /// fsyncs each — ten minutes of an iPad's time for a 22 MB package.
    ///
    /// Nothing is flushed: the journal is read by the *next* run, and a
    /// helper that was killed leaves its writes in the page cache all the
    /// same. What a panic or a power loss leaves behind is what dpkg leaves,
    /// a package the status file calls half-installed — and that file is
    /// written whole and synchronized, as dpkg writes it.
    private func append(_ place: Int) throws {
        if handle == nil {
            let path = journal.appendingPathComponent(Self.recordName).path
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
            else { throw PackageFailure("Cannot open the recovery journal") }
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        }
        // a JSON string escapes its newlines, so one record is one line
        try handle?.write(contentsOf: JSONEncoder().encode(JournalRecord(at: place, backup: backups[place])) + [0x0A])
    }

    /// The journal's lines, the last one for a place winning, in their order.
    /// A final line cut short is the run that was killed while appending it;
    /// a damaged line before the end is something else having written to the
    /// file, and then no destination can be accounted for.
    ///
    /// The places present are always `0...n`: a place's first line is
    /// appended by `backup`, before any higher place exists. So the array
    /// index of a record is its place, which is what `recover` counts on
    /// when it rebuilds `places` from the list's own order.
    private static func journalRecords(_ data: Data) throws -> [PackageFileBackup] {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var saved: [Int: PackageFileBackup] = [:]
        for (number, line) in lines.enumerated() {
            guard let record = try? JSONDecoder().decode(JournalRecord.self, from: Data(line)) else {
                guard number == lines.count - 1 else { throw PackageFailure("Damaged recovery journal") }
                break
            }
            saved[record.at] = record.backup
        }
        return saved.sorted { $0.key < $1.key }.map(\.value)
    }

    /// A caller that wrote a backed-up destination itself says so, so a
    /// replay knows what it put there.
    func noteWritten(_ url: URL) throws {
        try note(url, installed: fingerprint(url), removed: false)
    }

    func noteRemoved(_ url: URL) throws {
        try note(url, installed: nil, removed: true)
    }

    /// Directories an archive names that this installer does not own: a
    /// rootless archive's ancestors of the prefix, such as /var, and under
    /// roothide the `/rootfs` bridge, whose directories are the untouched iOS
    /// filesystem's own — roothide's own PatchLoader ships `/rootfs/var`.
    /// They describe the tar layout, not files to create or remove outside
    /// jbroot. A *file* there is still refused: the callers that know an
    /// entry's kind ask this only about a directory.
    func isScaffolding(_ path: String) -> Bool {
        switch layout.kind {
        case .none: false
        case let .rootless(prefix): path == prefix || prefix.hasPrefix(path + "/")
        case .roothide: path == "/rootfs" || path.hasPrefix("/rootfs/")
        }
    }

    func location(_ path: String) throws -> URL {
        let destination = try resolvedLocation(path)
        guard !isInDatabase(destination) else {
            throw PackageFailure("Package data cannot overwrite the package database")
        }
        return destination
    }

    /// Resolves an archive entry without letting package data become dpkg's
    /// own records. dpkg packages the administrative directories themselves;
    /// a directory there is shared scaffolding, while every other entry kind
    /// remains forbidden.
    func location(_ path: String, for entry: PreparedEntry) throws -> URL {
        let destination = try resolvedLocation(path)
        guard !isInDatabase(destination) || entry.kind == .directory else {
            throw PackageFailure("Package data cannot overwrite the package database")
        }
        return destination
    }

    /// Package lists have no entry kinds. A database path they record is
    /// protected scaffolding during removal, never payload to delete.
    func isPackageDatabasePath(_ path: String) throws -> Bool {
        try isInDatabase(resolvedLocation(path))
    }

    private func isInDatabase(_ url: URL) -> Bool {
        url.path == database.path || url.path.hasPrefix(database.path + "/")
    }

    private func resolvedLocation(_ path: String) throws -> URL {
        // in bytes, as the kernel reads it: a combining mark after a `/` is
        // one character with it
        guard path.utf8.first == 0x2F else { throw PackageFailure("Package path must be absolute: \(path)") }
        var relative = String(decoding: path.utf8.dropFirst(), as: UTF8.self)
        if case let .rootless(prefix) = layout.kind {
            guard path.utf8.starts(with: "\(prefix)/".utf8) else {
                throw PackageFailure("Package path is outside the bootstrap: \(path)")
            }
            relative = String(decoding: path.utf8.dropFirst(prefix.utf8.count + 1), as: UTF8.self)
        }
        guard try PreparedPackage.relativePath(relative) == relative, !relative.isEmpty else {
            throw PackageFailure("Invalid package pathname")
        }
        // The walk is of the directory the entry is in; the entry itself is
        // appended, never followed. Asking for the same directory again is
        // free: a package's entries arrive sorted, so a theme's thousands
        // of icons name the same one in a row, and each walk of it crosses
        // the jbroot's own `var` into the app group container a dozen calls
        // deep. Nothing written here can change that answer — a write lands
        // at the entry's own path, never at a component of the directory
        // holding it — and the two that could, a link installed or removed,
        // drop it, as does `finish` before any maintainer script runs.
        let directory = (relative as NSString).deletingLastPathComponent
        let physical: String
        if let known = lastDirectory, known.directory == directory {
            physical = known.physical
        } else {
            guard let walked = Self.physicalPath(directory, followingLast: true, layout: layout, under: root.path) else {
                throw PackageFailure("Package path runs through a symbolic link loop: \(path)")
            }
            lastDirectory = (directory, walked)
            physical = walked
        }
        let result = physical + "/" + (relative as NSString).lastPathComponent
        guard contains(physical) else {
            throw PackageFailure("Package path traverses a symlink outside the bootstrap: \(path)")
        }
        return URL(fileURLWithPath: result)
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Forgets what `location` remembers of the tree's shape. Anything that
    /// may have turned a directory into a link says so here; a maintainer
    /// script always does (`MaintainerScripts.forgetPaths`).
    func forgetPaths() {
        lastDirectory = nil
    }

    /// A file into place the way the filesystem can do it: an APFS clone
    /// shares the source's blocks and costs one call, where a copy writes
    /// every byte again — a theme is twenty-two megabytes of them, and they
    /// were being written twice, into the helper's own directory and then
    /// into place. `CLONE_NOFOLLOW` keeps a symbolic link a link, as
    /// `copyItem` does. A volume or a filesystem that cannot clone, the
    /// simulator's included, gets the copy.
    /// A rootless bootstrap is its own volume — `/var/jb` leads to the
    /// preboot one, where the app's prepared tree cannot be cloned at all —
    /// so the copy is the path that still runs, not a corner of one.
    static func clone(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 {
            return
        }
        // a clone that gave up partway through a tree leaves what it had
        // made by then; the copy must not meet it. Every caller names a
        // destination of its own that nothing else has written.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// The contents on stable storage before the name that publishes them,
    /// as dpkg synchronizes a `.dpkg-new` before renaming it: a crash then
    /// leaves the old file or the whole new one, never a name over bytes
    /// that never landed. This ran *after* the rename, which buys that
    /// guarantee for nothing, and `fsync` waits for a filesystem commit per
    /// file — most of a theme's time. A barrier only orders the two, which
    /// is all the rename needs; a filesystem without one gets the wait.
    private static func synchronize(_ url: URL, naming path: String) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw PackageFailure("Cannot synchronize installed file: \(path)")
        }
        defer { close(descriptor) }
        if fcntl(descriptor, F_BARRIERFSYNC) == 0 {
            return
        }
        guard fsync(descriptor) == 0 else {
            throw PackageFailure("Cannot synchronize installed file: \(path)")
        }
    }

    /// Directories this run has already made. Asking the filesystem for the
    /// parent of every file a package ships walks and stats the whole chain
    /// each time, and a theme's four thousand icons share a handful of
    /// directories.
    private func ensureDirectory(_ url: URL) throws {
        guard ensured.insert(url).inserted else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func backup(_ url: URL) throws {
        guard places[url] == nil else { return }
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let saved = journal.appendingPathComponent(String(backups.count))
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT != S_IFDIR else {
                throw PackageFailure("Cannot replace directory with file: \(url.path)")
            }
            try Self.clone(url, to: saved)
            // a clone never carries setuid or setgid over, and a rollback
            // has to put the file back as it was — Procursus ships setuid
            // `sudo`, `su` and `ping`. The kind is already in hand, and it
            // is a file: `chmod` would follow a cloned link.
            if info.st_mode & S_IFMT == S_IFREG, chmod(saved.path, info.st_mode & 0o7777) != 0 {
                throw PackageFailure("Cannot save the file's permissions: \(url.path)")
            }
            backups.append(.init(destination: url, saved: saved))
        } else {
            backups.append(.init(destination: url, saved: nil))
        }
        places[url] = backups.count - 1
        try append(backups.count - 1)
    }

    func install(
        _ entry: PreparedEntry,
        from archive: PackageArchive,
        at destination: URL,
        hardLinkTarget: URL? = nil,
        mode: UInt32? = nil,
        owner: (UInt32, UInt32)? = nil
    ) throws {
        if entry.kind == .directory {
            // dpkg asks stat, not lstat: a symbolic link to a directory is
            // the directory, and the bootstrap is built from such links
            if isDirectory(destination) {
                return
            }
            guard !exists(destination) else {
                throw PackageFailure("Directory collides with a file: \(entry.path)")
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            ensured.insert(destination)
        } else {
            if keepsDirectory(entry, at: destination) {
                return
            }
            try ensureDirectory(destination.deletingLastPathComponent())
            try backup(destination)
            let temporary = destination.appendingPathExtension("irisin-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            var installed: String?
            switch entry.kind {
            case .file:
                try Self.clone(archive.content(entry.file!), to: temporary)
                installed = entry.file!.sha256
            case .symbolicLink:
                let text = layout.linkText(entry.linkTarget!)
                try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: text)
                installed = "link:" + text
                lastDirectory = nil
            case .hardLink:
                guard let target = hardLinkTarget else {
                    throw PackageFailure("Missing resolved hard link target")
                }
                guard link(target.path, temporary.path) == 0 else {
                    throw PackageFailure("Cannot create hard link: \(entry.path)")
                }
                installed = try? PackageArchive.digest(target, md5: false)
            case .directory: break
            }
            if entry.kind != .symbolicLink {
                try Self.synchronize(temporary, naming: entry.path)
            }
            guard rename(temporary.path, destination.path) == 0 else {
                throw PackageFailure("Cannot install file: \(entry.path)")
            }
            try note(destination, installed: installed, removed: false)
        }
        let uid = owner?.0 ?? entry.uid
        let gid = owner?.1 ?? entry.gid
        if geteuid() == 0, lchown(destination.path, uid, gid) != 0 {
            throw PackageFailure("Cannot set file ownership: \(entry.path)")
        }
        if entry.kind != .symbolicLink {
            guard chmod(destination.path, mode_t(mode ?? entry.mode)) == 0 else {
                throw PackageFailure("Cannot set permissions: \(entry.path)")
            }
            // the archive's time, the one the filesystem keeps: asking
            // Foundation for it reads the file's attributes first, and the
            // access time is nobody's here
            var times = [
                timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                timespec(tv_sec: Int(entry.modificationTime), tv_nsec: 0),
            ]
            guard utimensat(AT_FDCWD, destination.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw PackageFailure("Cannot set the modification time: \(entry.path)")
            }
        }
    }

    func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard let path = physical(url.path, followingLast: true) else { return false }
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// dpkg keeps what is at the path where the archive has a symbolic link
    /// and the path is a directory, or a link to the directory the new link
    /// names: the contents are reachable either way. The path is then no
    /// other package's to give up, so neither Replaces nor a takeover applies.
    func keepsDirectory(_ entry: PreparedEntry, at destination: URL) -> Bool {
        guard entry.kind == .symbolicLink, let target = entry.linkTarget else { return false }
        var info = stat()
        guard lstat(destination.path, &info) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return true
        case S_IFLNK:
            let proposed = target.hasPrefix("/")
                ? layout.linkedPath(layout.linkText(target))
                : destination.deletingLastPathComponent().path + "/" + target
            var old = stat()
            var new = stat()
            guard let current = physical(destination.path, followingLast: true),
                  let named = physical(proposed, followingLast: true),
                  stat(current, &old) == 0, old.st_mode & S_IFMT == S_IFDIR,
                  stat(named, &new) == 0, new.st_mode & S_IFMT == S_IFDIR
            else { return false }
            return old.st_dev == new.st_dev && old.st_ino == new.st_ino
        default:
            return false
        }
    }

    /// Removes the file, or the directory when it is empty. Answers whether
    /// a directory stayed because it still has contents, which dpkg keeps
    /// in the package's list to retry later.
    @discardableResult
    func remove(_ url: URL) throws -> Bool {
        // whatever an interrupted dpkg left beside the path goes with it
        for suffix in ["dpkg-tmp", "dpkg-new"] {
            let leftover = url.appendingPathExtension(suffix)
            if exists(leftover), !isDirectory(leftover) {
                try backup(leftover)
                try FileManager.default.removeItem(at: leftover)
                try note(leftover, installed: nil, removed: true)
            }
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        // The bootstrap is built from links to directories, and the jbroot's
        // own `var` is one: what it points at holds every package's state.
        // `install` leaves such a link alone where a package lists the
        // directory (above, and `keepsDirectory`), so removal leaves it too
        // and keeps it in the list. dpkg unlinks it, and a roothide package
        // that names `/var` — every package an adapter rewrites does, for
        // the mirror under it — would take the bootstrap with it the moment
        // no other installed package happens to name `/var` as well. What
        // this costs is a link a package shipped itself staying behind.
        if info.st_mode & S_IFMT == S_IFLNK, isDirectory(url) {
            return true
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            ensured.remove(url)
            if rmdir(url.path) != 0 {
                guard errno == ENOTEMPTY || errno == EEXIST else {
                    throw PackageFailure("Cannot remove directory")
                }
                return true
            }
        } else {
            if info.st_mode & S_IFMT == S_IFLNK {
                lastDirectory = nil
            }
            try backup(url)
            try FileManager.default.removeItem(at: url)
            try note(url, installed: nil, removed: true)
        }
        return false
    }

    func finish() throws {
        try? handle?.close()
        handle = nil
        if FileManager.default.fileExists(atPath: journal.path) {
            try FileManager.default.removeItem(at: journal)
        }
        backups.removeAll()
        places.removeAll()
        ensured.removeAll()
        lastDirectory = nil
    }

    /// Puts every destination back. Replaying a journal another process
    /// left (`interrupted`), a destination is only restored while it still
    /// holds what that transaction put there.
    func rollback(interrupted: Bool = false) throws {
        for backup in backups.reversed() {
            let destination = backup.destination
            if interrupted {
                if backup.removed, exists(destination) {
                    continue
                }
                if let installed = backup.installed, fingerprint(destination) != installed {
                    continue
                }
            }
            guard let saved = backup.saved else {
                var info = stat()
                if lstat(destination.path, &info) == 0 {
                    guard info.st_mode & S_IFMT != S_IFDIR else {
                        throw PackageFailure("Recovery cannot replace a directory: \(destination.path)")
                    }
                    try FileManager.default.removeItem(at: destination)
                }
                continue
            }
            // Prepare the replacement first. A missing backup or failed copy
            // must not destroy the only remaining contents at the destination.
            // The run may have removed the directory it was in, once empty.
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let temporary = destination.appendingPathExtension("irisin-restore-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Self.clone(saved, to: temporary)
            // the copy aside kept the file's own bits (`backup`), and this
            // clone of it drops setuid and setgid again
            var kept = stat()
            if lstat(saved.path, &kept) == 0, kept.st_mode & S_IFMT == S_IFREG,
               chmod(temporary.path, kept.st_mode & 0o7777) != 0
            {
                throw PackageFailure("Cannot restore the file's permissions: \(destination.path)")
            }
            guard rename(temporary.path, destination.path) == 0 else {
                throw PackageFailure("Cannot restore file: \(destination.path)")
            }
        }
        try finish()
    }
}
