/// A closed dpkg operation over identities declared by the transaction.
/// The helper owns all executable paths and argument construction.
public enum InstallerStage: Codable, Equatable, Sendable {
    case remove([String])
    case unpack([String])
    case configure([String])

    public var identities: [String] {
        switch self {
        case let .remove(packages), let .unpack(packages), let .configure(packages): packages
        }
    }
}
