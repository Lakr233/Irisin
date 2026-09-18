import Darwin
import Foundation
import IrisinProtocol

/// Which of the three jailbreak layouts we are running under, and how a path
/// has to be spelled for whoever is going to read it.
///
/// Mixing the two spellings up is the classic bootstrap-path bug, so each
/// direction is its own function and every call site names the one it means.
/// The rule comes from roothide's own NewTerm, by way of iGhostVT and Fila:
///
/// - The path handed to `execve` must be what the **kernel** wants, because
///   neither the kernel nor our helper is linked against libvroot: `resolve`.
/// - Every path handed to a bootstrap program, as an argument or in `PATH`,
///   must be in the bootstrap's own vocabulary, because those programs are
///   vroot-linked under roothide (unprefixed, the jbroot is their `/`) and
///   prefix-compiled under rootless (`/var/jb/...`): `bootstrapPath` and
///   `systemPath`.
public struct BootstrapLayout: Equatable, Sendable {
    /// Rootless bootstraps all agree on this, and their binaries carry it
    /// compiled in, so this literal, not whatever it resolves to, is what goes
    /// back into paths.
    public static let rootlessPrefix = "/var/jb"

    public let kind: Kind
    /// The directory standing in for a rootless prefix where nothing can
    /// create `/var/jb`: the simulator's container on a Mac. Packages and the
    /// database keep the prefix in their vocabulary and `resolve` lands them
    /// here. Nil on a device, where the prefix is a real path.
    public let mount: String?

    public init(kind: Kind, mount: String? = nil) {
        self.kind = kind
        self.mount = mount
    }

    /// Derived from the install root the helper peeled off its own path.
    public init(installRoot: String) {
        mount = nil
        var isBootstrap: Bool {
            var info = stat()
            return stat(installRoot + "/usr/libexec", &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }
        if installRoot.isEmpty {
            kind = .none
        } else if ProcessPath.canonical(Self.rootlessPrefix) == installRoot {
            // A rootless bootstrap may keep its files in a randomly named
            // directory with `/var/jb` symlinked at it; the install root is
            // canonical, so compare canonical against canonical and keep the
            // literal prefix its binaries were built against.
            kind = .rootless(prefix: Self.rootlessPrefix)
        } else {
            kind = isBootstrap ? .roothide(jbroot: installRoot) : .none
        }
    }

    /// How the bootstrap's own programs spell one of *its* files.
    public func bootstrapPath(_ path: String) -> String {
        switch kind {
        case .none, .roothide: path
        case let .rootless(prefix): prefix + path
        }
    }

    /// How those same programs spell a file on the untouched iOS filesystem,
    /// such as a `.deb` in the app's documents.
    public func systemPath(_ path: String) -> String {
        switch kind {
        case .none, .rootless: path
        case .roothide: "/rootfs" + path
        }
    }

    /// A path in the bootstrap's vocabulary, as a syscall wants it.
    public func resolve(_ path: String) -> String {
        switch kind {
        case .none: path
        case let .rootless(prefix):
            if let mount, path == prefix || path.utf8.starts(with: "\(prefix)/".utf8) {
                mount + String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
            } else {
                path
            }
        case let .roothide(jbroot): path.utf8.first == 0x2F ? jbroot + path : path
        }
    }

    /// The kernel path of one of the bootstrap's tools, from its generic
    /// spelling (`/usr/bin/dpkg`).
    public func tool(_ genericPath: String) -> String {
        resolve(bootstrapPath(genericPath))
    }

    /// Where the bootstrap keeps its tools, and where iOS keeps its own. The
    /// bootstrap's come first; without the second half a spawned tool reaches
    /// everything the bootstrap installed and nothing the system ships.
    public var searchPath: String {
        let bootstrap = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"]
        let system = ["/usr/sbin", "/usr/bin", "/sbin", "/bin"]
        return (bootstrap.map(bootstrapPath) + system.map(systemPath)).joined(separator: ":")
    }

    /// The environment every program we start as root gets. The bootstrap's
    /// programs read this, and under roothide they read it through vroot, so
    /// every path in it is in their vocabulary.
    ///
    /// One definition, because a second copy is how `DISABLE_TWEAKS` goes
    /// missing from one of the two paths that spawn root processes.
    public var rootEnvironment: [String: String] {
        [
            "PATH": searchPath,
            "HOME": bootstrapPath("/var/root"),
            "USER": "root",
            "LOGNAME": "root",
            "TERM": "dumb",
            "LANG": "C.UTF-8",
            "DEBIAN_FRONTEND": "noninteractive",
            "DPKG_FRONTEND_LOCKED": "true",
            // Nothing may inject into a process that runs maintainer scripts
            // as root.
            "DISABLE_TWEAKS": "1",
        ]
    }
}
