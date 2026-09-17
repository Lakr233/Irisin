import AptRepository

public enum ResolutionAction: Sendable {
    case install(Package)
    case remove(String)

    public var identity: String {
        switch self {
        case let .install(package): package.identity
        case let .remove(identity): identity
        }
    }
}
