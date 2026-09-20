import Foundation

public extension PackageRequirementGroup {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case depends
        case preDepends = "pre-depends"
        case conflicts
        case replaces
        case breaks
        case provides
    }
}
