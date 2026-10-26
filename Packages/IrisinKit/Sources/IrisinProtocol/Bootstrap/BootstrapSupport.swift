/// Which bootstraps `irisind` and `irisin-install` serve on this system.
///
/// Both ask with the install root they peeled off their own path, before
/// either does anything: the daemon before its listener exists, the helper
/// before it reads its job. A bootstrap this system does not serve gets no
/// daemon and a helper that answers `helperMisplaced`.
public enum BootstrapSupport {
    /// The system a build is for.
    public enum System: Sendable {
        case iOS
        case tvOS

        public static var current: System {
            #if os(tvOS)
                .tvOS
            #else
                .iOS
            #endif
        }
    }

    /// Whether a bootstrap whose files are under `installRoot` is served on
    /// `system`.
    ///
    /// - iOS serves every install root it always has: rootless, RootHide,
    ///   and the empty root, which is rootful or the Mac harness.
    /// - tvOS serves RootHide alone: the install root must end in a name
    ///   libroothide would make. An empty root (rootful) and `/var/jb` or
    ///   wherever it leads (rootless) are refused, and so is a root that
    ///   only holds a `usr/libexec`, which iOS takes for RootHide: tvOS has
    ///   no older install to stay compatible with.
    public static func serves(installRoot: String, on system: System = .current) -> Bool {
        switch system {
        case .iOS:
            true
        case .tvOS:
            installRoot.split(separator: "/").last.map { RoothideRoot.isRootName($0) } ?? false
        }
    }
}
