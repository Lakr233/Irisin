import AptRepository
import Foundation
import LibSolv

/// The half of a solve no request changes, read once and kept.
///
/// Solving a request against a hundred repositories is nearly all this:
/// every candidate the catalogue offers read into a record, its relations
/// parsed and matched against every provider, and the libsolv definition
/// each record is added to the pool as. The request only adds its jobs.
/// A pool is read off the main actor from one snapshot, and answers for
/// another only while every input it was read from is the same
/// (`serves`); `PackageResolver` reads a fresh one otherwise, so a pool
/// kept too long costs time and never a plan.
///
/// The records are the ones a solve without a pool reads, in the same
/// order and with the same indices, so the solver is handed the same
/// definitions either way.
public struct ResolutionPool: Sendable {
    /// What the pool was read from. A later snapshot takes its catalogue
    /// while the database has not been written since
    /// (`PackageIndex.resolutionSnapshot(reusingCatalogueOf:)`).
    public let snapshot: ResolutionSnapshot
    /// The installed packages in identity order, each read into `records`
    /// or refused with why. Reading stops at the first one refused: no
    /// request gets past it, so nothing after it was read.
    let installed: [Result<Int, ResolutionFailure>]
    /// `snapshot.installed` in identity order, as the records were read.
    let installedPackages: [Package]
    let records: [PoolPackage]
    /// Every version the catalogue offers that installs here, one record
    /// each, in the order the records were read; readable or not.
    let candidates: [Package]
    /// A candidate's position in `candidates`.
    let offered: [Package: Int]
    /// The record a candidate became, by its position in `candidates`; nil
    /// for one that does not parse.
    let recordOfCandidate: [Int?]
    /// Every candidate that does not parse, and why. Only those a plan
    /// touches become its diagnostics: one broken paragraph in one of a
    /// hundred repositories is not every transaction's business.
    let unreadable: [Package: ResolutionFailure.Reason]
    /// The same, in the order of `candidates`.
    let unreadableInOrder: [(Package, ResolutionFailure.Reason)]
    /// Records an adapter would have to rewrite: they go to a repository
    /// of their own.
    let adapted: Set<Int>
    let universe: PackageUniverse
    /// Every relation's witnesses, which `definition(of:)` hands libsolv.
    let wiring: Wiring

    /// Reads the pool of `snapshot`. Throws `CancellationError` once its
    /// task is cancelled.
    public init(snapshot: ResolutionSnapshot) throws {
        try self.init(snapshot: snapshot, requested: [])
    }

    /// `requested` are packages a request names that the catalogue may not
    /// offer (a `.deb` on disk, another repository's copy of an installed
    /// package): they join the candidates as a solve without a pool takes
    /// them, and a pool read with any of them is that request's alone.
    init(snapshot: ResolutionSnapshot, requested: [Package]) throws {
        self.snapshot = snapshot
        installedPackages = snapshot.installed.sorted(by: { $0.identity < $1.identity })
        var records: [PoolPackage] = []
        var installed: [Result<Int, ResolutionFailure>] = []
        var refused = false
        for package in installedPackages {
            do {
                try records.append(PoolPackage(reading: package, installed: true, in: snapshot))
                installed.append(.success(records.count - 1))
            } catch {
                installed.append(.failure(error as? ResolutionFailure ?? ResolutionFailure(.unknown)))
                refused = true
                break
            }
        }
        self.installed = installed
        var candidates: [Package] = []
        var offered: [Package: Int] = [:]
        var recordOfCandidate: [Int?] = []
        var unreadable: [Package: ResolutionFailure.Reason] = [:]
        var adapted = Set<Int>()
        // a refused installed package fails every request before the
        // candidates are looked at: there is no point reading them
        if !refused {
            // an installed identity follows the repository it came from: the
            // other repositories' copies are not candidates for it, unless the
            // user asked for one of them by name, which a request's own
            // pool takes in `requested`
            var available = snapshot.packages.filter { package in
                snapshot.origins[package.identity].map { $0 == package.repoRef } ?? true
            }
            available += requested
            // the sort is stable: a requested package the catalogue already
            // offers comes after the catalogue's copy, whose records it
            // repeats, so the candidates are the catalogue's in either case
            available.sort {
                ($0.repoRef?.absoluteString ?? "", $0.identity) < ($1.repoRef?.absoluteString ?? "", $1.identity)
            }
            for (step, package) in available.enumerated() {
                if step % 1024 == 0 {
                    try Task.checkCancellation()
                }
                for version in package.payload.keys.sorted(by: { DebianVersion.compare($0, $1) > 0 }) {
                    let record = Package(
                        identity: package.identity,
                        payload: [version: package.payload[version]!],
                        repoRef: package.repoRef
                    )
                    guard record.supports(anyOf: snapshot.installableArchitectures),
                          offered[record] == nil
                    else { continue }
                    offered[record] = candidates.count
                    candidates.append(record)
                }
            }
            recordOfCandidate.reserveCapacity(candidates.count)
            for (step, record) in candidates.enumerated() {
                if step % 1024 == 0 {
                    try Task.checkCancellation()
                }
                do {
                    try records.append(PoolPackage(reading: record, installed: false, in: snapshot))
                    recordOfCandidate.append(records.count - 1)
                    if snapshot.adapts(record) {
                        adapted.insert(records.count - 1)
                    }
                } catch {
                    recordOfCandidate.append(nil)
                    unreadable[record] = (error as? ResolutionFailure)?.reason ?? .unknown
                }
            }
        }
        self.candidates = candidates
        self.offered = offered
        self.recordOfCandidate = recordOfCandidate
        self.unreadable = unreadable
        unreadableInOrder = candidates.indices.compactMap { position in
            recordOfCandidate[position] == nil ? (candidates[position], unreadable[candidates[position]] ?? .unknown) : nil
        }
        self.adapted = adapted
        self.records = records
        let universe = PackageUniverse(packages: records, architecture: snapshot.architecture)
        self.universe = universe
        wiring = try Wiring(records: records, universe: universe)
    }

    /// Whether this pool is the one `snapshot` reads: the same catalogue
    /// (database and revision), installed packages, architectures, origins
    /// and adapted control paragraphs. A snapshot made by hand names no
    /// database and is never served.
    public func serves(_ snapshot: ResolutionSnapshot) -> Bool {
        self.snapshot.sharesCatalogue(with: snapshot)
            && self.snapshot.architecture == snapshot.architecture
            && self.snapshot.installableArchitectures == snapshot.installableArchitectures
            && self.snapshot.origins == snapshot.origins
            && self.snapshot.adaptedManifests == snapshot.adaptedManifests
            && installedPackages == snapshot.installed.sorted(by: { $0.identity < $1.identity })
    }

    /// Whether every version `request` installs is already a candidate
    /// here, so that the request adds nothing to the pool.
    func offers(_ request: ResolutionRequest) -> Bool {
        request.actions.allSatisfy { action in
            guard case let .install(package) = action else { return true }
            return package.payload.allSatisfy { version, metadata in
                let record = Package(identity: package.identity, payload: [version: metadata], repoRef: package.repoRef)
                return !record.supports(anyOf: snapshot.installableArchitectures) || offered[record] != nil
            }
        }
    }

    enum Offer {
        case record(Int)
        case unreadable(ResolutionFailure.Reason)
    }

    /// The record of a candidate, or why it does not parse; nil when the
    /// catalogue does not offer it here.
    func offer(of package: Package) -> Offer? {
        guard let position = offered[package] else { return nil }
        if let index = recordOfCandidate[position] {
            return .record(index)
        }
        return .unreadable(unreadable[package] ?? .unknown)
    }

    static func token(_ index: Int) -> String {
        "irisin-record:\(index)"
    }

    /// What record `index` is added to libsolv as: provides its own token;
    /// requires, for each Depends and Pre-Depends relation, any of the
    /// tokens of its witnesses, or a name nothing provides when it has
    /// none; conflicts with every other witness of its Conflicts and Breaks.
    func definition(of index: Int) -> PackageDefinition {
        let record = records[index]
        var definition = PackageDefinition(
            name: record.name,
            version: PoolPackage.solvVersion(record.version),
            architecture: record.architecture
        )
        definition.provides = [.named(wiring.tokens[index])]
        let relations = wiring.relations(of: index)
        for (kind, range) in [(PoolPackage.Group.Kind.depends, relations.depends), (.preDepends, relations.preDepends)] {
            let clauses = record.relations[kind] ?? []
            let dependencies = range.map { relation -> Dependency in
                let witnesses = wiring.witnesses(ofRelation: relation)
                guard let first = witnesses.first else {
                    return .named("missing:\(record.name):\(clauses[relation - range.lowerBound].original)")
                }
                return witnesses.dropFirst().reduce(.named(wiring.tokens[Int(first)])) {
                    .anyOf($0, .named(wiring.tokens[Int($1)]))
                }
            }
            if kind == .depends {
                definition.requires = dependencies
            } else {
                definition.prerequisites = dependencies
            }
        }
        // Breaks restricts the final configured set. Its weaker unpack-time
        // semantics are preserved separately by TransactionPlanner.
        definition.conflicts = wiring.conflicts(of: index).map { .named(wiring.tokens[Int($0)]) }
        return definition
    }

    /// Which records witness each record's relations, flat: the matching is
    /// the expensive half of a definition and a few integers to keep,
    /// where a `Dependency` tree per relation is a few allocations each.
    struct Wiring: Sendable {
        /// `ResolutionPool.token` of every record, made once.
        let tokens: [String]
        /// The witnesses of every Depends and Pre-Depends relation, one
        /// relation after another in record order.
        private let links: [Int32]
        /// Where each relation's witnesses end in `links`.
        private let relationEnds: [Int32]
        /// Where each record's Depends and its Pre-Depends end among the
        /// relations.
        private let dependsEnds: [Int32]
        private let preDependsEnds: [Int32]
        /// The witnesses of every record's Conflicts and Breaks, but itself.
        private let conflictLinks: [Int32]
        private let conflictEnds: [Int32]

        init(records: [PoolPackage], universe: PackageUniverse) throws {
            var links: [Int32] = []
            var relationEnds: [Int32] = []
            var dependsEnds: [Int32] = []
            var preDependsEnds: [Int32] = []
            var conflictLinks: [Int32] = []
            var conflictEnds: [Int32] = []
            dependsEnds.reserveCapacity(records.count)
            preDependsEnds.reserveCapacity(records.count)
            conflictEnds.reserveCapacity(records.count)
            for (index, record) in records.enumerated() {
                if index % 1024 == 0 {
                    try Task.checkCancellation()
                }
                for kind in [PoolPackage.Group.Kind.depends, .preDepends] {
                    for relation in record.relations[kind] ?? [] {
                        links += universe.witnesses(relation).map { Int32($0) }
                        relationEnds.append(Int32(links.count))
                    }
                    if kind == .depends {
                        dependsEnds.append(Int32(relationEnds.count))
                    } else {
                        preDependsEnds.append(Int32(relationEnds.count))
                    }
                }
                for kind in [PoolPackage.Group.Kind.conflicts, .breaks] {
                    for relation in record.relations[kind] ?? [] {
                        conflictLinks += universe.witnesses(relation).filter { $0 != index }.map { Int32($0) }
                    }
                }
                conflictEnds.append(Int32(conflictLinks.count))
            }
            tokens = records.indices.map(ResolutionPool.token)
            self.links = links
            self.relationEnds = relationEnds
            self.dependsEnds = dependsEnds
            self.preDependsEnds = preDependsEnds
            self.conflictLinks = conflictLinks
            self.conflictEnds = conflictEnds
        }

        /// The positions of record `index`'s Depends and Pre-Depends
        /// relations, in the order its control paragraph lists them.
        func relations(of index: Int) -> (depends: Range<Int>, preDepends: Range<Int>) {
            let start = index == 0 ? 0 : Int(preDependsEnds[index - 1])
            let middle = Int(dependsEnds[index])
            return (start ..< middle, middle ..< Int(preDependsEnds[index]))
        }

        func witnesses(ofRelation relation: Int) -> ArraySlice<Int32> {
            links[(relation == 0 ? 0 : Int(relationEnds[relation - 1])) ..< Int(relationEnds[relation])]
        }

        func conflicts(of index: Int) -> ArraySlice<Int32> {
            conflictLinks[(index == 0 ? 0 : Int(conflictEnds[index - 1])) ..< Int(conflictEnds[index])]
        }
    }
}
