import Darwin
import Foundation

/// A removed bundle may retain empty directories and RootHide's runtime links
/// beside former executables. Never follow those links or recursively delete
/// arbitrary contents: only unlink `.jbroot` symlinks and remove empty folders.
enum RemovedApplicationBundle {
    static func isGone(_ path: String) throws -> Bool {
        try inspect(path, removing: false)
    }

    static func removeHusk(_ path: String) throws {
        guard try inspect(path, removing: false), try inspect(path, removing: true) else {
            throw PackageFailure("The app bundle still contains files: \(path)")
        }
    }

    private static func inspect(_ path: String, removing: Bool) throws -> Bool {
        let url = URL(fileURLWithPath: path)
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else {
            if errno == ENOENT {
                return true
            }
            throw posixError()
        }
        defer { close(parent) }
        return try inspect(parent: parent, name: url.lastPathComponent, removing: removing, depth: 0)
    }

    private static func inspect(parent: Int32, name: String, removing: Bool, depth: Int) throws -> Bool {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return true
            }
            throw posixError()
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return false }
        guard depth < 128 else { throw POSIXError(.ELOOP) }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw posixError(code)
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw posixError() }
                break
            }
            let child = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if child == "." || child == ".." {
                continue
            }
            guard fstatat(descriptor, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posixError()
            }
            if child == ".jbroot", info.st_mode & S_IFMT == S_IFLNK {
                if removing, unlinkat(descriptor, child, 0) != 0 {
                    throw posixError()
                }
            } else if info.st_mode & S_IFMT == S_IFDIR {
                guard try inspect(parent: descriptor, name: child, removing: removing, depth: depth + 1)
                else { return false }
            } else {
                return false
            }
        }
        if removing, unlinkat(parent, name, AT_REMOVEDIR) != 0 {
            throw posixError()
        }
        return true
    }

    /// The default reads `errno` at the call, so a throw reports the call that just failed.
    private static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
