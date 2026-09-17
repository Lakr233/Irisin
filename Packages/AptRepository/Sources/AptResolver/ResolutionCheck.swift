import Foundation

/// Evidence from the catalogue for one requested package or dependency group.
/// A match means a candidate exists, not that the entire transaction is solvable.
public struct ResolutionCheck: Hashable, Sendable {
    public let package: String
    public let requirement: String
    public let outcome: ResolutionCheckOutcome
    public let candidates: [String]

    public init(package: String, requirement: String, outcome: ResolutionCheckOutcome, candidates: [String] = []) {
        self.package = package
        self.requirement = requirement
        self.outcome = outcome
        self.candidates = candidates
    }
}
