import Foundation

/// Names and limits shared by the app, `irisind` and `irisin-install`.
///
/// The daemon is the only process here that runs as root, so this is also the
/// whole trust boundary: everything a client can ask for is one of the
/// operations below, and the ones that do anything carry a closed
/// `InstallerJob` or a package's file descriptor, never a command line.
public enum IrisinWire {
    public static let version: UInt64 = 3
    public static let serviceName = "wiki.qaq.irisin.service"

    /// What a client must carry, strictly `true`, beside `platform-application`
    /// and `com.apple.private.security.no-sandbox`. It is the public
    /// contract for other packages' clients as well as Irisin's own app: it
    /// says a program means to be a client, and that is all it says. It is
    /// not an identity: any installed package can sign a program with it.
    public static let clientEntitlement = "wiki.qaq.irisin.client"

    /// Every entitlement `irisind` requires of a peer, each strictly `true`.
    public static let requiredClientEntitlements = [
        clientEntitlement,
        "platform-application",
        "com.apple.private.security.no-sandbox",
    ]

    /// Irisin's own app, relative to the install root. It is admitted by the
    /// rule it always was (this exact path, a root-owned file writable by
    /// nobody else) as well as by `ExecutableAdmission`, so a bootstrap
    /// whose directories the wider rule distrusts never locks Irisin out of
    /// its own daemon.
    /// On tvOS it is the launchpad (the `IrisinLaunchpad` target), whose
    /// product is installed at the same path.
    public static let clientPaths = ["/Applications/irisin.app/irisin"]

    /// The version of the external-client operations (`serviceInfo` through
    /// `respring`), answered by `serviceInfo`. It grows when one of them
    /// changes shape; a new operation is a new capability, not a new version.
    public static let externalVersion: UInt64 = 1

    /// What `serviceInfo` lists, one name per operation an external client
    /// may use.
    public static let externalCapabilities = [
        "submitInstall", "transactionStatus", "transactionEvents", "removePackage", "respring",
    ]

    /// Where external transactions keep their records, relative to the
    /// install root: one directory per transaction id, root's alone.
    public static let transactionsPath = "/var/lib/irisin/transactions"

    /// The largest package `submitInstall` takes.
    public static let maximumPackageByteCount: Int64 = 4 << 30

    /// The most events one `transactionEvents` reply carries.
    public static let maximumEventsPerReply = 256

    /// Where the package puts the two root binaries, relative to the install
    /// root. The daemon finds its root by peeling `daemonPath` off its own
    /// executable path; the helper does the same with `helperPath`.
    public static let daemonPath = "/usr/libexec/irisind"
    public static let helperPath = "/usr/libexec/irisin-install"

    /// The helper's transcript of its last run, relative to the install root,
    /// as plain text with a timestamp per line. Written as well as streamed,
    /// because a self-update replaces the app that was reading the stream.
    /// The run before it is kept beside it with `.previous` appended.
    public static let installerLogPath = "/var/log/irisin-install.log"

    /// The app's own folder in mobile's `Documents`, named for its bundle id.
    /// The app has no container, so its home is shared with every other app
    /// without one; the bundle id keeps them out of each other's data, as a
    /// sandbox's container would. The postinst and `prepareUserHome` make it,
    /// and `Documents` above it, for mobile.
    public static let appDataFolderName = "wiki.qaq.irisin"

    /// Hard ceiling on the encoded job in a `run` request.
    public static let maximumJobByteCount = 256 * 1024

    /// The keys of the XPC dictionaries both sides read.
    public enum Key {
        public static let version = "v"
        public static let operation = "op"
        public static let code = "code"
        public static let errno = "errno"
        public static let path = "path"
        public static let installRoot = "root"
        /// The `InstallerJob`, JSON encoded.
        public static let job = "job"
        public static let descriptor = "fd"
        public static let jobIdentifier = "jobid"

        // External clients. Documentation/ExternalClients.md is the contract.
        public static let externalVersion = "xv"
        public static let capabilities = "caps"
        public static let transaction = "txid"
        public static let sha256 = "sha256"
        public static let packageIdentity = "package"
        public static let packageVersion = "pkgver"
        public static let kind = "kind"
        public static let state = "state"
        public static let duplicate = "dup"
        public static let exitStatus = "exit"
        public static let failure = "failure"
        public static let failureText = "failtext"
        public static let nextSequence = "next"
        public static let afterSequence = "after"
        public static let limit = "limit"
        public static let events = "events"
        public static let sequence = "seq"
        public static let text = "text"
        public static let phase = "phase"
        public static let step = "step"
        public static let completed = "done"
        public static let total = "total"
        public static let raw = "raw"
    }
}

/// Every request the daemon serves.
public enum IrisinOperation: UInt64, Sendable, CaseIterable {
    /// Protocol handshake. Establishes the version and reports the install
    /// root the daemon resolved for itself.
    case hello = 1

    /// Start one `InstallerJob` as root. The daemon spawns `irisin-install`
    /// with the job on its standard input and hands the read end of the
    /// helper's output pipe back over XPC; the bytes then flow between the app
    /// and the kernel with nothing in between, and the helper runs to the end
    /// whether or not the daemon or the app survives it.
    case run = 2

    case goodbye = 3

    // MARK: External clients
    //
    // Another package's program installs through these: a package by file
    // descriptor, a removal by package id, a respring, each a transaction
    // the client names, recorded on disk and read back by id. The daemon
    // keeps no state in memory for them. Documentation/ExternalClients.md.

    /// The external protocol version, the capabilities and the install root.
    case serviceInfo = 4

    /// Install one `.deb` passed as a file descriptor, under a transaction
    /// id the client chose. The helper copies it into root's own staging
    /// before verifying it, so what the client does to its file afterwards
    /// changes nothing. The same id twice installs once.
    case submitInstall = 5

    /// A transaction's state, read from its record.
    case transactionStatus = 6

    /// A transaction's events after a sequence number, replayed from its
    /// record: a client that reconnects asks again from where it was.
    case transactionEvents = 7

    /// Remove one package by id, as a transaction. Nothing that depends on
    /// it is removed with it: such a removal fails.
    case removePackage = 8

    /// icli's graceful respring, as a transaction.
    case respring = 9

    public var name: String {
        String(describing: self)
    }
}

public enum IrisinReplyCode: Int64, Sendable, Codable {
    case success = 0
    case invalidRequest = 1
    /// On a device this means the daemon refused the client, or there is no
    /// privileged backend at all.
    case notPermitted = 2
    case notFound = 3
    case operationFailed = 4
    /// A transaction id already names a different request.
    case conflict = 5
}

/// Everything that can come back instead of an answer.
public struct IrisinFailure: Error, Sendable, Hashable, Codable {
    public var code: IrisinReplyCode
    /// The `errno` the failing syscall set, or 0 when the refusal was the
    /// daemon's own.
    public var systemError: Int32
    public var path: String?

    public init(code: IrisinReplyCode, systemError: Int32 = 0, path: String? = nil) {
        self.code = code
        self.systemError = systemError
        self.path = path
    }

    public init(errno: Int32, path: String? = nil) {
        switch errno {
        case ENOENT, ENOTDIR: code = .notFound
        case EACCES, EPERM: code = .notPermitted
        default: code = .operationFailed
        }
        systemError = errno
        self.path = path
    }

    public var systemErrorDescription: String? {
        guard systemError != 0 else { return nil }
        return String(cString: strerror(systemError))
    }
}
