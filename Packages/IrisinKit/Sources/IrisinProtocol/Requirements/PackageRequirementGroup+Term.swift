import Foundation

public extension PackageRequirementGroup.Clause {
    struct Term: Codable, Hashable, Sendable {
        public let original: String
        public let representPackage: String
        public let architectureQualifier: String?
        public let versionValue: String
        public let versionType: VersionType

        init?(value: String) {
            original = value.trimmingCharacters(in: .whitespacesAndNewlines)
            var name = original
            var version = ""
            var relation = VersionType.noneSpecific
            if let open = original.firstIndex(of: "(") {
                guard original.hasSuffix(")") else { return nil }
                name = String(original[..<open]).trimmingCharacters(in: .whitespaces)
                let constraint = original[original.index(after: open) ..< original.index(before: original.endIndex)]
                    .trimmingCharacters(in: .whitespaces)
                let op = String(constraint.prefix { "<=>".contains($0) })
                version = String(constraint.dropFirst(op.count)).trimmingCharacters(in: .whitespaces)
                guard DebianVersion.isValid(version) else { return nil }
                switch op {
                case ">>": relation = .greater
                case ">=", ">": relation = .greaterOrEqual
                // dpkg accepts a bare parenthesized version as an exact match.
                case "=", "": relation = .equal
                case "<<": relation = .smaller
                case "<=", "<": relation = .smallerOrEqual
                default: return nil
                }
            }
            let parts = name.lowercased().split(separator: ":", omittingEmptySubsequences: false)
            guard (1 ... 2).contains(parts.count), Self.validName(parts[0]) else { return nil }
            if parts.count == 2, !Self.validName(parts[1]) {
                return nil
            }
            representPackage = String(parts[0])
            architectureQualifier = parts.count == 2 ? String(parts[1]) : nil
            versionValue = version
            versionType = relation
        }

        private static func validName(_ name: Substring) -> Bool {
            guard let first = name.utf8.first,
                  (97 ... 122).contains(first) || (48 ... 57).contains(first)
            else { return false }
            return name.utf8.allSatisfy {
                (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 || $0 == 95
            }
        }

        public func doesThisVersionMatchesRequirement(version: String) -> Bool {
            guard versionType != .noneSpecific else { return true }
            guard let version = DebianVersion.parse(version), let wanted = DebianVersion.parse(versionValue)
            else { return false }
            let comparison = DebianVersion.compare(version, wanted)
            switch versionType {
            case .greater: return comparison > 0
            case .greaterOrEqual: return comparison >= 0
            case .equal: return comparison == 0
            case .smaller: return comparison < 0
            case .smallerOrEqual: return comparison <= 0
            case .noneSpecific: return true
            }
        }
    }
}
