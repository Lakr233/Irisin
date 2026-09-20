import Foundation

/// Names and limits shared by the app, `irisind` and `irisin-install`.
///
/// The daemon is the only process here that runs as root, so this is also the
/// whole trust boundary: everything the app can ask for is one of the three
/// operations below, and the one that does anything carries a closed
/// `InstallerJob`, never a command line.
public enum IrisinWire {
    public static let version: UInt64 = 3
    public static let serviceName = "wiki.qaq.irisin.service"
    public static let clientEntitlement = "wiki.qaq.irisin.client"

    /// Resolved against the install root the daemon itself runs from, so one
    /// list covers roothide's randomized bootstrap and the fixed rootless
    /// `/var/jb` prefix.
    public static let clientPaths = [
        "/Applications/irisin.app/irisin",
    ]

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
