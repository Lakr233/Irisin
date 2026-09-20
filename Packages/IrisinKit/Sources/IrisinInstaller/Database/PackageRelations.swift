import IrisinProtocol

/// Validation shared by installation preflight, ownership takeover and stage
/// checks. The solver chooses packages; the installer verifies its inputs.
enum PackageRelations {
    typealias Group = PackageRequirementGroup

    static func groups(_ fields: [String: String], _ kind: Group.Kind) throws -> [Group.Clause] {
        guard let text = fields[kind.rawValue], !text.isEmpty else { return [] }
        guard let group = Group(value: text, type: kind)
        else { throw PackageFailure("Malformed \(kind.rawValue) in \(fields["package"] ?? "package")") }
        return group.requirements
    }

    /// `unconfigured` is dpkg's `allowunconfigd`, true for a Pre-Depends
    /// check alone: a package that is not configured then witnesses only if
    /// the version its postinst last configured satisfies the element too.
    static func matches(
        _ element: Group.Clause.Term,
        _ fields: [String: String],
        unconfigured: Bool = false
    ) -> Bool {
        if let qualifier = element.architectureQualifier {
            if qualifier == "any", fields["multi-arch"] != "allowed", fields["multi-arch"] != "foreign" {
                return false
            }
            if qualifier != "any", qualifier != "native", qualifier != fields["architecture"],
               fields["architecture"] != "all"
            {
                return false
            }
        }
        // Names on both sides are lowercase: the requirement parser lowercases
        // its own, and the database keys its records that way.
        if fields["package"]?.lowercased() == element.representPackage, let version = fields["version"],
           element.doesThisVersionMatchesRequirement(version: version)
        {
            if unconfigured, let configured = fields["config-version"],
               !["installed", "triggers-pending"].contains(PackageDatabase.state(of: fields)),
               !element.doesThisVersionMatchesRequirement(version: configured)
            {
                return false
            }
            return true
        }
        for provided in ((try? groups(fields, .provides)) ?? []).flatMap(\.elements)
            where provided.representPackage == element.representPackage
        {
            if element.versionType == .noneSpecific {
                return true
            }
            if provided.versionType == .equal,
               element.doesThisVersionMatchesRequirement(version: provided.versionValue)
            {
                return true
            }
        }
        return false
    }

    static func relates(
        _ fields: [String: String],
        _ kind: Group.Kind,
        to other: [String: String]
    ) throws -> Bool {
        try groups(fields, kind).contains { relation in relation.elements.contains { matches($0, other) } }
    }

    static func dependencies(
        _ fields: [String: String],
        kinds: [Group.Kind],
        available: [[String: String]],
        unconfigured: Bool = false
    ) throws {
        for kind in kinds {
            for group in try groups(fields, kind)
                where !group.elements.contains(where: { element in
                    available.contains { matches(element, $0, unconfigured: unconfigured) }
                })
            {
                throw PackageFailure(
                    "\(fields["package"] ?? "package"): unsatisfied \(kind.rawValue): \(group.original)"
                )
            }
        }
    }
}
