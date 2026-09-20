import Foundation

public extension PackageRequirementGroup.Clause.Term {
    enum VersionType: String, CaseIterable, Codable, Sendable {
        // The raw values are the names these cases had, kept for anything
        // that was ever encoded with them.
        case greater = "bigger"
        case greaterOrEqual = "biggerOrEqual"
        case equal, smaller, smallerOrEqual, noneSpecific
    }
}
