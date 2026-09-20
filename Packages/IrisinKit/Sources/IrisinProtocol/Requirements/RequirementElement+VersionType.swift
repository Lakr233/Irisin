import Foundation

public extension PackageRequirementGroup.Requirement.RequirementElement {
    enum VersionType: String, CaseIterable, Codable, Sendable {
        case bigger, biggerOrEqual, equal, smaller, smallerOrEqual, noneSpecific
    }
}
