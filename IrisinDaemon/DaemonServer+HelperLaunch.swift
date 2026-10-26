import Darwin
import Foundation
import IrisinProtocol

extension DaemonServer {
    /// Starts `irisin-install`: argv of exactly itself, an empty environment,
    /// the job as JSON on standard input, and one pipe for everything it
    /// prints. Returns the read end of that pipe.
    static func startHelper(at helper: String, job: InstallerJob) throws -> Int32 {
        var output: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw IrisinFailure(errno: errno) }
        do {
            try spawnHelper(at: helper, job: job, standardOutput: output[1], package: nil)
        } catch {
            close(output[0]); close(output[1])
            throw error
        }
        close(output[1])
        return output[0]
    }

    /// Starts `irisin-install` the same way for an external transaction:
    /// everything it prints goes to `standardOutput` (the transaction's
    /// journal), and `package`, when there is one, is its descriptor 3. The
    /// caller keeps and closes both of its own descriptors.
    static func spawnHelper(at helper: String, job: InstallerJob, standardOutput: Int32, package: Int32?) throws {
        var info = stat()
        guard stat(helper, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0
        else {
            throw IrisinFailure(code: .notFound, systemError: ENOENT, path: helper)
        }
        let payload = try job.encoded()

        var input: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { throw IrisinFailure(errno: errno) }

        var descriptors: [ProcessSpawn.Descriptor] = [
            .duplicate(input[0], as: STDIN_FILENO),
            .duplicate(standardOutput, as: STDOUT_FILENO),
            .duplicate(standardOutput, as: STDERR_FILENO),
        ]
        if let package {
            descriptors.append(.duplicate(package, as: InstallerJob.External.packageDescriptor))
        }
        // A session of its own: launchd tearing this daemon down (which the
        // package being installed may ask for in its postinst) does not take
        // the install down with it.
        do {
            _ = try ProcessSpawn.spawn(
                helper,
                arguments: [helper],
                environment: [],
                descriptors: descriptors,
                newSession: true
            )
        } catch {
            close(input[0])
            close(input[1])
            throw IrisinFailure(errno: error.errno, path: helper)
        }
        close(input[0])

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
    }
}
