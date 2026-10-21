import Darwin
import Dispatch
import Foundation
import IrisinClient
import IrisinProtocol
import notify

/// Sends one job through irisind and prints its transcript. The helper runs
/// in a session of its own: whatever happens to irisin-cli, the job ends,
/// and its account is in `irisin-install.log`.
struct Runner {
    /// What a running app listens for to read the installed list again.
    static let packagesChanged = "wiki.qaq.irisin.packages-changed"

    let context: Context
    let output: Output

    func run(_ job: InstallerJob) async throws {
        await waitForLock()
        let link = DaemonLink(daemonIsInstalled: true)
        let transcript = try await start(job, on: link)
        let interrupt = Self.announceInterrupt(log: context.shellPath(context.logFile))
        defer { interrupt.cancel() }
        let output = output
        let status = await transcript.collect { event in
            Self.print(event, output)
        }
        link.invalidate()
        notify_post(Self.packagesChanged)
        guard let status else {
            throw CommandFailure.unavailable("The helper stopped without finishing. See \(context.shellPath(context.logFile)).")
        }
        output.object(["exit": Int(status)])
        guard status == 0 else {
            throw CommandFailure.transaction(status: status)
        }
    }

    /// irisind is on demand: launchd starts it at the first lookup, and a
    /// daemon replaced a moment ago takes a moment to answer again.
    private func start(_ job: InstallerJob, on link: DaemonLink) async throws -> JobTranscript {
        let deadline = Date().addingTimeInterval(15)
        while true {
            do {
                return try await link.run(job)
            } catch let failure as IrisinFailure where failure.code != .operationFailed {
                // an answer, not a silence: the daemon read the job and refused it
                throw CommandFailure.refused("Irisin's service refused the job (code \(failure.code), errno \(failure.systemError)).")
            } catch {
                guard Date() < deadline else {
                    throw CommandFailure.unavailable("Irisin's service did not answer. Reinstall Irisin, or reboot and try again.")
                }
                link.invalidate()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// The helper takes dpkg's frontend lock for the whole run and refuses
    /// to start beside a holder; this asks who holds it, and never takes it.
    private func waitForLock() async {
        let path = context.path("/Library/dpkg/lock-frontend")
        var announced = false
        while let holder = Self.lockHolder(path) {
            if !announced {
                output.note("Waiting for another operation (process \(holder)) to finish…")
                announced = true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    static func lockHolder(_ path: String) -> pid_t? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var record = flock()
        record.l_type = Int16(F_WRLCK)
        record.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &record) == 0, record.l_type != Int16(F_UNLCK) else { return nil }
        return record.l_pid
    }

    /// Ctrl-C leaves the job to the helper and says where to follow it.
    private static func announceInterrupt(log: String) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            FileHandle.standardError.write(Data("\nirisin-cli stopped; the transaction goes on in Irisin's helper. Its account is in \(log).\n".utf8))
            exit(130)
        }
        source.resume()
        return source
    }

    private static func print(_ event: InstallerEvent, _ output: Output) {
        if output.json {
            if let data = try? JSONEncoder().encode(event),
               let object = try? JSONSerialization.jsonObject(with: data)
            {
                output.object(["event": object, "text": event.description])
            }
            return
        }
        // the files placed within a step are the screen's, as on the app's
        if case .packageProgress = event { return }
        output.line(event.description)
    }
}
