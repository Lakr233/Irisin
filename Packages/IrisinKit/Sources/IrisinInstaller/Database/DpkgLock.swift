import Darwin

/// POSIX record locks are what dpkg/apt use. Never unlink a lock file: doing
/// so would let another process lock a different inode for the same database.
final class DpkgLock {
    private var descriptor: Int32

    init(path: String) throws {
        descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o640)
        guard descriptor >= 0 else { throw ToolSpawn.Failure(errno: errno) }
        var record = flock()
        record.l_type = Int16(F_WRLCK)
        record.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_SETLK, &record) != -1 else {
            let error = errno
            Darwin.close(descriptor)
            descriptor = -1
            throw ToolSpawn.Failure(errno: error)
        }
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor); descriptor = -1
        }
    }

    deinit { close() }
}
