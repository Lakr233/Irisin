import AptRepository
import Foundation
import IrisinProtocol
import LibSolv

public enum PackageResolver {
    public static func resolve(request: ResolutionRequest, snapshot: ResolutionSnapshot) throws -> ResolutionPlan {
        do {
            return try solve(request: request, snapshot: snapshot)
        } catch {
            // the failure's own evidence first: it names what went wrong
            let checks = ((error as? ResolutionFailure)?.checks ?? [])
                + ResolutionDiagnostics.checks(request: request, snapshot: snapshot)
            var reason = (error as? ResolutionFailure)?.reason ?? .unknown
            if reason == .noPlan || error is LibSolv.ResolutionFailure, !checks.isEmpty {
                // Private SAT token names are implementation details. The
                // evidence rows explain which real package requirement failed.
                let unmatched: Set<ResolutionCheck.Outcome> = [
                    .missing, .incompatibleArchitecture, .noMatchingVersion, .invalidMetadata,
                ]
                reason = checks.contains { unmatched.contains($0.outcome) }
                    ? .requirementsUnmatched
                    : .requirementsConflict
            }
            throw ResolutionFailure(reason, checks: checks)
        }
    }

    private static func solve(request: ResolutionRequest, snapshot: ResolutionSnapshot) throws -> ResolutionPlan {
        var actions: [String: ResolutionAction] = [:]
        for action in request.actions {
            actions[action.identity] = action
        }
        var records: [PoolPackage] = []
        var diagnostics: [ResolutionFailure.Reason] = []
        for package in snapshot.installed.sorted(by: { $0.identity < $1.identity }) {
            try records.append(PoolPackage(package, installed: true, action: actions[package.identity], in: snapshot))
        }
        // an installed identity follows the repository it came from: the
        // other repositories' copies are not candidates for it, unless the
        // user asked for one of them by name, which is the explicit action
        // appended below
        var available = snapshot.packages.filter { package in
            snapshot.origins[package.identity].map { $0 == package.repoRef } ?? true
        }
        for action in actions.values {
            if case let .install(package) = action {
                available.append(package)
            }
        }
        available.sort {
            ($0.repoRef?.absoluteString ?? "", $0.identity) < ($1.repoRef?.absoluteString ?? "", $1.identity)
        }
        var seen = Set<Package>()
        var candidates: [Package] = []
        for package in available {
            for version in package.payload.keys.sorted(by: { DebianVersion.compare($0, $1) > 0 }) {
                let record = Package(
                    identity: package.identity,
                    payload: [version: package.payload[version]!],
                    repoRef: package.repoRef
                )
                guard record.supports(anyOf: snapshot.installableArchitectures),
                      seen.insert(record).inserted
                else { continue }
                candidates.append(record)
            }
        }
        // Which records an adapter would have to rewrite, by their index in
        // `records`: they go to a repository of their own below.
        var adapted = Set<Int>()
        for record in candidates {
            do {
                try records.append(PoolPackage(record, installed: false, in: snapshot))
                if snapshot.adapts(record) {
                    adapted.insert(records.count - 1)
                }
            } catch {
                diagnostics.append((error as? ResolutionFailure)?.reason ?? .unknown)
            }
        }
        let universe = PackageUniverse(packages: records, architecture: snapshot.architecture)
        let environment = try SolverEnvironment(distribution: .debian, architecture: snapshot.architecture)
        let installedRepository = try environment.addRepository(name: "installed")
        let availableRepository = try environment.addRepository(name: "available")
        // A package built for this bootstrap beats one an adapter would have
        // to rewrite, whatever their versions and repositories: libsolv
        // prunes candidates by repository priority before version. The
        // adapted one stays in the pool, so a dependency only it can satisfy
        // still solves — dropping it answered such a dependency with a
        // conflict whose every check read matched.
        let adaptedRepository = try environment.addRepository(name: "adapted", priority: -1)
        try environment.setInstalledRepository(installedRepository)
        var ids: [PackageID] = []
        let installed = Set(records.indices.filter { records[$0].installed })
        let installedByName = Dictionary(uniqueKeysWithValues: installed.map { (records[$0].name, $0) })
        for (index, record) in records.enumerated() {
            var definition = PackageDefinition(
                name: record.name,
                version: PoolPackage.solvVersion(record.version),
                architecture: record.architecture
            )
            definition.provides = [.named(token(index))]
            for kind in [PoolPackage.Group.Kind.depends, .preDepends] {
                let dependencies = (record.relations[kind] ?? []).map { relation -> Dependency in
                    let witnesses = universe.witnesses(relation)
                    return disjunction(
                        witnesses.map { .named(token($0)) },
                        missing: "missing:\(record.name):\(relation.original)"
                    )
                }
                if kind == .depends {
                    definition.requires = dependencies
                } else {
                    definition.prerequisites = dependencies
                }
            }
            // Breaks restricts the final configured set. Its weaker unpack-time
            // semantics are preserved separately by TransactionPlanner.
            for kind in [PoolPackage.Group.Kind.conflicts, .breaks] {
                for relation in record.relations[kind] ?? [] {
                    definition.conflicts += universe.witnesses(relation)
                        .filter { $0 != index }
                        .map { .named(token($0)) }
                }
            }
            let repository = if record.installed {
                installedRepository
            } else if adapted.contains(index) {
                adaptedRepository
            } else {
                availableRepository
            }
            try ids.append(environment.addPackage(definition, to: repository))
        }
        var jobs: [Job] = []
        var explicitInstall = Set<Int>()
        var explicitRemove = Set<String>()
        for name in actions.keys.sorted() {
            switch actions[name]! {
            case let .install(package):
                guard let version = package.latestVersion, let metadata = package.payload[version] else {
                    throw ResolutionFailure(.noVersion(package: name))
                }
                let requested = Package(
                    identity: package.identity,
                    payload: [version: metadata],
                    repoRef: package.repoRef
                )
                guard let index = records.indices.first(where: {
                    !records[$0].installed && records[$0].package == requested
                }) else {
                    throw ResolutionFailure(.versionUnavailable(package: name))
                }
                explicitInstall.insert(index)
                jobs.append(Job(.install, .package(ids[index])))
            case .remove:
                if let index = installedByName[name] {
                    explicitRemove.insert(name)
                    jobs.append(Job(.remove, .package(ids[index])))
                }
            }
        }
        /// what no plan may remove: everything protected, or once the user
        /// allows removing system packages, only the records the bootstrap
        /// writes for the device itself. No repository offers those again.
        func kept(_ record: PoolPackage) -> Bool {
            let device = record.name == "firmware" || record.name.hasPrefix("gsc.") || record.name.hasPrefix("cy+")
            return record.protected && !(request.allowSystemRemoval && !device)
        }
        for index in installed.sorted() {
            let record = records[index]
            if record.held || (request.updateAll && snapshot.blockedUpdates.contains(record.name)) {
                jobs.append(Job(.lock, .package(ids[index])))
            }
            if kept(record) {
                jobs.append(Job(.install, .name(record.name)))
            }
        }
        // Permit only explicitly requested downgrades. A global allowDowngrade
        // flag alone would also downgrade unrelated installed dependencies.
        for index in records.indices where !records[index].installed && !explicitInstall.contains(index) {
            if let old = installedByName[records[index].name],
               DebianVersion.compare(records[index].version, records[old].version) < 0
            {
                jobs.append(Job(.lock, .package(ids[index])))
            }
        }
        // Updating everything leaves a converted package where it is unless
        // the user asked otherwise: the newer version is kept out by name.
        let frozen = request.updateAll && !snapshot.offersAdaptedUpdates
            ? adapted.filter { installedByName[records[$0].name] != nil && !explicitInstall.contains($0) }
            : []
        for index in frozen.sorted() {
            jobs.append(Job(.lock, .package(ids[index])))
        }
        if request.updateAll {
            jobs.append(Job(.update, .all))
        }
        var options = SolverOptions()
        options.allowUninstall = !request.updateAll
        options.allowDowngrade = !explicitInstall.isEmpty
        options.installRecommendations = false
        let result: Resolution
        do { result = try environment.solve(jobs, options: options) }
        catch let failure as LibSolv.ResolutionFailure {
            // a removal the system keeps is the plainest cause to name
            for name in explicitRemove.sorted() {
                if let blocked = removalBlock(installedByName[name]!, base: installed, universe: universe, kept: kept) {
                    throw blocked
                }
            }
            var checks: [ResolutionCheck] = []
            for problem in failure.problems {
                var detail = problem
                for index in records.indices.reversed() {
                    detail = detail.replacingOccurrences(
                        of: token(index),
                        with: "\(records[index].name) (\(records[index].version))"
                    )
                }
                // A missing dependency is explained with architecture/version
                // evidence by ResolutionDiagnostics, without internal SAT names.
                guard !detail.contains("missing:") else { continue }
                checks.append(.init(package: "", requirement: detail, outcome: .conflictingRequirements))
            }
            throw ResolutionFailure(.noPlan, checks: checks)
        }
        let indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var selected = Set(result.installed.compactMap { indexByID[$0.id] })
        try universe.validate(selected)
        // apt's marks: a package keeps the mark its installed copy has, a new
        // one is automatic unless it was asked for, and a protected one never is
        let installedNames = Set(installed.map { records[$0].name })
        func isAuto(_ index: Int) -> Bool {
            let record = records[index]
            if record.protected {
                return false
            }
            if installedNames.contains(record.name) {
                return snapshot.autoInstalled.contains(record.name)
            }
            return !explicitInstall.contains(index)
        }
        // what the request names stays whatever its mark, and so does a held package
        let dependents = unneededDependents(in: selected, universe: universe) {
            records[$0].held || explicitInstall.contains($0) || !isAuto($0)
        }
        var everything: [String: [String]] = [:]
        for (index, users) in dependents {
            everything[records[index].name] = users.map { records[$0].name }.sorted()
        }
        // an unneeded package this plan would install goes without asking,
        // unless an unneeded one that stays depends on it
        let removed = ResolutionPlan.removable(
            request.autoremove.union(everything.keys.filter { !installedNames.contains($0) }),
            unneeded: everything
        )
        if !removed.isEmpty {
            selected = selected.filter { !removed.contains(records[$0].name) }
            try universe.validate(selected)
        }
        // offered as installed packages only: the new ones are settled above,
        // so an edge through one of them is folded into the installed
        // packages behind it
        func users(of name: String) -> [String] {
            var found = Set<String>()
            var pending = everything[name] ?? []
            while let next = pending.popLast() {
                if found.insert(next).inserted {
                    pending += everything[next] ?? []
                }
            }
            return found.filter { $0 != name && installedNames.contains($0) }.sorted()
        }
        var unneeded: [String: [String]] = [:]
        for name in everything.keys where installedNames.contains(name) {
            unneeded[name] = users(of: name)
        }
        // a removal the solver kept: the failure says what keeps it
        if let stayed = selected.first(where: { explicitRemove.contains(records[$0].name) }) {
            throw removalBlock(stayed, base: selected, universe: universe, kept: kept)
                ?? ResolutionFailure(.unresolvable)
        }
        // These indices identify full package records, including source and
        // archive metadata. Matching only identity/version would allow a
        // different file to stand in for the one the user chose.
        guard explicitInstall.isSubset(of: selected) else {
            throw ResolutionFailure(.unresolvable)
        }
        let finalNames = Set(selected.map { records[$0].name })
        for index in installed {
            let record = records[index]
            if kept(record), !finalNames.contains(record.name) {
                throw ResolutionFailure(.requiredBySystem(package: record.name))
            }
            if record.held, !selected.contains(index) {
                throw ResolutionFailure(.onHold(package: record.name))
            }
        }
        let additions = selected.subtracting(installed)
        let removals = installed.filter { !finalNames.contains(records[$0].name) }
        if request.updateAll, !removals.isEmpty {
            throw ResolutionFailure(.updateAllRemoves)
        }
        let stages = try TransactionPlanner.plan(universe: universe, selected: selected)
        let selectedByName = Dictionary(uniqueKeysWithValues: selected.map { (records[$0].name, $0) })
        var newestAvailable: [String: String] = [:]
        // a frozen version is not one the update left behind
        for (index, record) in records.enumerated() where !record.installed && !frozen.contains(index) {
            if newestAvailable[record.name].map({ DebianVersion.compare(record.version, $0) > 0 }) ?? true {
                newestAvailable[record.name] = record.version
            }
        }
        var heldBack: [String] = []
        if request.updateAll {
            for index in installed.sorted() {
                let name = records[index].name
                if let current = selectedByName[name], let newest = newestAvailable[name],
                   DebianVersion.compare(newest, records[current].version) > 0
                {
                    heldBack.append(records[index].name)
                }
            }
        }
        // the same edges the solver was given, read backwards: an addition is
        // required by every selected package whose relation it witnesses
        var requiredBy: [String: Set<String>] = [:]
        for index in selected {
            let record = records[index]
            for kind in [PoolPackage.Group.Kind.depends, .preDepends] {
                for relation in record.relations[kind] ?? [] {
                    for witness in universe.witnesses(relation) where additions.contains(witness) && witness != index {
                        requiredBy[records[witness].name, default: []].insert(record.name)
                    }
                }
            }
        }
        return ResolutionPlan(
            id: UUID(),
            snapshot: snapshot,
            install: additions.sorted().map { records[$0].package },
            remove: removals.sorted().map { records[$0].package },
            finalPackages: selected.sorted().map { records[$0].package },
            stages: stages,
            heldBack: heldBack.sorted(),
            diagnostics: diagnostics,
            requiredBy: requiredBy.mapValues { $0.sorted() },
            autoInstalled: additions.filter(isAuto).map { records[$0].name }.sorted(),
            unneeded: unneeded,
            recoveryMode: false
        )
    }

    /// apt's autoremove mark: from every root, follow Depends, Pre-Depends
    /// and the weak dependencies to each witness in `selected`. Each package
    /// left unmarked maps to the unmarked packages that depend on it.
    /// What stops the removal of `removed` from `base`: the system requires
    /// it, or requires a package that would have to go with it, or a held
    /// package would. Nil when nothing does.
    private static func removalBlock(
        _ removed: Int,
        base: Set<Int>,
        universe: PackageUniverse,
        kept: (PoolPackage) -> Bool
    ) -> ResolutionFailure? {
        let packages = universe.packages
        let name = packages[removed].name
        if kept(packages[removed]) {
            return ResolutionFailure(
                .requiredBySystem(package: name),
                checks: [.init(package: name, requirement: name, outcome: .requiredBySystem)]
            )
        }
        // what leaves with it, as dpkg would take it: a package goes once
        // a relation it had satisfied has no witness left
        var gone: Set<Int> = [removed]
        var changed = true
        while changed {
            changed = false
            for index in base where !gone.contains(index) {
                let record = packages[index]
                let relations = (record.relations[.depends] ?? []) + (record.relations[.preDepends] ?? [])
                let broken = relations.contains { relation in
                    let witnesses = universe.witnesses(relation).filter(base.contains)
                    return !witnesses.isEmpty && witnesses.allSatisfy(gone.contains)
                }
                if broken {
                    gone.insert(index)
                    changed = true
                }
            }
        }
        let system = gone.filter { kept(packages[$0]) }.map { packages[$0].name }.sorted()
        if !system.isEmpty {
            return ResolutionFailure(
                .neededBySystem(package: name, dependents: system),
                checks: system.map { .init(package: name, requirement: $0, outcome: .requiredBySystem) }
            )
        }
        if let held = gone.filter({ packages[$0].held }).map({ packages[$0].name }).min() {
            return ResolutionFailure(.onHold(package: held))
        }
        return nil
    }

    private static func unneededDependents(
        in selected: Set<Int>,
        universe: PackageUniverse,
        isRoot: (Int) -> Bool
    ) -> [Int: Set<Int>] {
        func dependencies(_ index: Int) -> [Int] {
            let record = universe.packages[index]
            let relations = (record.relations[.depends] ?? []) + (record.relations[.preDepends] ?? [])
                + record.weakDependencies
            return relations.flatMap(universe.witnesses).filter { $0 != index && selected.contains($0) }
        }
        var marked = Set<Int>()
        var pending = Array(selected.filter(isRoot))
        while let index = pending.popLast() {
            guard marked.insert(index).inserted else { continue }
            pending += dependencies(index).filter { !marked.contains($0) }
        }
        let unmarked = selected.subtracting(marked)
        var dependents = Dictionary(uniqueKeysWithValues: unmarked.map { ($0, Set<Int>()) })
        for index in unmarked {
            for dependency in dependencies(index) where unmarked.contains(dependency) {
                dependents[dependency]!.insert(index)
            }
        }
        return dependents
    }

    private static func token(_ index: Int) -> String {
        "irisin-record:\(index)"
    }

    private static func disjunction(_ values: [Dependency], missing: String) -> Dependency {
        guard let first = values.first else { return .named(missing) }
        return values.dropFirst().reduce(first) { .anyOf($0, $1) }
    }
}
