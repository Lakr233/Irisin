public struct PackageRequirement: Codable, Sendable {
    public let group: [PackageRequirementGroup]
    public init(group: [PackageRequirementGroup]) {
        self.group = group
    }
}
