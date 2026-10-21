import Darwin
import Foundation

/// Why another process's catalogue was not opened: one of its files is not
/// there, is not a file, or belongs to someone else.
public struct CatalogueUnavailable: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case missing
        case notRegularFile
        /// owned by this uid, not the catalogue's owner
        case owner(uid_t)
        case unreadable(errno: Int32)
    }

    /// the file's path
    public let file: String
    public let reason: Reason
}

public extension PackageIndex {
    /// The catalogue another process keeps in `directory`, for a reader that
    /// must change nothing there: a root process reading mobile's, whose
    /// files the app could not change again once root had made them.
    ///
    /// The database and the `-wal` and `-shm` files beside it must exist,
    /// be regular files and be `owner`'s, or nothing is opened: SQLite
    /// makes a missing `-wal` and `-shm` itself, read-only or not, and
    /// they would be the reader's. Should the writer close in between and
    /// take the two with it, a file the open left in the directory is
    /// handed to the owner of the database before this returns.
    ///
    /// For a process that never opens the same file to write: WCDB keeps
    /// one core per file in a process, so this would make that process's
    /// writable handle read-only too. None of the centers is touched for
    /// that reason, and the caller's `AptEnvironment` should not name this
    /// folder as its working location. The update preferences are the
    /// caller's to fill (`restoreUpdatePreferences(from:)`).
    static func readOnly(in directory: URL, owner: uid_t) throws -> PackageIndex {
        let url = directory.appendingPathComponent(AptDatabase.fileName)
        let files = [url.path, url.path + "-wal", url.path + "-shm"]
        for file in files {
            try checkCatalogueFile(file, owner: owner)
        }
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        let db = AptDatabase(readingAt: url)
        // WCDB opens on the first statement; this is it
        _ = try db.resolutionRevision()
        handBack(directory: directory, before: before, to: url.path)
        for file in files {
            try checkCatalogueFile(file, owner: owner)
        }
        return PackageIndex(db: db)
    }

    /// What the user said about updates, from the storage the center keeps
    /// it in: what a process without `PackageCenter` sets before it solves.
    mutating func restoreUpdatePreferences(from storage: any AptStorage) {
        func value<Value: Decodable>(_ key: String, _ fallback: Value) -> Value {
            storage.read(key: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? fallback
        }
        blockedUpdateTable = value(UpdatePreferenceKey.blockedUpdates, [])
        offersAdaptedUpdates = value(UpdatePreferenceKey.offersAdaptedUpdates, false)
    }

    /// Every repository the catalogue lists.
    func obtainRepositories() -> [Repository] {
        db.repositories()
    }

    private static func checkCatalogueFile(_ path: String, owner: uid_t) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let error = errno
            throw CatalogueUnavailable(file: path, reason: error == ENOENT ? .missing : .unreadable(errno: error))
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw CatalogueUnavailable(file: path, reason: .notRegularFile)
        }
        guard info.st_uid == owner else {
            throw CatalogueUnavailable(file: path, reason: .owner(info.st_uid))
        }
    }

    /// An entry the open made in `directory` goes to the database's owner
    /// and group, never through a link. Only root can make it another's,
    /// and only root needs to: anyone else made it their own, the owner's.
    private static func handBack(directory: URL, before: Set<String>, to database: String) {
        guard geteuid() == 0 else { return }
        var owner = stat()
        guard stat(database, &owner) == 0,
              let after = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in after where !before.contains(name) {
            let path = directory.appendingPathComponent(name).path
            guard lchown(path, owner.st_uid, owner.st_gid) == 0 else {
                aptLog(Self.self, "could not hand \(path) back to uid \(owner.st_uid): errno \(errno)", level: .error)
                continue
            }
            aptLog(Self.self, "handed \(path), made by the read-only open, back to uid \(owner.st_uid)", level: .warning)
        }
    }
}
