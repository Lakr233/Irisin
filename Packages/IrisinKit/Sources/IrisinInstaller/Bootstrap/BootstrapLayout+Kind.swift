public extension BootstrapLayout {
    enum Kind: Equatable, Sendable {
        /// Rootful, or the Mac harness. Every mapping is the identity.
        case none
        /// A fixed prefix whose binaries speak real paths.
        case rootless(prefix: String)
        /// A randomly named jbroot whose binaries are vroot-linked, with the
        /// untouched iOS filesystem bridged back in at `/rootfs`.
        case roothide(jbroot: String)
    }
}
