import Darwin
import Foundation
import IrisinInstaller
import IrisinProtocol

// `irisin-install`: the process `irisind` starts for one job.
//
// One `InstallerJob` as JSON on standard input, the transcript as one
// `InstallerEvent` per line on standard output (`InstallerOutput`), and the
// exit status as the last event. It runs as whoever spawned it, root on a
// device, in a session of its own: the package it is installing may be this
// app, whose postinst restarts the daemon that started it and whose app is
// the one reading the pipe. Neither ending interrupts the transaction, and
// the transcript is also written, as timestamped plain text, to
// `IrisinWire.installerLogPath` so the relaunched app can show it.

// A reader that went away turns every write into EPIPE, which is ignored
// below; it must not become a signal that kills a half-finished job.
signal(SIGPIPE, SIG_IGN)

func writeAll(_ descriptor: Int32, _ data: Data) {
    guard descriptor >= 0 else { return }
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0, errno == EINTR {
                continue
            }
            guard written > 0 else { return }
            offset += written
        }
    }
}

func writeEvent(_ event: InstallerEvent) {
    writeAll(STDOUT_FILENO, Data((InstallerOutput.encode(event) + "\n").utf8))
}

guard let installRoot = ProcessPath.installRoot(ofCurrentProcessAt: IrisinWire.helperPath) else {
    // No log yet: there is no install root to keep one under. The pipe
    // still gets a proper ending.
    for event in [InstallerEvent.failure(.helperMisplaced), .exit(EX_CONFIG)] {
        writeEvent(event)
    }
    exit(EX_CONFIG)
}

let job = try? InstallerJob.decode(FileHandle.standardInput.readDataToEndOfFile())

/// A transaction starts a fresh log and keeps the one before it, because the
/// failure being investigated is usually the one before the retry. The
/// maintenance jobs append to the current log: a respring after an install
/// must not push that install's transcript out.
let logPath = installRoot + IrisinWire.installerLogPath
try? FileManager.default.createDirectory(
    atPath: (logPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true
)
let logDescriptor: Int32
if case .transaction = job {
    rename(logPath, logPath + ".previous")
    logDescriptor = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
} else {
    logDescriptor = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
}

let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
}()

/// The pipe gets the event; the log gets the time and the plain-text line.
func emit(_ event: InstallerEvent) {
    writeEvent(event)
    // a ring's hundred ticks are for the screen, not for the record
    if case .packageProgress = event {
        return
    }
    writeAll(logDescriptor, Data((clock.string(from: Date()) + " " + event.description + "\n").utf8))
}

guard let job else {
    emit(.failure(.invalidJob))
    emit(.exit(EX_DATAERR))
    exit(EX_DATAERR)
}

emit(.started(.init(job: job.name, uid: getuid(), installRoot: installRoot)))
let status = InstallerRunner(installRoot: installRoot, emit: emit).run(job)
emit(.exit(status))
exit(status)
