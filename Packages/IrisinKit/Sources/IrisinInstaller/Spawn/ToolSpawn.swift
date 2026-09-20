import Darwin
import Foundation
import IrisinProtocol

/// libSystem exports this on iOS; only the header marks it unavailable.
@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func spawnActionsAddChdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ path: UnsafePointer<CChar>
) -> Int32

/// One bootstrap tool, run to completion with its output read line by line.
///
/// The argv is whatever the caller composed and nothing else: there is no
/// shell here, no `PATH` lookup and no inherited environment. By default
/// standard output and standard error share one pipe so the transcript reads
/// in the order the tool wrote it; a caller that has to parse the output
/// asks for standard error on its own pipe instead.
public enum ToolSpawn {
    /// Blocks until the tool exits. Returns its exit status, or 128 plus the
    /// signal that killed it, the way a shell would. With `error` given,
    /// standard error is read on a thread of its own, so neither stream can
    /// fill its pipe and stall the tool while the other is being read.
    @discardableResult
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String? = nil,
        error: (@Sendable (String) -> Void)? = nil,
        output: (String) -> Void
    ) throws -> Int32 {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Failure(errno: errno) }
        let readEnd = descriptors[0]
        let writeEnd = descriptors[1]
        var errorDescriptors: [Int32] = [-1, -1]
        if error != nil {
            guard pipe(&errorDescriptors) == 0 else {
                let failure = Failure(errno: errno)
                close(readEnd)
                close(writeEnd)
                throw failure
            }
        }
        let errorReadEnd = errorDescriptors[0]
        let errorWriteEnd = errorDescriptors[1]
        func closeAll() {
            close(readEnd)
            close(writeEnd)
            if errorReadEnd >= 0 {
                close(errorReadEnd)
                close(errorWriteEnd)
            }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorWriteEnd >= 0 ? errorWriteEnd : writeEnd, STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        if let workingDirectory {
            let result = spawnActionsAddChdir(&actions, workingDirectory)
            guard result == 0 else {
                closeAll()
                throw Failure(errno: result)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        posix_spawnattr_setsigdefault(&attributes, &defaulted)
        var masked = sigset_t()
        sigemptyset(&masked)
        posix_spawnattr_setsigmask(&attributes, &masked)
        // Every descriptor this process holds stays here: the child gets its
        // three standard streams and nothing it could use to reach back.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )

        let argv = CStringArray(arguments)
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv.pointers, envp.pointers)
        guard spawned == 0 else {
            closeAll()
            throw Failure(errno: spawned)
        }
        close(writeEnd)
        if errorWriteEnd >= 0 {
            close(errorWriteEnd)
        }

        let errorDrained = DispatchSemaphore(value: 0)
        if let error {
            let reader = Thread {
                LineReader.read(descriptor: errorReadEnd, line: error)
                close(errorReadEnd)
                errorDrained.signal()
            }
            reader.start()
        }
        LineReader.read(descriptor: readEnd, line: output)
        close(readEnd)
        // Every standard error line is delivered before the status is.
        if error != nil {
            errorDrained.wait()
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return 128 }
        }
        return Self.exitStatus(status)
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }
}
