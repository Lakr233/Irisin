import Foundation

public extension PackageRequirementGroup {
    struct Clause: Codable, Sendable {
        public let elements: [Term]
        public let original: String

        init?(value: String) {
            original = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = original.components(separatedBy: "|")
            let parsed = parts.compactMap { Term(value: $0) }
            guard parsed.count == parts.count else { return nil }
            elements = parsed
        }
    }
}
