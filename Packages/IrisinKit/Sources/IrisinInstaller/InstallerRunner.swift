import Darwin
import Foundation
import IrisinProtocol

/// What `irisin-install` does with a job, as root.
///
/// A transaction is carried out natively by `PackageInstaller`; the
/// app bundles it added or removed are then told to LaunchServices through
/// icli, linked in as a library (`ApplicationRegistrar`). The maintenance jobs are the
/// same registrar (rebuild, respring) or a signal sent from this process
/// (`ProcessTable`). Nothing the app sent is ever an argv element on its own
/// authority; identities and package paths are validated by `InstallerJob`
/// before they get here and respelled by `BootstrapLayout` on the way out.
///
/// Every bundle path handed to icli is the kernel path from
/// `layout.resolve`, spelled the same way whether it is being registered or
/// unregistered: icli matches LaunchServices records by path.
public final class InstallerRunner {
    private let installRoot: String
    private let layout: BootstrapLayout
    private let emit: (InstallerEvent) -> Void
    private let registrar: ApplicationRegistrar
    private let daemonManager: LaunchDaemon
    /// `ProcessTable.signal`, except in the harness: a Mac running a
    /// simulator has a backboardd of its own that a test must not touch.
    private let signalProcesses: (String, Int32) -> Int

    public convenience init(
        installRoot: String,
        layout: BootstrapLayout? = nil,
        emit: @escaping (InstallerEvent) -> Void
    ) {
        #if targetEnvironment(simulator)
            // The simulator shares the Mac's process table: a real signal
            // would reach the host's sharingd and every booted simulator's
            // SpringBoard. One process is counted and none is touched.
            self.init(installRoot: installRoot, layout: layout, emit: emit) { _, _ in 1 }
        #else
            self.init(installRoot: installRoot, layout: layout, emit: emit, signalProcesses: ProcessTable.signal)
        #endif
    }

    /// `registrar` is `ApplicationRegistrar.live`, except in the harness: a
    /// Mac has no LaunchServices of the kind icli talks to.
    init(
        installRoot: String,
        layout: BootstrapLayout?,
        emit: @escaping (InstallerEvent) -> Void,
        registrar: ((ApplicationRegistrar.Request) throws -> [String: Any])? = nil,
        daemonManager: ((LaunchDaemon.Request) throws -> Void)? = nil,
        signalProcesses: @escaping (String, Int32) -> Int
    ) {
        self.installRoot = installRoot
        self.layout = layout ?? BootstrapLayout(installRoot: installRoot)
        self.emit = emit
        self.signalProcesses = signalProcesses
        self.registrar = ApplicationRegistrar(perform: registrar ?? ApplicationRegistrar.live(emit: emit))
        self.daemonManager = LaunchDaemon(perform: daemonManager ?? LaunchDaemon.live(emit: emit))
    }

    /// The whole job, to completion. Returns the status the transcript ends
    /// with: 0 when every step succeeded, otherwise the first failing step's.
    /// `.phase(.completed)` precedes every 0 and nothing else.
    public func run(_ job: InstallerJob) -> Int32 {
        do {
            try job.validate()
        } catch {
            emit(.failure(.invalidJob))
            return 64
        }
        let status: Int32 = switch job {
        case let .transaction(transaction):
            runTransaction(transaction)
        case .rebuildIconCache:
            rebuildIconCache()
        case .respring:
            respring()
        case .bootstrapIrisinDaemon:
            manageDaemon(.bootstrap(plist: daemonPlist, executable: daemonExecutable))
        case .bootoutIrisinDaemon:
            manageDaemon(.bootout(plist: daemonPlist))
        case .reloadAirDrop:
            signal("sharingd", SIGKILL)
        case .enterSafeMode:
            // The jailbreak's tweak-free safe mode: SpringBoard crashing on
            // SIGSEGV is what its injection library watches for.
            signal("SpringBoard", SIGSEGV)
        }
        if status == 0 {
            emit(.phase(.completed))
        }
        return status
    }

    /// The kernel path of the bootstrap's applications directory.
    private var applicationsDirectory: String {
        layout.resolve(layout.bootstrapPath("/Applications"))
    }

    /// The kernel path to the one plist these closed maintenance jobs may
    /// touch. It follows the helper onto either supported bootstrap.
    private var daemonPlist: String {
        layout.resolve(layout.bootstrapPath("/Library/LaunchDaemons/wiki.qaq.irisind.plist"))
    }

    /// The kernel path of the daemon's executable, beside this helper.
    private var daemonExecutable: String {
        layout.resolve(layout.bootstrapPath(IrisinWire.daemonPath))
    }

    // MARK: - Transaction

    private func runTransaction(_ transaction: InstallerJob.Transaction) -> Int32 {
        let applicationsBefore = Set(directoryEntries(applicationsDirectory))
        emit(.notice("Install root \(installRoot.isEmpty ? "/" : installRoot)"))
        emit(.notice("Applications directory \(applicationsDirectory)"))

        let installer = PackageInstaller(installRoot: installRoot, layout: layout, emit: emit)
        // Irisin's own files replaced the daemon, which leaves when its
        // executable does; its postinst loads the new one, but may not have
        // had a shell to run in, and a run that stopped later never reached
        // it. Loaded here whatever the run did, never as its failure.
        defer {
            if installer.placedSelf {
                reloadOwnDaemon()
            }
        }
        do {
            try installer.run(transaction)
        } catch let error as PackageStepFailure {
            emit(.failure(error.problem))
            return 1
        } catch {
            emit(.failure(.installationStopped(detail: String(describing: error))))
            return 1
        }

        // The package database has committed. Do not invite a retry of that
        // transaction merely because LaunchServices or husk cleanup failed.
        if !transaction.dryRun,
           !reconcileApplications(
               previous: applicationsBefore,
               installed: installedApplications(of: transaction.install.map(\.identity))
           )
        {
            emit(.warning(.homeScreenNeedsAttention))
        }
        return 0
    }

    /// The `.app` bundles a set of freshly installed packages put under the
    /// applications directory, in the bootstrap's own spelling, read from the
    /// compatible `.list` files. dpkg and the helper name them in lowercase;
    /// a list some other tool wrote in mixed case is still found.
    private func installedApplications(of identities: [String]) -> Set<String> {
        let infoDirectory = layout.resolve(layout.bootstrapPath("/Library/dpkg/info"))
        var lists = [String: String]()
        for entry in directoryEntries(infoDirectory) where entry.hasSuffix(".list") {
            lists[entry.lowercased()] = entry
        }
        let applicationsPrefix = layout.bootstrapPath("/Applications/")
        var applications = Set<String>()
        for identity in identities {
            guard let file = lists[(identity + ".list").lowercased()],
                  let contents = try? String(contentsOfFile: infoDirectory + "/" + file, encoding: .utf8)
            else { continue }
            for line in contents.split(separator: "\n") {
                let path = line.trimmingCharacters(in: .whitespaces)
                // A tweak may put files inside another app's bundle; only a
                // bundle directly under Applications is something to register.
                guard path.hasSuffix(".app"), path.utf8.starts(with: applicationsPrefix.utf8),
                      !path.utf8.dropFirst(applicationsPrefix.utf8.count).contains(0x2F) else { continue }
                applications.insert(path)
            }
        }
        return applications
    }

    /// Tell LaunchServices about the bundles that came and went, clear the
    /// husks a removal leaves behind (empty directories and roothide's
    /// `.jbroot` links beside former executables), then let icli reconcile
    /// the whole directory once for the ghosts an older transaction left.
    ///
    /// An updated app at its old path is registered by name: `refresh`
    /// skips a path whose registered bundle identifier and build have not
    /// changed, a package can change an app without changing its build, and
    /// re-registering is what makes LaunchServices reread the bundle.
    /// Registration is verified by icli itself (it reads LaunchServices back
    /// after every call), so `.done` here means the record is there.
    private func reconcileApplications(previous: Set<String>, installed: Set<String>) -> Bool {
        var succeeded = true
        var removed: [String] = []
        for name in previous.filter({ $0.hasSuffix(".app") }).sorted() {
            let path = applicationsDirectory + "/" + name
            do {
                if try RemovedApplicationBundle.isGone(path) {
                    removed.append(name)
                }
            } catch {
                emit(.warning(.leftoverBundle(path: path, detail: String(describing: error))))
                succeeded = false
            }
        }
        guard !installed.isEmpty || !removed.isEmpty else { return succeeded }
        emit(.phase(.registeringApplications))
        for application in installed.sorted() {
            let path = layout.resolve(application)
            let outcome = registrar.register(bundleAt: path)
            switch outcome {
            case .done:
                emit(.notice("Registered \(path)"))
            case .failed:
                emit(.warning(.registrationFailed(bundle: path, detail: outcome.reason)))
                succeeded = false
            }
        }
        for name in removed {
            let path = applicationsDirectory + "/" + name
            let outcome = registrar.unregister(bundleAt: path)
            switch outcome {
            case .done:
                emit(.notice("Unregistered \(path)"))
            case .failed:
                emit(.warning(.unregistrationFailed(bundle: path, detail: outcome.reason)))
                succeeded = false
                continue
            }
            do {
                try RemovedApplicationBundle.removeHusk(path)
            } catch {
                emit(.warning(.leftoverBundle(path: path, detail: String(describing: error))))
                succeeded = false
            }
        }
        let refreshed = registrar.refresh(directory: applicationsDirectory)
        if !refreshed.succeeded {
            emit(.warning(.refreshFailed(detail: refreshed.reason)))
            succeeded = false
        }
        return succeeded
    }

    // MARK: - Maintenance

    private func manageDaemon(_ request: LaunchDaemon.Request) -> Int32 {
        emit(.phase(.applying))
        do {
            try daemonManager.perform(request)
            switch request {
            case let .bootstrap(plist, _):
                emit(.notice("Bootstrapped and started Irisin daemon from \(plist)"))
            case let .bootout(plist):
                emit(.notice("Booted out Irisin daemon from \(plist)"))
            }
            return 0
        } catch {
            emit(.failure(.installationStopped(detail: String(describing: error))))
            return 1
        }
    }

    /// The daemon job the package's postinst pipes in, run from the end of
    /// a transaction that placed Irisin. A failure is a warning: the
    /// transaction's own outcome is already said.
    private func reloadOwnDaemon() {
        do {
            try daemonManager.perform(.bootstrap(plist: daemonPlist, executable: daemonExecutable))
            emit(.notice("Bootstrapped and started Irisin daemon from \(daemonPlist)"))
        } catch {
            emit(.warning(.daemonNotLoaded(detail: String(describing: error))))
        }
    }

    /// icli's refresh over the bootstrap's applications directory, after
    /// the husks left by older transactions are unregistered and removed.
    private func rebuildIconCache() -> Int32 {
        emit(.phase(.registeringApplications))
        var cleaned = true
        for name in directoryEntries(applicationsDirectory).filter({ $0.hasSuffix(".app") }).sorted() {
            let path = applicationsDirectory + "/" + name
            do {
                guard try RemovedApplicationBundle.isGone(path) else { continue }
            } catch {
                emit(.warning(.leftoverBundle(path: path, detail: String(describing: error))))
                cleaned = false
                continue
            }
            let outcome = registrar.unregister(bundleAt: path)
            switch outcome {
            case .done:
                do {
                    try RemovedApplicationBundle.removeHusk(path)
                    emit(.notice("Removed leftover app bundle \(path)"))
                } catch {
                    emit(.warning(.leftoverBundle(path: path, detail: String(describing: error))))
                    cleaned = false
                }
            case .failed:
                emit(.warning(.unregistrationFailed(bundle: path, detail: outcome.reason)))
                cleaned = false
            }
        }
        let outcome = registrar.refresh(directory: applicationsDirectory)
        switch outcome {
        case let .done(reply):
            let registered = (reply["registered"] as? [Any])?.count ?? 0
            let unregistered = (reply["unregistered"] as? [Any])?.count ?? 0
            let unchanged = (reply["unchanged"] as? [Any])?.count ?? 0
            emit(.notice("Registered \(registered), unregistered \(unregistered), unchanged \(unchanged)"))
        case .failed:
            emit(.failure(.refreshFailed(detail: outcome.reason)))
            return 1
        }
        guard cleaned else {
            emit(.failure(.homeScreenNeedsAttention))
            return 1
        }
        return 0
    }

    /// The graceful respring through icli; failing that, backboardd is asked
    /// to exit and takes SpringBoard with it, the way `killall backboardd`
    /// did.
    private func respring() -> Int32 {
        emit(.phase(.applying))
        let outcome = registrar.respring()
        switch outcome {
        case .done:
            return 0
        case .failed:
            emit(.notice("Graceful respring unavailable (\(outcome.reason)); restarting backboardd"))
            return signal("backboardd", SIGTERM, announced: false)
        }
    }

    /// `kill(2)` for every process by that name. 1 when there was none, the
    /// status `killall` gives for the same.
    private func signal(_ name: String, _ number: Int32, announced: Bool = true) -> Int32 {
        if announced {
            emit(.phase(.applying))
        }
        let delivered = signalProcesses(name, number)
        guard delivered > 0 else {
            emit(.warning(.noProcess(name: name)))
            return 1
        }
        #if targetEnvironment(simulator)
            emit(.notice("Simulator: signal \(number) to \(name) was not sent"))
        #else
            emit(.notice("Sent signal \(number) to \(delivered) \(name) process(es)"))
        #endif
        return 0
    }

    private func directoryEntries(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
