import AptRepository
import AptResolver
import Darwin
import Foundation
import IrisinAdapter
import IrisinClient
import IrisinProtocol

/// The app's queue, cut down to one solve and one run
/// (Documentation/CommandLine.md, "The pipeline"): resolve, show, download,
/// prepare, run through irisind, tell the app.
struct Pipeline {
    let context: Context
    let index: PackageIndex
    let output: Output

    struct Options {
        var assumeYes = false
        var dryRun = false
        var allowSystemRemoval = false
    }

    // MARK: - Plan

    func plan(_ request: ResolutionRequest) throws -> ResolutionPlan {
        do {
            let snapshot = try index.resolutionSnapshot()
            return try PackageResolver.resolve(request: request, snapshot: snapshot)
        } catch let failure as ResolutionFailure {
            throw CommandFailure.refused(failure.text)
        }
    }

    /// The plan, as apt lists one; false when there is nothing to do.
    func show(_ plan: ResolutionPlan) -> Bool {
        let installing = plan.install.sorted { $0.identity < $1.identity }
        let removing = plan.remove.sorted { $0.identity < $1.identity }
        let before = (try? Session.installed(context)) ?? [:]
        if !installing.isEmpty {
            output.line("Install:")
            for package in installing {
                let from = before[package.identity]?.latestVersion
                output.line("  \(package.identity) \(from.map { "\($0) -> " } ?? "")\(package.latestVersion ?? "?")")
            }
        }
        if !removing.isEmpty {
            output.line("Remove:")
            for package in removing {
                output.line("  \(package.identity) \(package.latestVersion ?? "")")
            }
        }
        if !plan.heldBack.isEmpty {
            output.line("Held back: \(plan.heldBack.sorted().joined(separator: ", "))")
        }
        output.object([
            "plan": [
                "install": installing.map { package -> [String: Any] in
                    ["package": package.identity, "version": package.latestVersion ?? "",
                     "from": before[package.identity]?.latestVersion ?? NSNull()]
                },
                "remove": removing.map { ["package": $0.identity, "version": $0.latestVersion ?? ""] },
                "heldBack": plan.heldBack.sorted(),
            ] as [String: Any],
        ])
        if installing.isEmpty, removing.isEmpty {
            output.line("Nothing to do.")
            return false
        }
        if (installing + removing).contains(where: { $0.identity.hasPrefix(InstallerJob.selfIdentityPrefix) }) {
            output.note("note: this changes Irisin itself; the helper finishes it even if irisin-cli or the app stops.")
        }
        return true
    }

    /// Asked on the terminal unless `-y`; a script without a terminal must say `-y`.
    func confirm(_ options: Options) throws {
        guard !options.assumeYes else { return }
        guard isatty(STDIN_FILENO) == 1 else {
            throw CommandFailure.refused("Pass -y to go ahead without a terminal.")
        }
        FileHandle.standardError.write(Data("Continue? [y/N] ".utf8))
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), ["y", "yes"].contains(answer) else {
            throw CommandFailure.refused("Nothing was changed.")
        }
    }

    // MARK: - Run

    /// Downloads and prepares what the plan installs, sends the transaction
    /// and prints its transcript; the helper's exit status, thrown when not 0.
    func run(_ plan: ResolutionPlan, options: Options) async throws {
        if let adapted = plan.install.first(where: { plan.snapshot.adapts($0) }) {
            throw CommandFailure.refused(
                "\(adapted.identity) is built for another bootstrap and installs only in Compatibility Mode. Install it from Irisin."
            )
        }
        let workspace = try Workspace.make()
        defer { workspace.remove() }

        var items: [InstallerJob.Transaction.Item] = []
        for package in plan.install {
            let file = try await Fetch.file(for: package, into: workspace.directory, context: context, index: index, output: output)
            items.append(try Stage.item(for: package, file: file, in: workspace.directory))
        }

        // read again: the app may have installed something while this one downloaded
        if try index.changes(since: plan.snapshot).contains(.installed) {
            throw CommandFailure.refused("The installed packages changed while preparing. Run the command again.")
        }
        let installing = Set(items.map(\.identity))
        let configuring = Set(plan.stages.flatMap { stage -> [String] in
            if case let .configure(names) = stage { return names }
            return []
        })
        let transaction = InstallerJob.Transaction(
            install: items,
            remove: plan.remove.map(\.identity),
            dryRun: options.dryRun,
            stages: plan.stages,
            configureExisting: configuring.subtracting(installing).sorted(),
            autoInstalled: plan.autoInstalled,
            statusDigest: plan.snapshot.statusDigest,
            allowSystemRemoval: options.allowSystemRemoval,
            recoveryMode: plan.recoveryMode
        )
        try InstallerJob.transaction(transaction).validate()
        try await Runner(context: context, output: output).run(.transaction(transaction))
    }
}

/// Where one run keeps its downloads and prepared trees: root's, 0700,
/// removed when the run ends, and by the next run when this one died.
struct Workspace {
    let directory: URL

    private static let prefix = "irisin-cli."

    static func make() throws -> Workspace {
        let base = FileManager.default.temporaryDirectory
        removeAbandoned(in: base)
        let directory = base.appendingPathComponent("\(prefix)\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return Workspace(directory: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A directory whose run has no process any more.
    private static func removeAbandoned(in base: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            guard let pid = Int32(name.dropFirst(prefix.count)), pid != getpid() else { continue }
            if kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
            }
        }
    }
}

/// A `.deb` into what the job names: the archive, its digest and the tree
/// the helper captures and installs from, as `Installer.stage` makes them.
enum Stage {
    static func item(for package: Package, file: URL, in directory: URL) throws -> InstallerJob.Transaction.Item {
        let destination = directory.appendingPathComponent(package.identity + ".deb")
        if file != destination {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file, to: destination)
        }
        let digest: String
        do {
            digest = try package.validateArchive(at: destination)
        } catch {
            throw CommandFailure.refused("\(package.identity)'s file does not match its repository's listing: \(error)")
        }
        let prepared = directory.appendingPathComponent(package.identity + ".contents")
        try? FileManager.default.removeItem(at: prepared)
        let manifestDigest = try ArchiveStream.prepareDebianPackage(at: destination, in: prepared)
        return .init(
            identity: package.identity,
            path: destination.path,
            sha256: digest,
            preparedPath: prepared.path,
            preparedSHA256: manifestDigest
        )
    }
}
