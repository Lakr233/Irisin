import Darwin
import Foundation
import IrisinProtocol
#if canImport(XPC)
    import XPC
#endif

/// The app's one handle on the privileged half, and the only thing that
/// decides whether there is one.
///
/// The backend is chosen once, at the handshake, and never revisited:
/// what `hello()` answers is the only honest answer to "can this app install
/// anything", and it is an enum carrying the install root rather than a flag
/// beside it so a caller cannot read the polarity backwards.
public final class DaemonLink: @unchecked Sendable {
    public enum Backend: Sendable, Equatable {
        /// `irisind` answered. Every job runs as root in another process,
        /// and `installRoot` is the prefix the daemon resolved for itself:
        /// empty on a rootful layout, `/var/jb` on rootless, a randomized
        /// directory on roothide.
        case daemon(installRoot: String)
        /// There is no daemon here and there is not going to be one: a
        /// TrollStore or sideload install. Browsing works, nothing is
        /// installed, and every `run` is refused. The simulator never binds
        /// this: `SimulatorDaemon` answers there as `.daemon`.
        case local

        public var installRoot: String {
            guard case let .daemon(root) = self else { return "" }
            return root
        }

        public var isPrivileged: Bool {
            guard case .daemon = self else { return false }
            return true
        }
    }

    #if targetEnvironment(simulator)
        /// The directory that stands in for the bootstrap in the simulator,
        /// for the app's own reads of what is installed.
        public static var simulatedInstallRoot: String {
            SimulatorDaemon.installRoot
        }
    #endif

    /// How long a build that shipped no daemon keeps asking before it settles
    /// for browsing only. About two seconds of *Connecting…* in a build with
    /// no daemon, paid once per launch. A duration measured from the first
    /// miss and deliberately not a count of attempts: a count means whatever
    /// the caller's polling cadence makes it mean.
    public static let graceBeforeFallback: TimeInterval = 2.5

    public var onLinkLost: (@Sendable () -> Void)? {
        get { transport.onLinkLost }
        set { transport.onLinkLost = newValue }
    }

    private let transport = DaemonTransport()
    private let daemonIsInstalled: Bool
    private let grace: TimeInterval
    private let stateLock = NSLock()
    private var bound: Backend?
    private var firstMiss: Date?

    public convenience init() {
        self.init(daemonIsInstalled: Self.daemonIsInstalled(besideBundleAt: Bundle.main.bundleURL))
    }

    /// `grace` is a seam for the tests and nothing else.
    public init(daemonIsInstalled: Bool, grace: TimeInterval = DaemonLink.graceBeforeFallback) {
        self.daemonIsInstalled = daemonIsInstalled
        self.grace = grace
    }

    /// The backend already chosen, or nil while nothing has answered yet.
    public var backend: Backend? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bound
    }

    /// Whether this copy of the app was installed with `irisind` beside it.
    ///
    /// On disk rather than in a build flag on purpose: one binary ships in every
    /// wrapper and only the `.deb` carries the daemon. The package installs the
    /// app at `<prefix>/Applications/irisin.app` and the daemon at
    /// `<prefix>/usr/libexec/irisind` on every bootstrap.
    public static func daemonIsInstalled(besideBundleAt bundle: URL) -> Bool {
        let applications = bundle.deletingLastPathComponent()
        guard applications.lastPathComponent == "Applications" else { return false }
        let daemon = applications
            .deletingLastPathComponent()
            .appendingPathComponent(String(IrisinWire.daemonPath.dropFirst()))
        guard access(daemon.path, F_OK) != 0 else { return true }
        // Only "it is not there" answers false. "I could not look" must not
        // demote a device that has a daemon.
        return errno != ENOENT && errno != ENOTDIR
    }

    // MARK: - Choosing a backend

    /// Asks the daemon, and decides what a silence means.
    ///
    /// 1. If `irisind` answers, this is the privileged build, for good.
    /// 2. If it does not and the daemon is installed beside this bundle, the
    ///    service will appear once launchd catches up after a respring: keep
    ///    throwing, and let the caller keep retrying and saying *Connecting…*.
    ///    There is no path to the local backend on a device that has one.
    /// 3. Otherwise this binary came without a daemon. Once the grace period
    ///    has elapsed since the first miss, bind the local backend and say so.
    public func hello() async throws -> Backend {
        if let bound {
            return bound
        }
        do {
            let backend = try await transport.hello()
            return bind(backend)
        } catch {
            guard !daemonIsInstalled, graceHasElapsed() else { throw error }
            return bind(.local)
        }
    }

    private func graceHasElapsed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let first = firstMiss else {
            firstMiss = Date()
            return false
        }
        return Date().timeIntervalSince(first) >= grace
    }

    private func bind(_ backend: Backend) -> Backend {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let bound {
            return bound
        }
        bound = backend
        return backend
    }

    // MARK: - Jobs

    /// Start one job as root and read its transcript.
    ///
    /// Refused with `.notPermitted` when the bound backend is local; a
    /// handshake that has not happened yet is made here first, so a job asked
    /// for at cold launch waits for the daemon rather than being refused for
    /// arriving early.
    public func run(_ job: InstallerJob) async throws -> JobTranscript {
        guard try await hello().isPrivileged else {
            throw IrisinFailure(code: .notPermitted)
        }
        return try await transport.run(job)
    }

    /// Drop the connection so the next request builds a new one. An XPC
    /// connection whose Mach service was not registered is invalid for good.
    public func invalidate() {
        transport.invalidate()
    }
}
