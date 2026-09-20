import Darwin
import Foundation
import IrisinProtocol

extension DaemonServer {
    /// Starts `irisin-install`: argv of exactly itself, an empty environment,
    /// the job as JSON on standard input, and one pipe for everything it
    /// prints. Returns the read end of that pipe.
    static func startHelper(at helper: String, job: InstallerJob) throws -> Int32 {
        var info = stat()
        guard stat(helper, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            throw IrisinFailure(code: .notFound, systemError: ENOENT, path: helper)
        }
        let payload = try job.encoded()

        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { throw IrisinFailure(errno: errno) }
        guard pipe(&output) == 0 else {
            close(input[0]); close(input[1])
            throw IrisinFailure(errno: errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        var masked = sigset_t()
        sigemptyset(&masked)
        posix_spawnattr_setsigmask(&attributes, &masked)
        // `POSIX_SPAWN_SETSID`: the helper gets a session of its own, so launchd
        // tearing this daemon down (which the package being installed may ask
        // for in its postinst) does not take the install down with it.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSID)
        )

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(helper), nil]
        defer { free(argv[0]) }
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, helper, &actions, &attributes, &argv, &envp)
        close(input[0])
        close(output[1])
        guard spawned == 0 else {
            close(input[1])
            close(output[0])
            throw IrisinFailure(errno: spawned, path: helper)
        }

        // The whole job, then EOF: the helper reads its standard input to the
        // end before doing anything. A job is a few kilobytes at most.
        payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(input[1], bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { break }
                offset += written
            }
        }
        close(input[1])
        return output[0]
    }
}
