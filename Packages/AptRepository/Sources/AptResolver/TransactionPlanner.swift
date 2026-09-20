import AptRepository
import IrisinProtocol

/// Simulates dpkg's present/configured states. Every emitted stage must be
/// executable in the state left by the preceding stage; final-set SAT alone
/// cannot establish this property.
enum TransactionPlanner {
    static func plan(universe: PackageUniverse, selected: Set<Int>) throws -> [InstallerStage] {
        let packages = universe.packages
        var present = Set(packages.indices.filter { packages[$0].installed })
        var configured = Set(present.filter { packages[$0].configured })
        var unpack = selected.subtracting(present)
        let finalNames = Set(selected.map { packages[$0].name })
        var remove = Set(present.filter { !finalNames.contains(packages[$0].name) })
        var stages: [InstallerStage] = []
        var ordered = true

        func requirementsSatisfied(
            _ index: Int,
            in available: Set<Int>,
            kinds: [PoolPackage.Group.Kind]
        ) -> Bool {
            kinds.allSatisfy { kind in
                (packages[index].relations[kind] ?? []).allSatisfy { universe.satisfied($0, in: available) }
            }
        }
        func conflicts(_ lhs: Int, _ rhs: Int, kind: PoolPackage.Group.Kind) -> Bool {
            guard packages[lhs].name != packages[rhs].name else { return false }
            return (packages[lhs].relations[kind] ?? []).contains { universe.witnesses($0).contains(rhs) }
        }
        /// The Depends and Pre-Depends witnesses of a package, through Provides.
        func dependencies(_ index: Int) -> [Int] {
            [PoolPackage.Group.Kind.depends, .preDepends]
                .flatMap { packages[index].relations[$0] ?? [] }
                .flatMap(universe.witnesses)
                .filter { $0 != index }
        }
        /// `members` with every package after the dependencies it has among
        /// them; a cycle keeps index order. The helper runs a stage's
        /// packages in list order.
        func dependenciesFirst(_ members: Set<Int>) -> [Int] {
            var edges: [Int: [Int]] = [:]
            for index in members {
                edges[index] = dependencies(index).filter(members.contains)
            }
            return StronglyConnectedComponents.components(edges).flatMap { $0.sorted() }
        }

        while !unpack.isEmpty || !remove.isEmpty || !selected.isSubset(of: configured) {
            var progress = false
            // Remove the largest safe subset. Reverse dependants in the same
            // batch can disappear together, including ordinary dependency cycles.
            var removable = remove
            var changed = true
            while changed {
                changed = false
                let remaining = present.subtracting(removable)
                for dependent in configured.subtracting(removable) {
                    for kind in [PoolPackage.Group.Kind.depends, .preDepends] {
                        for relation in packages[dependent].relations[kind] ?? []
                            where !universe.satisfied(relation, in: remaining)
                        {
                            let needed = Set(universe.witnesses(relation)).intersection(removable)
                            if !needed.isEmpty {
                                removable.subtract(needed); changed = true
                            }
                        }
                    }
                }
            }
            if !removable.isEmpty {
                // dpkg's checkforremoval: a package goes before what it
                // depends on, so its prerm still finds its dependencies.
                stages.append(.remove(dependenciesFirst(removable).reversed().map { packages[$0].name }))
                present.subtract(removable)
                configured.subtract(removable)
                remove.subtract(removable)
                progress = true
            }
            // An already configured old version can satisfy Pre-Depends here.
            // Upgrading it prematurely would lose that valid witness.
            // apt's OrderUnpack: dependencies unpack before their dependants,
            // so a provider's preinst never runs over a dependant's files. A
            // dependant waits with a dependency whose Pre-Depends are not
            // configured yet, unless waiting got nowhere.
            var waiting = Set<Int>()
            for index in dependenciesFirst(unpack) {
                guard !ordered || waiting.isDisjoint(with: dependencies(index)),
                      requirementsSatisfied(index, in: configured, kinds: [.preDepends])
                else {
                    waiting.insert(index)
                    continue
                }
                guard !present.contains(where: {
                    conflicts(index, $0, kind: .conflicts) || conflicts($0, index, kind: .conflicts)
                }) else { continue }
                let broken = Set(configured.filter {
                    conflicts(index, $0, kind: .breaks) || conflicts($0, index, kind: .breaks)
                })
                // dpkg --auto-deconfigure may deconfigure these versions, but
                // each must have a replacement/removal in this same transaction.
                guard broken.allSatisfy({ !selected.contains($0) }) else { continue }
                let old = present.filter { packages[$0].name == packages[index].name }
                present.subtract(old)
                configured.subtract(old)
                configured.subtract(broken)
                present.insert(index)
                unpack.remove(index)
                stages.append(.unpack([packages[index].name]))
                progress = true
            }
            // Configure mutually dependent packages together. Compute SCCs over
            // the remaining present packages, using one available witness per OR.
            let pending = selected.intersection(present).subtracting(configured)
            var edges: [Int: [Int]] = [:]
            for index in pending {
                edges[index] = []
                for kind in [PoolPackage.Group.Kind.depends, .preDepends] {
                    for relation in packages[index].relations[kind] ?? [] {
                        let witnesses = universe.witnesses(relation)
                        if witnesses.contains(where: { configured.contains($0) }) {
                            continue
                        }
                        if let witness = witnesses.first(where: { pending.contains($0) }) {
                            edges[index, default: []].append(witness)
                        }
                    }
                }
            }
            for component in StronglyConnectedComponents.components(edges) {
                let available = configured.union(component)
                guard component.allSatisfy({
                    requirementsSatisfied($0, in: available, kinds: [.depends, .preDepends])
                }) else { continue }
                guard !component.contains(where: { index in
                    present.contains {
                        conflicts(index, $0, kind: .breaks) || conflicts($0, index, kind: .breaks)
                    }
                }) else { continue }
                stages.append(.configure(component.sorted().map { packages[$0].name }))
                configured.formUnion(component)
                progress = true
            }
            guard progress else {
                if ordered {
                    ordered = false
                    continue
                }
                let names = Set(
                    unpack.union(remove).union(selected.subtracting(configured)).map { packages[$0].name }
                ).sorted()
                throw ResolutionFailure(.noInstallOrder(packages: names))
            }
            ordered = true
        }
        guard present == selected else {
            throw ResolutionFailure(.orderUnplanned)
        }
        return stages
    }
}
