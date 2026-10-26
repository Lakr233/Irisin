import Darwin
import Foundation
import IrisinProtocol

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

        // Every descriptor this process holds stays here: the child gets its
        // three standard streams and nothing it could use to reach back.
        let pid: pid_t
        do {
            pid = try ProcessSpawn.spawn(
                executable,
                arguments: arguments,
                environment: environment.map { "\($0.key)=\($0.value)" },
                descriptors: [
                    .duplicate(writeEnd, as: STDOUT_FILENO),
                    .duplicate(errorWriteEnd >= 0 ? errorWriteEnd : writeEnd, as: STDERR_FILENO),
                    .open("/dev/null", flags: O_RDONLY, as: STDIN_FILENO),
                ],
                workingDirectory: workingDirectory
            )
        } catch {
            closeAll()
            throw Failure(errno: error.errno)
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
