@_spi(Probe) import AptRepository
import AptResolver
import Foundation
import IrisinAdapter
import IrisinProtocol

/// The resolver against real repositories, read from disk. A fixture
/// directory holds `manifest.json` (each repository's address and its
/// index file, as `Scripts/fetch-repository-indexes.py` writes them) and
/// `indexes/`; the tool keeps its database, dpkg status and extended
/// states in `work/`.
///
/// - `catalogue` writes the database through the refresh's own parse, then
///   an installed system: a roothide bootstrap solved from a few seeds, and
///   tweaks from other repositories, some a version behind.
/// - `bench` times each request the way the queue sheet solves it: cold,
///   with nothing read ahead, then warm, against a `ResolutionPool` read
///   ahead as the queue's preflight reads it; and the preflight itself.
/// - `golden` writes every plan (or failure) of a fixed set of requests, for
///   `diff` against the plans another build writes; `--pool` solves them
///   the way the queue does, against one pool read ahead and kept.
@MainActor
enum CatalogueBench {
    nonisolated static let device = BootstrapArchitecture.roothide.rawValue
    nonisolated static let installable = PackageAdapters.installed.installable(on: device)

    static func run(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw ResolutionFailure(message: "no fixture directory") }
        let fixture = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let work = fixture.appendingPathComponent("work")
        if arguments[0] == "catalogue" {
            try? FileManager.default.removeItem(at: work)
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        AptEnvironment.bootstrap(AptEnvironment(
            workingLocation: work,
            dpkgStatusLocation: work.appendingPathComponent("status").path,
            aptExtendedStatesLocation: work.appendingPathComponent("extended_states").path,
            deviceArchitecture: { device },
            installableArchitectures: { installable },
            indexFallbacks: { BootstrapArchitecture.probeOrder.map(\.rawValue) },
            adaptedManifestPreview: {
                PackageAdapters.installed.resolveAdaptedPackageManifestPreview(control: $0, on: device)
            },
            storage: MemoryStorage(),
            logger: QuietLogger()
        ))
        switch arguments[0] {
        case "catalogue":
            try await catalogue(fixture: fixture, work: work)
        case "bench":
            try await bench(iterations: arguments.count > 2 ? Int(arguments[2]) ?? 7 : 7)
        default:
            guard arguments.count >= 3 else { throw ResolutionFailure(message: "no output file") }
            try await golden(to: URL(fileURLWithPath: arguments[2]), pooled: arguments.contains("--pool"))
        }
    }

    // MARK: - Catalogue

    struct ManifestEntry: Decodable {
        let url: String
        let file: String?
    }

    /// A roothide bootstrap's own packages; those the catalogue lacks are skipped.
    static let seeds = [
        "apt", "dpkg", "bash", "coreutils", "zsh", "openssh", "sudo", "curl", "wget", "vim", "nano",
        "less", "grep", "sed", "gawk", "findutils", "diffutils", "tar", "gzip", "xz-utils", "bzip2",
        "zstd", "unzip", "zip", "file", "ncurses-bin", "roothide", "uikittools", "plutil", "ldid",
    ]

    static func catalogue(fixture: URL, work: URL) async throws {
        let status = work.appendingPathComponent("status")
        try writeStatus([], to: status)
        let manifest = try JSONDecoder().decode(
            [ManifestEntry].self,
            from: Data(contentsOf: fixture.appendingPathComponent("manifest.json"))
        )
        var identities = 0
        for entry in manifest {
            guard let file = entry.file, let url = URL(string: entry.url) else { continue }
            let text = try String(contentsOf: fixture.appendingPathComponent(file), encoding: .utf8)
            identities += CatalogueFixture.store(index: text, of: url)
        }
        let index = PackageCenter.default.index
        var snapshot = try index.resolutionSnapshot()
        print("catalogue: \(manifest.count) repositories, \(identities) identities, \(snapshot.packages.count) rows")

        // the bootstrap
        let seeded = seeds.compactMap { candidate($0, in: snapshot, native: true) }
        let base = try PackageResolver.resolve(request: .init(actions: seeded.map { .install($0) }), snapshot: snapshot)
        var installed = base.finalPackages.filter { $0.identity != "firmware" }
        var sources = base.install
        try writeStatus(installed, to: status)
        try Data(base.autoInstalled.map { "Package: \($0)\nArchitecture: \(device)\nAuto-Installed: 1\n" }
            .joined(separator: "\n").utf8)
            .write(to: work.appendingPathComponent("extended_states"))
        print("bootstrap: \(seeded.count) seeds, \(installed.count) installed")

        // tweaks from other repositories: an older version where the
        // repository offers one, so updating everything has work to do
        snapshot = try index.resolutionSnapshot()
        let taken = Set(installed.map(\.identity))
        var byIdentity: [String: [Package]] = [:]
        for package in snapshot.packages where !taken.contains(package.identity) {
            guard package.repoRef?.absoluteString.contains("procursus") == false else { continue }
            byIdentity[package.identity, default: []].append(package)
        }
        var older = 0, newest = 0, tried = 0
        for identity in byIdentity.keys.sorted() where older + newest < 24 && tried < 400 {
            guard let package = byIdentity[identity]!.min(by: {
                ($0.repoRef?.absoluteString ?? "") < ($1.repoRef?.absoluteString ?? "")
            }),
                let versions = package.versions(supportingAnyOf: [device])
            else { continue }
            let ordered = versions.payload.keys.sorted { DebianVersion.compare($0, $1) > 0 }
            let wantsOlder: Bool
            if older < 12, ordered.count >= 2 {
                wantsOlder = true
            } else if newest < 12 {
                wantsOlder = false
            } else {
                continue
            }
            let version = wantsOlder ? ordered[1] : ordered[0]
            tried += 1
            let single = Package(identity: identity, payload: [version: versions.payload[version]!], repoRef: package.repoRef)
            guard let plan = try? PackageResolver.resolve(request: .init(actions: [.install(single)]), snapshot: snapshot),
                  plan.install.map(\.identity) == [identity], plan.remove.isEmpty
            else { continue }
            installed.append(single)
            sources.append(single)
            try writeStatus(installed, to: status)
            snapshot = try index.resolutionSnapshot()
            if wantsOlder {
                older += 1
            } else {
                newest += 1
            }
        }
        await PackageCenter.default.reloadLocalPackages(installedFrom: sources)
        snapshot = try index.resolutionSnapshot()
        print("tweaks: \(older) a version behind, \(newest) current; \(snapshot.installed.count) installed, \(snapshot.origins.count) origins")
    }

    /// dpkg's status for these packages, installed and configured, beside
    /// the device's firmware at 16.5.
    static func writeStatus(_ packages: [Package], to url: URL) throws {
        let kept = [
            "package", "version", "architecture", "maintainer", "installed-size", "depends", "pre-depends",
            "provides", "conflicts", "breaks", "replaces", "recommends", "suggests", "essential", "priority",
            "section", "name", "multi-arch", "protected",
        ]
        var paragraphs = ["Package: firmware\nStatus: install ok installed\nVersion: 16.5\nArchitecture: \(device)\nEssential: yes\nPriority: required"]
        for package in packages.sorted(by: { $0.identity < $1.identity }) {
            var fields = package.latestMetadata ?? [:]
            fields["package"] = package.identity
            fields["version"] = package.latestVersion
            var lines = ["Status: install ok installed"]
            for key in kept {
                guard let value = fields[key], !value.isEmpty else { continue }
                lines.append("\(key.capitalized): \(value.replacingOccurrences(of: "\n", with: " "))")
            }
            paragraphs.append(lines.joined(separator: "\n"))
        }
        try Data((paragraphs.joined(separator: "\n\n") + "\n").utf8).write(to: url)
    }

    /// The version the package page would install: the best fit for this
    /// bootstrap (its own build, then `all`, then one an adapter rewrites),
    /// the newest of those, from the first repository by address.
    static func candidate(_ identity: String, in snapshot: ResolutionSnapshot, native: Bool = false) -> Package? {
        var best: (fit: Int, version: String, repo: String, package: Package)?
        for package in snapshot.packages where package.identity == identity {
            for (version, metadata) in package.payload {
                let architectures = Package.architectures(in: metadata)
                let fit = architectures.contains(device) ? 3 : architectures.contains("all") ? 2
                    : architectures.contains(where: installable.contains) ? 1 : 0
                guard fit > (native ? 1 : 0) else { continue }
                let repo = package.repoRef?.absoluteString ?? ""
                if let current = best {
                    let order = DebianVersion.compare(version, current.version)
                    guard fit > current.fit || (fit == current.fit && (order > 0 || (order == 0 && repo < current.repo)))
                    else { continue }
                }
                best = (fit, version, repo, Package(identity: identity, payload: [version: metadata], repoRef: package.repoRef))
            }
        }
        return best?.package
    }

    // MARK: - Requests

    struct Scenario {
        let name: String
        let request: ResolutionRequest
        /// The queue sheet's update of everything: the update's own plan
        /// first, then its installs proposed as a queue.
        var twoStep = false
    }

    static func scenarios(_ snapshot: ResolutionSnapshot) -> [Scenario] {
        let installed = Set(snapshot.installed.map(\.identity))
        func install(_ name: String, _ identities: [String]) -> Scenario? {
            let packages = identities.compactMap { candidate($0, in: snapshot) }
            guard packages.count == identities.count else { return nil }
            return Scenario(name: name, request: .init(actions: packages.map { .install($0) }))
        }
        var result: [Scenario] = []
        result += [install("install tweak with deps (NoAppThinning)", ["com.netskao.noappthinning"])].compactMap(\.self)
        // no relations at all, built for this bootstrap
        let alone = snapshot.packages
            .filter { !installed.contains($0.identity) && $0.supports(architecture: device) }
            .filter { ($0.latestMetadata?["depends"] ?? "").isEmpty && ($0.latestMetadata?["pre-depends"] ?? "").isEmpty }
            .map(\.identity).sorted().first
        if let alone {
            result += [install("install package with no deps (\(alone))", [alone])].compactMap(\.self)
        }
        for heavy in ["ffmpeg", "git", "python3", "neofetch"] where !installed.contains(heavy) {
            if let scenario = install("install package with many deps (\(heavy))", [heavy]) {
                result.append(scenario)
                break
            }
        }
        result.append(Scenario(name: "update all", request: .init(updateAll: true), twoStep: true))
        result.append(Scenario(name: "remove openssh", request: .init(actions: [.remove("openssh")])))
        // refused: the failure is explained against the whole catalogue
        result.append(Scenario(name: "remove bash (refused)", request: .init(actions: [.remove("bash")])))
        return result
    }

    /// Every benchmark request, then fifty packages picked at random with
    /// a fixed seed, removals that go and that the system refuses, a
    /// downgrade and a queue of several.
    static func goldenRequests(_ snapshot: ResolutionSnapshot) -> [Scenario] {
        var result = scenarios(snapshot).map { Scenario(name: $0.name, request: $0.request) }
        let installed = Set(snapshot.installed.map(\.identity))
        let identities = Set(snapshot.packages.filter { $0.versions(supportingAnyOf: installable) != nil }.map(\.identity))
            .subtracting(installed).sorted()
        var state: UInt64 = 20_260_924
        var picked: [String] = []
        while picked.count < 50, picked.count < identities.count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let identity = identities[Int((state >> 33) % UInt64(identities.count))]
            if !picked.contains(identity) {
                picked.append(identity)
            }
        }
        for identity in picked {
            if let package = candidate(identity, in: snapshot) {
                result.append(Scenario(name: "install \(identity)", request: .init(actions: [.install(package)])))
            }
        }
        for name in ["zsh", "bash", "coreutils", "vim", "curl"] + snapshot.installed.map(\.identity).sorted().suffix(3) {
            result.append(Scenario(name: "remove \(name)", request: .init(actions: [.remove(name)])))
        }
        result.append(Scenario(name: "remove bash, system removal allowed", request: .init(actions: [.remove("bash")], allowSystemRemoval: true)))
        // a downgrade of an installed tweak, asked for by name
        for package in snapshot.installed.sorted(by: { $0.identity < $1.identity }) {
            guard let current = package.latestVersion,
                  let older = snapshot.packages.first(where: { offered in
                      offered.identity == package.identity && offered.payload.keys.contains { DebianVersion.compare($0, current) < 0 }
                  })
            else { continue }
            let version = older.payload.keys.filter { DebianVersion.compare($0, current) < 0 }
                .max { DebianVersion.compare($0, $1) < 0 }!
            let single = Package(identity: package.identity, payload: [version: older.payload[version]!], repoRef: older.repoRef)
            result.append(Scenario(name: "downgrade \(package.identity) to \(version)", request: .init(actions: [.install(single)])))
            break
        }
        let queue = picked.prefix(6).compactMap { candidate($0, in: snapshot) }
        result.append(Scenario(name: "queue of six", request: .init(actions: queue.map { .install($0) })))
        result += unusualRequests(snapshot)
        return result
    }

    /// Requests that reach the resolver's corners: an entry whose relations
    /// do not parse, asked for and depended on; another repository's copy
    /// of an installed package; a `.deb` no repository offers.
    static func unusualRequests(_ snapshot: ResolutionSnapshot) -> [Scenario] {
        var result: [Scenario] = []
        let kinds = ["depends", "pre-depends", "conflicts", "breaks", "provides"]
        var unreadable: [Package] = []
        for package in snapshot.packages.sorted(by: { ($0.identity, $0.repoRef?.absoluteString ?? "") < ($1.identity, $1.repoRef?.absoluteString ?? "") }) {
            for version in package.payload.keys.sorted() {
                let metadata = package.payload[version]!
                guard Package.architectures(in: metadata).contains(where: { $0 == "all" || installable.contains($0) }) else { continue }
                let broken = kinds.contains { kind in
                    guard let value = metadata[kind], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                    return PackageRequirementGroup(value: value, type: .init(rawValue: kind)!) == nil
                }
                if broken, unreadable.count < 3 {
                    unreadable.append(Package(identity: package.identity, payload: [version: metadata], repoRef: package.repoRef))
                }
            }
        }
        for package in unreadable {
            result.append(Scenario(name: "install unreadable \(package.identity)", request: .init(actions: [.install(package)])))
            // whatever depends on it
            if let user = snapshot.packages.sorted(by: { $0.identity < $1.identity }).first(where: { offered in
                offered.identity != package.identity
                    && (offered.latestMetadata?["depends"] ?? "").contains(package.identity)
                    && offered.supports(anyOf: installable)
            }), let chosen = candidate(user.identity, in: snapshot) {
                result.append(Scenario(name: "install \(user.identity), which depends on an unreadable entry", request: .init(actions: [.install(chosen)])))
            }
        }
        // another repository's copy of an installed tweak: not a candidate
        // until asked for by name
        for (identity, origin) in snapshot.origins.sorted(by: { $0.key < $1.key }) {
            guard let other = snapshot.packages.first(where: {
                $0.identity == identity && $0.repoRef != origin && $0.supports(anyOf: installable)
            }), let version = other.latestVersion else { continue }
            let single = Package(identity: identity, payload: [version: other.payload[version]!], repoRef: other.repoRef)
            result.append(Scenario(name: "install \(identity) from another repository", request: .init(actions: [.install(single)])))
            break
        }
        // a .deb on disk: the catalogue's own control paragraph, no repository
        if let offered = candidate("com.netskao.noappthinning", in: snapshot), var metadata = offered.latestMetadata {
            metadata["filename"] = "file:///var/mobile/Downloads/noappthinning.deb"
            let local = Package(identity: offered.identity, payload: [offered.latestVersion!: metadata], repoRef: nil)
            result.append(Scenario(name: "install a local .deb", request: .init(actions: [.install(local)])))
        }
        return result
    }

    // MARK: - Bench

    static func bench(iterations: Int) async throws {
        let index = PackageCenter.default.index
        let first = try index.resolutionSnapshot()
        print("catalogue: \(first.packages.count) rows, \(first.installed.count) installed, \(first.origins.count) origins")
        print("memory, one snapshot: \(memory())")
        // what the queue's preflight does after the packages move: a fresh
        // snapshot and its pool
        var preflight: [String: [Double]] = [:]
        var pool: ResolutionPool?
        for _ in 0 ..< iterations {
            var timer = Timer()
            let snapshot = try timer.measure("snapshot") { try index.resolutionSnapshot() }
            pool = nil
            pool = try timer.measure("pool") { try ResolutionPool(snapshot: snapshot) }
            timer.finish()
            for (phase, seconds) in timer.phases {
                preflight[phase, default: []].append(seconds)
            }
        }
        print("\npreflight (snapshot and pool, off the main actor, once per change):")
        report(preflight)
        // what the queue keeps: one catalogue, and the pool read from it
        pool = nil
        pool = try ResolutionPool(snapshot: first)
        print("memory, the snapshot and its pool: \(memory())")
        for scenario in scenarios(first) {
            for warm in [false, true] {
                var samples: [String: [Double]] = [:]
                var outcome = ""
                for _ in 0 ..< iterations {
                    var timer = Timer()
                    outcome = try solve(scenario, index: index, pool: warm ? pool : nil, timer: &timer)
                    for (phase, seconds) in timer.phases {
                        samples[phase, default: []].append(seconds)
                    }
                }
                print("\n\(scenario.name), \(warm ? "warm" : "cold"): \(outcome)")
                report(samples)
            }
        }
        print("\nmemory: \(memory())")
    }

    static func report(_ samples: [String: [Double]]) {
        for phase in Timer.order where samples[phase] != nil {
            let values = samples[phase]!.sorted()
            print(String(
                format: "  %-10@ median %8.1f ms   p90 %8.1f ms",
                phase as NSString,
                median(values) * 1000,
                percentile(values, 0.9) * 1000
            ))
        }
    }

    /// What malloc holds live, and the physical footprint jetsam counts
    /// (which keeps pages malloc has freed and not yet returned).
    static func memory() -> String {
        String(format: "%.1f MB live in malloc, footprint %.1f MB", Double(mstats().bytes_used) / 1_048_576, footprint())
    }

    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// One tap, as the queue sheet solves it: a snapshot, the plan, then
    /// the check that nothing moved while it was solved. With a `pool` the
    /// snapshot takes its catalogue and the resolver its records.
    static func solve(_ scenario: Scenario, index: PackageIndex, pool: ResolutionPool?, timer: inout Timer) throws -> String {
        var request = scenario.request
        var plan: ResolutionPlan
        do {
            var snapshot = try timer.measure("snapshot") { try index.resolutionSnapshot(reusingCatalogueOf: pool?.snapshot) }
            if let pool, !pool.serves(snapshot) {
                throw ResolutionFailure(message: "the pool does not serve its own inputs")
            }
            plan = try timer.measure("resolve") { try PackageResolver.resolve(request: request, snapshot: snapshot, pool: pool) }
            _ = try timer.measure("isCurrent") { try index.isCurrent(plan.snapshot) }
            if scenario.twoStep {
                let installed = Set(plan.snapshot.installed.map(\.identity))
                request = .init(actions: plan.install.filter { installed.contains($0.identity) }.map { .install($0) })
                snapshot = try timer.measure("snapshot") { try index.resolutionSnapshot(reusingCatalogueOf: pool?.snapshot) }
                plan = try timer.measure("resolve") { try PackageResolver.resolve(request: request, snapshot: snapshot, pool: pool) }
                _ = try timer.measure("isCurrent") { try index.isCurrent(plan.snapshot) }
            }
        } catch let failure as ResolutionFailure {
            timer.finish()
            return "fails: \(failure.reason)"
        }
        timer.finish()
        return "installs \(plan.install.count), removes \(plan.remove.count), held back \(plan.heldBack.count)"
    }

    struct Timer {
        static let order = ["snapshot", "pool", "resolve", "isCurrent", "total"]
        private(set) var phases: [String: Double] = [:]
        private let start = ContinuousClock.now

        mutating func measure<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
            let begin = ContinuousClock.now
            defer { phases[phase, default: 0] += (ContinuousClock.now - begin).seconds }
            return try body()
        }

        mutating func finish() {
            phases["total"] = (ContinuousClock.now - start).seconds
        }
    }

    static func median(_ sorted: [Double]) -> Double {
        sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// Nearest rank.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
    }

    // MARK: - Golden

    struct GoldenEntry: Encodable {
        let name: String
        let request: [String]
        let plan: GoldenPlan?
        let failure: GoldenFailure?
    }

    struct GoldenPlan: Encodable {
        let install: [String]
        let remove: [String]
        let finalPackages: [String]
        let stages: [InstallerStage]
        let heldBack: [String]
        let diagnostics: [String]
        let requiredBy: [String: [String]]
        let autoInstalled: [String]
        let unneeded: [String: [String]]
    }

    struct GoldenFailure: Encodable {
        let reason: String
        let checks: [String]
    }

    static func describe(_ package: Package) -> String {
        "\(package.identity)=\(package.latestVersion ?? "?")@\(package.repoRef?.absoluteString ?? "installed")"
    }

    static func golden(to output: URL, pooled: Bool) async throws {
        let index = PackageCenter.default.index
        let snapshot = try index.resolutionSnapshot()
        // as the queue keeps it: read once, then each request's snapshot
        // takes its catalogue and the resolver its records
        var pool = pooled ? try ResolutionPool(snapshot: snapshot) : nil
        var entries: [GoldenEntry] = []
        for scenario in goldenRequests(snapshot) {
            let request = scenario.request.actions.map { action in
                switch action {
                case let .install(package): "install \(describe(package))"
                case let .remove(identity): "remove \(identity)"
                }
            } + (scenario.request.updateAll ? ["update all"] : [])
                + (scenario.request.allowSystemRemoval ? ["allow system removal"] : [])
            do {
                let plan = if pooled {
                    try PackageResolver.resolve(
                        request: scenario.request,
                        snapshot: index.resolutionSnapshot(reusingCatalogueOf: pool?.snapshot),
                        keeping: &pool
                    )
                } else {
                    try PackageResolver.resolve(request: scenario.request, snapshot: snapshot)
                }
                entries.append(GoldenEntry(name: scenario.name, request: request, plan: GoldenPlan(
                    install: plan.install.map(describe),
                    remove: plan.remove.map(describe),
                    finalPackages: plan.finalPackages.map(describe),
                    stages: plan.stages,
                    heldBack: plan.heldBack,
                    diagnostics: plan.diagnostics.map { String(describing: $0) },
                    requiredBy: plan.requiredBy,
                    autoInstalled: plan.autoInstalled,
                    unneeded: plan.unneeded
                ), failure: nil))
            } catch let failure as ResolutionFailure {
                entries.append(GoldenEntry(name: scenario.name, request: request, plan: nil, failure: GoldenFailure(
                    reason: String(describing: failure.reason),
                    checks: failure.checks.map { "\($0.package) | \($0.requirement) | \($0.outcome) | \($0.candidates.joined(separator: ", "))" }
                )))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(entries).write(to: output)
        let failed = entries.filter { $0.failure != nil }.count
        print("golden: \(entries.count) requests, \(entries.count - failed) plans, \(failed) failures -> \(output.path)")
    }
}

extension Duration {
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// Settings live for the process: nothing the tool does is kept.
final class MemoryStorage: AptStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(key: String) -> Data? {
        lock.withLock { values[key] }
    }

    func write(key: String, value: Data?) {
        lock.withLock { values[key] = value }
    }
}

struct QuietLogger: AptLogger {
    func log(_ kind: String, _ message: String, level: AptLogLevel) {
        if level == .critical {
            FileHandle.standardError.write(Data("[\(level.rawValue)] \(kind): \(message)\n".utf8))
        }
    }
}
