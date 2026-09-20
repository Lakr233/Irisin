import Foundation

public struct PackageRequirementGroup: Codable, Sendable {
    public let type: Kind
    public let requirements: [Clause]
    public let original: String

    public init?(value: String, type: Kind) {
        self.type = type
        original = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = original.components(separatedBy: ",")
        let parsed = parts.compactMap { Clause(value: $0) }
        guard parsed.count == parts.count else { return nil }
        if type != .depends, type != .preDepends, parsed.contains(where: { $0.elements.count != 1 }) {
            return nil
        }
        if type == .provides, parsed.flatMap(\.elements).contains(where: {
            $0.versionType != .noneSpecific && $0.versionType != .equal
        }) {
            return nil
        }
        requirements = parsed
    }
}
