import AptRepository

/// Pre-indexed witnesses keep relation translation proportional to actual
/// providers rather than comparing every relationship with the whole catalogue.
struct PackageUniverse: Sendable {
    let packages: [PoolPackage]
    let providers: [String: [Int]]
    let architecture: String

    init(packages: [PoolPackage], architecture: String) {
        self.packages = packages
        self.architecture = architecture
        var providers: [String: [Int]] = [:]
        for (index, package) in packages.enumerated() {
            for capability in package.capabilities {
                providers[capability, default: []].append(index)
            }
        }
        self.providers = providers
    }

    func witnesses(_ requirement: PoolPackage.Group.Clause) -> [Int] {
        var seen = Set<Int>()
        return requirement.elements.flatMap { element in
            (providers[element.representPackage] ?? []).filter {
                packages[$0].satisfies(element, architecture: architecture) && seen.insert($0).inserted
            }
        }
    }

    func satisfied(_ requirement: PoolPackage.Group.Clause, in selected: Set<Int>) -> Bool {
        witnesses(requirement).contains { selected.contains($0) }
    }

    /// What `validate` would refuse in `selected`: each package with a
    /// Depends or Pre-Depends nothing there satisfies, and both sides of a
    /// Conflicts or Breaks that meets a package there.
    func broken(in selected: Set<Int>) -> Set<Int> {
        var found = Set<Int>()
        for index in selected {
            let package = packages[index]
            for kind in [PoolPackage.Group.Kind.depends, .preDepends] {
                if (package.relations[kind] ?? []).contains(where: { !satisfied($0, in: selected) }) {
                    found.insert(index)
                }
            }
            for kind in [PoolPackage.Group.Kind.conflicts, .breaks] {
                for relationship in package.relations[kind] ?? [] {
                    let met = witnesses(relationship).filter { $0 != index && selected.contains($0) }
                    if !met.isEmpty {
                        found.insert(index)
                        found.formUnion(met)
                    }
                }
            }
        }
        return found
    }

    func validate(_ selected: Set<Int>) throws {
        var names = Set<String>()
        for index in selected.sorted() {
            let package = packages[index]
            guard names.insert(package.name).inserted else {
                throw ResolutionFailure(.ambiguousVersion(package: package.name))
            }
            for kind in [PoolPackage.Group.Kind.depends, .preDepends] {
                for relationship in package.relations[kind] ?? [] where !satisfied(relationship, in: selected) {
                    throw ResolutionFailure(
                        .missingRequirement(package: package.name, requirement: relationship.original)
                    )
                }
            }
            for kind in [PoolPackage.Group.Kind.conflicts, .breaks] {
                for relationship in package.relations[kind] ?? []
                    where witnesses(relationship).contains(where: { $0 != index && selected.contains($0) })
                {
                    throw ResolutionFailure(.conflict(package: package.name, requirement: relationship.original))
                }
            }
        }
    }
}
