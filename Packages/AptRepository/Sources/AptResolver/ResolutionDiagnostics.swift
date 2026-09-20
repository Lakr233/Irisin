import AptRepository
import Foundation
import IrisinProtocol

/// Runs only after resolution fails. It uses the same parser and provider
/// matching as the solver, retaining incompatible architectures as evidence.
enum ResolutionDiagnostics {
    static func checks(request: ResolutionRequest, snapshot: ResolutionSnapshot) -> [ResolutionCheck] {
        var records: [PoolPackage] = []
        let requested = request.actions.compactMap { action -> Package? in
            if case let .install(package) = action {
                return package
            }
            return nil
        }
        var seen = Set<Package>()
        for package in snapshot.installed + snapshot.packages + requested {
            for (version, metadata) in package.payload {
                let candidate = Package(
                    identity: package.identity,
                    payload: [version: metadata],
                    repoRef: package.repoRef
                )
                guard seen.insert(candidate).inserted else { continue }
                if let record = try? PoolPackage(candidate, installed: metadata["status"] != nil, in: snapshot) {
                    records.append(record)
                }
            }
        }
        let universe = PackageUniverse(packages: records, architecture: snapshot.architecture)
        var checks: [ResolutionCheck] = []
        var pending: [PoolPackage] = []
        for package in requested {
            guard let version = package.latestVersion, let metadata = package.latestMetadata else {
                checks.append(.init(
                    package: package.identity,
                    requirement: package.identity,
                    outcome: .invalidMetadata
                ))
                continue
            }
            let candidate = Package(identity: package.identity, payload: [version: metadata], repoRef: package.repoRef)
            do {
                let record = try PoolPackage(candidate, installed: false, in: snapshot)
                let outcome: ResolutionCheck.Outcome = candidate.supports(anyOf: snapshot.installableArchitectures)
                    ? .matched
                    : .incompatibleArchitecture
                checks.append(.init(
                    package: package.identity,
                    requirement: package.identity + " " + version,
                    outcome: outcome,
                    candidates: [describe(record)]
                ))
                if outcome == .matched {
                    pending.append(record)
                }
            } catch {
                // the outcome says the metadata is unreadable; the row names what
                checks.append(.init(
                    package: package.identity,
                    requirement: package.identity + " " + version,
                    outcome: .invalidMetadata
                ))
            }
        }
        if request.updateAll {
            pending += records.filter(\.installed)
        }
        var visited = Set<Package>()
        var offset = 0
        while offset < pending.count {
            let owner = pending[offset]
            offset += 1
            guard visited.insert(owner.package).inserted else { continue }
            for kind in [PoolPackage.Group.Kind.preDepends, .depends] {
                for requirement in owner.relations[kind] ?? [] {
                    let named = Set(
                        requirement.elements.flatMap { universe.providers[$0.representPackage] ?? [] }
                    ).sorted()
                    let compatible = named.filter {
                        records[$0].package.supports(anyOf: snapshot.installableArchitectures)
                    }
                    let matching = universe.witnesses(requirement).filter { compatible.contains($0) }
                    let outcome: ResolutionCheck.Outcome = if !matching.isEmpty {
                        .matched
                    } else if named.isEmpty {
                        .missing
                    } else if compatible.isEmpty {
                        .incompatibleArchitecture
                    } else {
                        .noMatchingVersion
                    }
                    let evidence = matching.isEmpty ? named : matching
                    checks.append(.init(
                        package: owner.name,
                        requirement: requirement.original,
                        outcome: outcome,
                        candidates: representativeCandidates(evidence.map { records[$0] })
                    ))
                    // Prefer an installed witness, then a newest candidate. The
                    // checkmark describes availability, never a speculative plan.
                    let next = matching.sorted {
                        if records[$0].installed != records[$1].installed {
                            return records[$0].installed
                        }
                        return DebianVersion.compare(records[$0].version, records[$1].version) > 0
                    }.first
                    if let next {
                        pending.append(records[next])
                    }
                }
            }
        }
        var unique = Set<ResolutionCheck>()
        return checks.filter { unique.insert($0).inserted }
    }

    private static func describe(_ record: PoolPackage) -> String {
        let source = record.package.repoRef?.host ?? "installed"
        return "\(record.name) \(record.version) · \(record.fields["architecture"] ?? "all") · \(source)"
    }

    /// Show the newest relevant version from each source/architecture instead
    /// of burying the failed requirement beneath a repository's version history.
    private static func representativeCandidates(_ records: [PoolPackage]) -> [String] {
        let newestFirst = records.sorted {
            let comparison = DebianVersion.compare($0.version, $1.version)
            return comparison == 0 ? describe($0) < describe($1) : comparison > 0
        }
        var seen = Set<[String]>()
        return newestFirst.filter {
            seen.insert([
                $0.name,
                $0.fields["architecture"] ?? "all",
                $0.package.repoRef?.absoluteString ?? "installed",
            ]).inserted
        }.map(describe).sorted()
    }
}
