import AptRepository

public enum ResolutionAction: Sendable {
    /// Install this exact record at its selected (latest) version. Its
    /// source, archive and metadata survive every solve; dependencies may
    /// choose candidates, but an unsatisfiable explicit choice must fail.
    case install(Package)
    case remove(String)

    public var identity: String {
        switch self {
        case let .install(package): package.identity
        case let .remove(identity): identity
        }
    }
}
