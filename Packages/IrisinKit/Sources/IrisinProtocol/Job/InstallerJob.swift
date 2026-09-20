import Foundation

/// The one thing the daemon will do as root, and the whole of what the app can
/// say about it.
///
/// There is deliberately no `exec(path, argv)` and no environment here. The
/// app names package files and package identities; every argv is composed in
/// `irisin-install` from these fields alone. A root daemon that can be
/// talked into running a command is a root shell for whoever can talk to it.
public enum InstallerJob: Codable, Equatable, Sendable {
    /// An ordered package transaction, carried out natively, followed by
    /// LaunchServices registration of the app bundles it added or removed.
    case transaction(Transaction)
    /// Unregister and remove the husks of removed apps, then icli's refresh
    /// over the bootstrap's applications directory.
    case rebuildIconCache
    /// icli's graceful respring, and a signal to backboardd when it fails.
    case respring
    /// Replace and start the installed Irisin LaunchDaemon with the plist
    /// beside this helper's install root. No path or label crosses the wire.
    case bootstrapIrisinDaemon
    /// Remove Irisin's own LaunchDaemon before its package is removed. No
    /// path or label crosses the wire.
    case bootoutIrisinDaemon
    /// SIGKILL to sharingd, sent by the helper itself.
    case reloadAirDrop
    /// SIGSEGV to SpringBoard, sent by the helper itself: the jailbreak's
    /// tweak-free safe mode.
    case enterSafeMode

    /// Every package of ours starts with this, on both bootstraps.
    public static let selfIdentityPrefix = "wiki.qaq.irisin"

    public var name: String {
        switch self {
        case .transaction: "transaction"
        case .rebuildIconCache: "rebuildIconCache"
        case .respring: "respring"
        case .bootstrapIrisinDaemon: "bootstrapIrisinDaemon"
        case .bootoutIrisinDaemon: "bootoutIrisinDaemon"
        case .reloadAirDrop: "reloadAirDrop"
        case .enterSafeMode: "enterSafeMode"
        }
    }
}

public extension InstallerJob {
    static let maximumPackagesPerTransaction = 512

    /// What a well-formed job looks like. Both the daemon and the helper check
    /// this before doing anything, so a malformed job never reaches an argv.
    ///
    /// Identities follow dpkg's own rule: lowercase alphanumerics, `+`, `-`,
    /// `.`, at least two characters, starting with an alphanumeric. A file
    /// path must be absolute, NUL-free and end in `.deb`; whether it exists is
    /// the daemon's question, answered after `realpath`.
    func validate() throws {
        guard case let .transaction(transaction) = self else { return }
        guard !transaction.stages.isEmpty else {
            throw IrisinFailure(code: .invalidRequest)
        }
        guard transaction.install.count + transaction.remove.count + transaction.configureExisting.count
            <= Self.maximumPackagesPerTransaction
        else {
            throw IrisinFailure(code: .invalidRequest)
        }
        for identity in transaction.remove + transaction.install.map(\.identity) + transaction.configureExisting {
            guard Self.isPackageIdentity(identity) else {
                throw IrisinFailure(code: .invalidRequest, path: identity)
            }
        }
        let installing = Set(transaction.install.map(\.identity))
        let removing = Set(transaction.remove)
        let existing = Set(transaction.configureExisting)
        let automatic = Set(transaction.autoInstalled)
        guard installing.count == transaction.install.count,
              removing.count == transaction.remove.count,
              existing.count == transaction.configureExisting.count,
              automatic.count == transaction.autoInstalled.count, automatic.isSubset(of: installing),
              installing.isDisjoint(with: removing), existing.isDisjoint(with: installing.union(removing)),
              Self.isSHA256Hex(transaction.statusDigest),
              transaction.stages.count <= Self.maximumPackagesPerTransaction * 3
        else {
            throw IrisinFailure(code: .invalidRequest)
        }
        var unpacked = Set<String>()
        var configured = Set<String>()
        var removed = Set<String>()
        for stage in transaction.stages {
            let identities = Set(stage.identities)
            guard !identities.isEmpty, identities.count == stage.identities.count else {
                throw IrisinFailure(code: .invalidRequest)
            }
            switch stage {
            case .remove:
                guard identities.isSubset(of: removing), removed.isDisjoint(with: identities) else {
                    throw IrisinFailure(code: .invalidRequest)
                }
                removed.formUnion(identities)
            case .unpack:
                guard identities.isSubset(of: installing), unpacked.isDisjoint(with: identities) else {
                    throw IrisinFailure(code: .invalidRequest)
                }
                unpacked.formUnion(identities)
            case .configure:
                guard identities.isSubset(of: unpacked.union(existing)), configured.isDisjoint(with: identities) else {
                    throw IrisinFailure(code: .invalidRequest)
                }
                configured.formUnion(identities)
            }
        }
        guard unpacked == installing, removed == removing, configured == installing.union(existing) else {
            throw IrisinFailure(code: .invalidRequest)
        }
        for package in transaction.install {
            if let preparedPath = package.preparedPath {
                guard preparedPath.hasPrefix("/"), !preparedPath.utf8.contains(0),
                      // by bytes: `..` and a combining mark is one character
                      !preparedPath.utf8.split(separator: 0x2F).contains(where: { $0.elementsEqual("..".utf8) }),
                      let digest = package.preparedSHA256, Self.isSHA256Hex(digest)
                else {
                    throw IrisinFailure(code: .invalidRequest, path: preparedPath)
                }
            } else if package.preparedSHA256 != nil {
                throw IrisinFailure(code: .invalidRequest)
            }
            guard Self.isSHA256Hex(package.sha256),
                  package.path.hasPrefix("/"),
                  !package.path.utf8.contains(0),
                  package.path.hasSuffix(".deb"),
                  !package.path.contains("/../")
            else {
                throw IrisinFailure(code: .invalidRequest, path: package.path)
            }
        }
    }

    static func isPackageIdentity(_ identity: String) -> Bool {
        guard identity.count >= 2, identity.count <= 256,
              let first = identity.unicodeScalars.first, first.isPackageIdentityStart else { return false }
        return identity.unicodeScalars.allSatisfy(\.isPackageIdentityCharacter)
    }

    /// Exactly 64 lowercase hexadecimal digits.
    private static func isSHA256Hex(_ text: String) -> Bool {
        text.count == 64 && text.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> InstallerJob {
        guard data.count <= IrisinWire.maximumJobByteCount else {
            throw IrisinFailure(code: .invalidRequest)
        }
        do {
            let job = try JSONDecoder().decode(InstallerJob.self, from: data)
            try job.validate()
            return job
        } catch let failure as IrisinFailure {
            throw failure
        } catch {
            throw IrisinFailure(code: .invalidRequest)
        }
    }
}

private extension Unicode.Scalar {
    var isPackageIdentityStart: Bool {
        ("a" ... "z").contains(self) || ("0" ... "9").contains(self)
    }

    var isPackageIdentityCharacter: Bool {
        isPackageIdentityStart || self == "+" || self == "-" || self == "."
    }
}
