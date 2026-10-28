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
    let installRoot: String
    let layout: BootstrapLayout
    let emit: (InstallerEvent) -> Void
    /// Where an external install's package arrives: descriptor 3, which the
    /// daemon passed through. The harness hands a file of its own.
    var externalPackageDescriptor = InstallerJob.External.packageDescriptor
    private let registrar: ApplicationRegistrar
    private let daemonManager: LaunchDaemon
    /// `ProcessTable.signal`, except in the harness: a Mac running a
    /// simulator has a backboardd of its own that a test must not touch.
    private let signalProcesses: (String, Int32) -> Int
    /// What the scripts read as `IRISIN_INSTALLER_*`.
    let identity: InstallerIdentity
    /// Irisin's own bundles, by kernel path, that the transaction took
    /// away: unregistering one stops the app, so it waits for
    /// `finishAfterExit`.
    private var removedOwnApplications: [String] = []

    public convenience init(
        installRoot: String,
        layout: BootstrapLayout? = nil,
        identity: InstallerIdentity = .current,
        emit: @escaping (InstallerEvent) -> Void
    ) {
        #if targetEnvironment(simulator)
            // The simulator shares the Mac's process table: a real signal
            // would reach the host's sharingd and every booted simulator's
            // SpringBoard. One process is counted and none is touched.
            self.init(installRoot: installRoot, layout: layout, identity: identity, emit: emit) { _, _ in 1 }
        #else
            self.init(
                installRoot: installRoot,
                layout: layout,
                identity: identity,
                emit: emit,
                signalProcesses: ProcessTable.signal
            )
        #endif
    }

    /// `registrar` is `ApplicationRegistrar.live`, except in the harness: a
    /// Mac has no LaunchServices of the kind icli talks to.
    init(
        installRoot: String,
        layout: BootstrapLayout?,
        identity: InstallerIdentity = .current,
        emit: @escaping (InstallerEvent) -> Void,
        registrar: ((ApplicationRegistrar.Request) throws -> [String: Any])? = nil,
        daemonManager: ((LaunchDaemon.Request) throws -> Void)? = nil,
        signalProcesses: @escaping (String, Int32) -> Int
    ) {
        self.installRoot = installRoot
        self.layout = layout ?? BootstrapLayout(installRoot: installRoot)
        self.emit = emit
        self.identity = identity
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
        case .registerOwnApplication:
            registerOwnApplication()
        case .respring:
            respring()
        case .bootstrapIrisinDaemon:
            manageDaemon(.bootstrap(plist: daemonPlist, executable: daemonExecutable))
        case .bootoutIrisinDaemon:
            manageDaemon(.bootout(plist: daemonPlist))
        case .reloadAirDrop:
            reloadAirDrop()
        case .enterSafeMode:
            // The jailbreak's tweak-free safe mode: the home screen crashing
            // on SIGSEGV is what its injection library watches for.
            signal(SystemProcess.homeScreen, SIGSEGV)
        case .prepareUserHome:
            prepareUserHome()
        case let .external(external):
            runExternal(external)
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

    /// `client` and an external client's `clientTransaction` id are what the
    /// scripts read in `IRISIN_INSTALLER_*`.
    func runTransaction(
        _ transaction: InstallerJob.Transaction,
        client: InstallerIdentity.Client = .app,
        clientTransaction: String? = nil
    ) -> Int32 {
        let applicationsBefore = applicationBundles()
        emit(.notice("Install root \(installRoot.isEmpty ? "/" : installRoot)"))
        emit(.notice("Applications directory \(applicationsDirectory)"))

        let installer = PackageInstaller(
            installRoot: installRoot,
            layout: layout,
            installerEnvironment: identity.environment(client: client, transaction: clientTransaction),
            emit: emit
        )
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
               current: applicationBundles(),
               installed: installedApplications(of: transaction.install.map(\.identity)),
               own: Set(installer.selfApplications.map { layout.resolve($0) })
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
        var applications = Set<String>()
        for identity in identities {
            guard let file = lists[(identity + ".list").lowercased()],
                  let contents = try? String(contentsOfFile: infoDirectory + "/" + file, encoding: .utf8)
            else { continue }
            applications.formUnion(self.applications(inList: contents))
        }
        return applications
    }

    /// The bundles directly under Applications that a `.list` names. A tweak
    /// may put files inside another app's bundle; only a bundle directly
    /// under Applications is something to register.
    private func applications(inList contents: String) -> Set<String> {
        let applicationsPrefix = layout.bootstrapPath("/Applications/")
        var applications = Set<String>()
        for line in contents.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasSuffix(".app"), path.utf8.starts(with: applicationsPrefix.utf8),
                  !path.utf8.dropFirst(applicationsPrefix.utf8.count).contains(0x2F) else { continue }
            applications.insert(path)
        }
        return applications
    }

    /// Irisin's own app bundles, as kernel paths: those in the installed
    /// list that has this helper in it, whatever the package and the bundle
    /// are called. Empty where no list has it (a bootstrap that installed
    /// Irisin without dpkg's database). A transaction has `SelfPackage`'s.
    private func ownApplications() -> Set<String> {
        let infoDirectory = layout.resolve(layout.bootstrapPath("/Library/dpkg/info"))
        let helper = layout.bootstrapPath(IrisinWire.helperPath)
        // Irisin's own name first, then every list: the name is a shortcut,
        // never the rule.
        let prefix = InstallerJob.selfIdentityPrefix
        let entries = directoryEntries(infoDirectory).filter { $0.hasSuffix(".list") }
            .sorted { $0.hasPrefix(prefix) && !$1.hasPrefix(prefix) }
        for entry in entries {
            guard let contents = try? String(contentsOfFile: infoDirectory + "/" + entry, encoding: .utf8),
                  contents.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == helper })
            else { continue }
            return Set(applications(inList: contents).map { layout.resolve($0) })
        }
        return []
    }

    /// What each `.app` directly under the applications directory looked
    /// like, by name: its `Info.plist`'s identity and change time, or nil
    /// for a bundle without one (a husk).
    private func applicationBundles() -> [String: BundleStamp?] {
        var bundles = [String: BundleStamp?]()
        for name in directoryEntries(applicationsDirectory) where name.hasSuffix(".app") {
            bundles[name] = BundleStamp(infoPlist: applicationsDirectory + "/" + name + "/Info.plist")
        }
        return bundles
    }

    /// Tell LaunchServices about the bundles that came and went, and clear
    /// the husks a removal leaves behind (empty directories and roothide's
    /// `.jbroot` links beside former executables). Only what this run
    /// changed is touched, never the whole directory: an app the packages'
    /// lists name, and, for a bundle a maintainer script made or rewrote
    /// that no list names, every bundle whose `Info.plist` is not the one
    /// it was before. Ghosts an older run left are Rebuild Icon Cache's.
    ///
    /// An updated app at its old path is registered by name: a package can
    /// change an app without changing its build or its `Info.plist`, and
    /// re-registering is what makes LaunchServices reread the bundle.
    /// Registration is verified by icli itself (it reads LaunchServices back
    /// after every call), so `.done` here means the record is there.
    ///
    /// Irisin's own bundles (`own`, kernel paths) are left alone: registering
    /// or unregistering the running app stops it before it has read the end
    /// of the run. An updated one the app registers as it exits
    /// (`registerOwnApplication`); a removed one waits for the app to be gone
    /// (`finishAfterExit`).
    private func reconcileApplications(
        previous: [String: BundleStamp?],
        current: [String: BundleStamp?],
        installed: Set<String>,
        own: Set<String>
    ) -> Bool {
        var succeeded = true
        var removed: [String] = []
        // A bundle this run took the Info.plist from; a husk that was one
        // before the run is left for Rebuild Icon Cache.
        for (name, stamp) in previous.sorted(by: { $0.key < $1.key }) where stamp != nil && (current[name] ?? nil) == nil {
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
        var changed = Set(installed.map { layout.resolve($0) })
        for (name, stamp) in current where stamp != nil && previous[name] != stamp {
            changed.insert(applicationsDirectory + "/" + name)
        }
        for path in changed.intersection(own).sorted() {
            changed.remove(path)
            emit(.notice("Left \(path) for Irisin to register as it exits"))
        }
        removed.removeAll { name in
            let path = applicationsDirectory + "/" + name
            guard own.contains(path) else { return false }
            removedOwnApplications.append(path)
            emit(.notice("Left \(path) to unregister once this run has ended"))
            return true
        }
        guard !changed.isEmpty || !removed.isEmpty else { return succeeded }
        emit(.phase(.registeringApplications))
        for path in changed.sorted() {
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

    /// Irisin's own bundles registered, the ones a transaction that updated
    /// them left for the app to ask for as it exits: registering the app
    /// stops it, which is how it leaves.
    private func registerOwnApplication() -> Int32 {
        let bundles = ownApplications().filter { BundleStamp(infoPlist: $0 + "/Info.plist") != nil }
        guard !bundles.isEmpty else {
            emit(.failure(.installationStopped(detail: "No installed package lists Irisin's app bundle")))
            return 1
        }
        emit(.phase(.registeringApplications))
        #if os(tvOS)
            awaitExit(of: bundles)
        #endif
        var status: Int32 = 0
        for path in bundles.sorted() {
            let outcome = registrar.register(bundleAt: path)
            switch outcome {
            case .done:
                emit(.notice("Registered \(path)"))
            case .failed:
                emit(.failure(.registrationFailed(bundle: path, detail: outcome.reason)))
                status = 1
            }
        }
        return status
    }

    #if os(tvOS)
        /// PineBoard disables an app that LaunchServices registers while it
        /// runs, and enables it again only at its next registration: the
        /// launchpad that asked for this, leaving after its own update,
        /// stayed refused at every launch. Its process is let go first, ten
        /// seconds at most, then the registration goes ahead regardless.
        private func awaitExit(of bundles: Set<String>) {
            let executables = bundles.compactMap { bundle in
                NSDictionary(contentsOfFile: bundle + "/Info.plist")?["CFBundleExecutable"] as? String
            }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline,
                  executables.contains(where: { !ProcessTable.processIdentifiers(named: $0).isEmpty })
            {
                usleep(100_000)
            }
        }
    #endif

    /// What waits until the transcript has ended: Irisin's own bundles a
    /// removal took away, unregistered and cleared once the app has read the
    /// end of the run, since unregistering stops it. `log` is the log alone;
    /// the pipe is closed by then.
    public func finishAfterExit(log: (InstallerEvent) -> Void) {
        for path in removedOwnApplications {
            let outcome = registrar.unregister(bundleAt: path)
            guard outcome.succeeded else {
                log(.warning(.unregistrationFailed(bundle: path, detail: outcome.reason)))
                continue
            }
            log(.notice("Unregistered \(path)"))
            do {
                try RemovedApplicationBundle.removeHusk(path)
            } catch {
                log(.warning(.leftoverBundle(path: path, detail: String(describing: error))))
            }
        }
        removedOwnApplications = []
    }

    /// The graceful respring through icli (PineBoard's on tvOS); failing
    /// that, backboardd is asked to exit and takes the home screen with it,
    /// the way `killall backboardd` did.
    private func respring() -> Int32 {
        emit(.phase(.applying))
        let outcome = registrar.respring()
        switch outcome {
        case .done:
            return 0
        case .failed:
            emit(.notice("Graceful respring unavailable (\(outcome.reason)); restarting \(SystemProcess.backboard)"))
            return signal(SystemProcess.backboard, SIGTERM, announced: false)
        }
    }

    /// A system with no AirDrop has nothing to reload: the job is not one of
    /// its jobs, and no one there sends it.
    private func reloadAirDrop() -> Int32 {
        guard let airDrop = SystemProcess.airDrop else {
            emit(.failure(.invalidJob))
            return 64
        }
        return signal(airDrop, SIGKILL)
    }

    /// mobile's home as this bootstrap's apps are registered with it: inside
    /// the jbroot on roothide, where icli sets HOME as roothide's uicache
    /// does, and the system's own elsewhere.
    private var userHome: String {
        if case .roothide = layout.kind {
            layout.resolve("/var/mobile")
        } else {
            "/var/mobile"
        }
    }

    /// Makes the app's data folder for mobile, and every level above it that
    /// is missing: `userHome`, its `Documents`, and
    /// `Documents/<IrisinWire.appDataFolderName>` — the same as the postinst
    /// does at install. A roothide bootstrap need not have `var/mobile`, the
    /// jbroot's `var` belongs to root, and an app whose home is missing
    /// cannot make it or keep anything.
    ///
    /// Each level is made and handed to mobile on its own: one `mkdir -p` as
    /// root leaves the levels above the last one root's, and mobile can then
    /// make nothing beside it. A level that exists is left as it is, but for
    /// a `Documents` that root owns — what the postinst of 4.3.4 through
    /// 4.5.25 left on a bootstrap that had none — which goes back to mobile.
    /// No level is followed through a symlink: mobile could have planted one
    /// to have root hand it some other directory.
    private func prepareUserHome() -> Int32 {
        let home = userHome
        let documents = home + "/Documents"
        let mobile = getpwnam("mobile")
        let uid = mobile?.pointee.pw_uid ?? 501
        let gid = mobile?.pointee.pw_gid ?? 501
        var applying = false
        for directory in [home, documents, documents + "/" + IrisinWire.appDataFolderName] {
            var info = stat()
            let exists = lstat(directory, &info) == 0
            if exists, info.st_mode & S_IFMT != S_IFDIR {
                emit(.failure(.installationStopped(detail: "\(directory) is not a directory")))
                return 1
            }
            let handsBack = exists && directory == documents && info.st_uid == 0
            guard !exists || handsBack else { continue }
            if !applying {
                emit(.phase(.applying))
                applying = true
            }
            // mode and owner set after mkdir: it applies the umask
            let made = (exists || mkdir(directory, 0o755) == 0)
                && lchown(directory, uid, gid) == 0
                && lchmod(directory, 0o755) == 0
            guard made else {
                let reason = String(cString: strerror(errno))
                emit(.failure(.installationStopped(detail: "Could not make \(directory) for mobile: \(reason)")))
                return 1
            }
            emit(.notice(exists ? "Gave \(directory) back to mobile" : "Made \(directory) for mobile"))
        }
        if !applying {
            emit(.notice("Home \(home) is ready"))
        }
        return 0
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

/// An `Info.plist` as `stat(2)` saw it: a file written in place moves its
/// change time, one replaced by a new bundle is another inode.
struct BundleStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let changed: timespec

    init?(infoPlist path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        changed = info.st_ctimespec
    }

    static func == (lhs: BundleStamp, rhs: BundleStamp) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
}
