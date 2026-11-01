import ArgumentParser
import AptRepository
import Foundation
import IrisinProtocol

/// `<root>/usr/bin/irisin-cli`: Irisin's packages from a shell, as root.
/// Documentation/CommandLine.md is the design; English only, as apt is.
@main
struct IrisinCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "irisin-cli",
        abstract: "Install, remove and look up packages through Irisin.",
        discussion: """
        Run as root (sudo irisin-cli ...). The catalogue is the one Irisin keeps: \
        refresh repositories in Irisin. Transactions run in Irisin's helper and \
        finish even if irisin-cli is stopped.
        """,
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        subcommands: [
            Search.self,
            Show.self,
            List.self,
            Install.self,
            Remove.self,
            Upgrade.self,
            Repo.self,
            Vendor.self,
            Udid.self,
            Respring.self,
            DpkgQuery.self,
            Dpkg.self,
        ]
    )
}

/// What every catalogue command opens first.
enum Session {
    static func open(_ options: GlobalOptions) throws -> (Context, PackageIndex) {
        let context = try Context.load()
        context.bootstrapEnvironment(verbose: options.verbose)
        return (context, try context.openCatalogue())
    }

    /// `--repository`: a catalogue of these sources alone, refreshed now
    /// into `workspace`, root's own. The app's catalogue is neither read nor
    /// written, so this works before Irisin has ever been opened.
    static func open(
        _ options: GlobalOptions,
        repositories lines: [String],
        in workspace: Workspace,
        output: Output
    ) async throws -> (Context, PackageIndex) {
        let sources = try lines.map { line in
            guard let source = RepositorySource(line: line), source.isValid else {
                throw CommandFailure.refused("\(line) is not a repository: give its address, or `deb <url> <suite> <components>`.")
            }
            return source
        }
        let context = try Context.load()
        context.bootstrapEnvironment(verbose: options.verbose, workingLocation: workspace.directory)
        return (context, try await refresh(sources, output: output))
    }

    /// The app's own refresh, through the same center, waited for here.
    @MainActor
    private static func refresh(_ sources: [RepositorySource], output: Output) async throws -> PackageIndex {
        let center = RepositoryCenter.default
        await center.load()
        for source in sources {
            center.registerRepository(source)
        }
        let deadline = Date().addingTimeInterval(300)
        while center.obtainUpdateRemain() > 0 {
            guard Date() < deadline else {
                throw CommandFailure.unavailable("The repositories did not finish refreshing within five minutes.")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        for source in sources {
            guard let repository = center.obtainImmutableRepository(withUrl: source.url), repository.packageCount > 0 else {
                throw CommandFailure.unavailable("\(source.line) offers no packages for this device, or could not be refreshed. Run again with --verbose to see why.")
            }
            output.note("Refreshed \(source.url.absoluteString): \(repository.packageCount) packages.")
        }
        return PackageCenter.default.index
    }

    /// dpkg's own record of what is installed, read directly: the
    /// catalogue's copy is the app's and may be behind.
    static func installed(_ context: Context) throws -> [String: Package] {
        guard FileManager.default.fileExists(atPath: context.statusFile) else { return [:] }
        return try DpkgStatus.packages(in: Data(contentsOf: URL(fileURLWithPath: context.statusFile)))
    }

    /// The newest record of `name` this device installs, or of `name=version`
    /// that version; nil when no repository offers it.
    static func candidate(_ name: String, in index: PackageIndex) -> Package? {
        let parts = name.split(separator: "=", maxSplits: 1).map(String.init)
        let identity = parts[0].lowercased()
        let device = AptEnvironment.current.deviceArchitecture
        let records = index.obtainPackageSummary(with: identity).values.compactMap { $0.versions(builtFor: device) }
        if parts.count == 2 {
            return records.lazy.compactMap { record in
                record.payload[parts[1]].map { Package(identity: identity, payload: [parts[1]: $0], repoRef: record.repoRef) }
            }.first
        }
        return records.max { a, b in
            let order = DebianVersion.compareStrings(a.latestVersion, b.latestVersion)
            // a tie goes to the build for this bootstrap over an `all` one
            return order != 0 ? order < 0 : !a.architectures.contains(device) && b.architectures.contains(device)
        }
    }

    static func describeAge(_ date: Date) -> String {
        let hours = Int(Date().timeIntervalSince(date) / 3600)
        if date.timeIntervalSince1970 <= 0 { return "never" }
        if hours < 1 { return "less than an hour ago" }
        if hours < 48 { return "\(hours) hours ago" }
        return "\(hours / 24) days ago"
    }

    /// A warning, once, when the catalogue is more than a day old: irisin-cli
    /// reads what Irisin last refreshed and never refreshes it itself.
    static func warnIfStale(_ index: PackageIndex, _ output: Output) {
        guard let newest = index.obtainRepositories().map(\.lastUpdatePackage).max() else { return }
        if Date().timeIntervalSince(newest) > 24 * 3600 {
            output.note("note: repositories were last refreshed \(describeAge(newest)); refresh them in Irisin for newer packages.")
        }
    }
}

extension DebianVersion {
    /// -1, 0 or 1; an unreadable or missing version sorts first.
    static func compareStrings(_ a: String?, _ b: String?) -> Int {
        guard let a = a.flatMap(DebianVersion.parse) else { return b.flatMap(DebianVersion.parse) == nil ? 0 : -1 }
        guard let b = b.flatMap(DebianVersion.parse) else { return 1 }
        return DebianVersion.compare(a, b)
    }
}
