import Foundation

/// Evidence from the catalogue for one requested package or dependency group.
/// A match means a candidate exists, not that the entire transaction is solvable.
public struct ResolutionCheck: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case matched
        case missing
        case incompatibleArchitecture
        case noMatchingVersion
        case invalidMetadata
        case conflictingRequirements
        /// The system requires the package, so it stays.
        case requiredBySystem
    }

    public let package: String
    public let requirement: String
    public let outcome: Outcome
    public let candidates: [String]

    public init(package: String, requirement: String, outcome: Outcome, candidates: [String] = []) {
        self.package = package
        self.requirement = requirement
        self.outcome = outcome
        self.candidates = candidates
    }
}
