public enum ResolutionCheckOutcome: Hashable, Sendable {
    case matched
    case missing
    case incompatibleArchitecture
    case noMatchingVersion
    case invalidMetadata
    case conflictingRequirements
    /// The system requires the package, so it stays.
    case requiredBySystem
}
