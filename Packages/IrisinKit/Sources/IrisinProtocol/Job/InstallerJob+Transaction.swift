import Foundation

public extension InstallerJob {
    struct Transaction: Codable, Equatable, Sendable {
        public var install: [Package]
        public var remove: [String]
        public var dryRun: Bool
        public var stages: [InstallerStage]
        public var configureExisting: [String]
        /// The identities in `install` that only a dependency asked for:
        /// the helper marks them `Auto-Installed` in apt's extended_states,
        /// and removes the mark of every other identity it installs.
        public var autoInstalled: [String]
        /// SHA-256 of the complete status file used to resolve this transaction.
        public var statusDigest: String
        /// The user switched on removing system packages: the helper lets
        /// an Essential or Protected package in `remove` go. A held one
        /// still stays.
        public var allowSystemRemoval: Bool

        public init(
            install: [Package],
            remove: [String],
            dryRun: Bool = false,
            stages: [InstallerStage]? = nil,
            configureExisting: [String] = [],
            autoInstalled: [String] = [],
            statusDigest: String = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            allowSystemRemoval: Bool = false
        ) {
            self.install = install
            self.remove = remove
            self.dryRun = dryRun
            self.configureExisting = configureExisting
            self.autoInstalled = autoInstalled
            self.statusDigest = statusDigest
            self.allowSystemRemoval = allowSystemRemoval
            self.stages = stages ?? ([remove.isEmpty ? nil : .remove(remove),
                                      install.isEmpty ? nil : .unpack(install.map(\.identity)),
                                      install.isEmpty ? nil : .configure(install.map(\.identity))].compactMap(\.self))
        }

        /// Whether this transaction replaces or removes the app itself. The
        /// app that started it will not be the app that finishes reading its
        /// output, which is why the helper runs detached and keeps a log.
        public var touchesSelf: Bool {
            (install.map(\.identity) + remove).contains { $0.hasPrefix(InstallerJob.selfIdentityPrefix) }
        }
    }
}
