import Foundation

public extension PackageRequirementGroup {
    enum RequirementType: String, CaseIterable, Codable, Sendable {
        case depends
        case preDepends = "pre-depends"
        case conflicts
        case replaces
        case breaks
        case provides
    }
}
