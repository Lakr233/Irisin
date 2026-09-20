import Foundation

public extension PackageRequirementGroup {
    struct Requirement: Codable, Sendable {
        public let elements: [RequirementElement]
        public let original: String

        init?(value: String) {
            original = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = original.components(separatedBy: "|")
            let parsed = parts.compactMap { RequirementElement(value: $0) }
            guard parsed.count == parts.count else { return nil }
            elements = parsed
        }
    }
}
