import ArgumentParser
import AptRepository
import AptResolver
import Foundation
import IrisinProtocol

/// The flags every command that changes something takes.
struct ChangeOptions: ParsableArguments {
    @Flag(name: [.customShort("y"), .long], help: "Go ahead without asking.")
    var yes = false

    @Flag(name: .long, help: "Run the transaction as a dry run: check everything, change nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Allow removing a package the system requires (Irisin's Power Operations).")
    var allowSystemRemoval = false

    var pipeline: Pipeline.Options {
        .init(assumeYes: yes, dryRun: dryRun, allowSystemRemoval: allowSystemRemoval)
    }
}

extension ParsableCommand {
    /// Solve, show, ask, run: what install, remove and upgrade share.
    /// `revise` may ask for another request once the first is solved: the
    /// plan of that one is the one shown and run.
    func change(
        _ options: GlobalOptions,
        _ change: ChangeOptions,
        request: @escaping (Context, PackageIndex) throws -> ResolutionRequest,
        revise: @escaping (ResolutionPlan) -> ResolutionRequest? = { _ in nil }
    ) throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (context, index) = try Session.open(options)
            let pipeline = Pipeline(context: context, index: index, output: output)
            var resolution = try request(context, index)
            resolution.allowSystemRemoval = change.allowSystemRemoval
            var plan = try pipeline.plan(resolution)
            if var revised = revise(plan) {
                revised.allowSystemRemoval = change.allowSystemRemoval
                plan = try pipeline.plan(revised)
            }
            guard pipeline.show(plan) else { return }
            try pipeline.confirm(change.pipeline)
            try await pipeline.run(plan, options: change.pipeline)
        }
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install packages by name, name=version, or a .deb file's path, with what they need."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var changeOptions: ChangeOptions

    @Argument(help: "Package identifiers, identifier=version, or paths to .deb files.")
    var packages: [String]

    func run() throws {
        try change(options, changeOptions) { context, index in
            let actions = try packages.map { name -> ResolutionAction in
                if name.hasSuffix(".deb") || name.contains("/") {
                    let url = context.userPath(name)
                    guard FileManager.default.isReadableFile(atPath: url.path) else {
                        throw CommandFailure.refused("\(name) is not a readable file.")
                    }
                    do {
                        return .install(try Package(debianPackageAt: url))
                    } catch {
                        throw CommandFailure.refused("\(name) is not a package file irisin-cli can read: \(error)")
                    }
                }
                guard let package = Session.candidate(name, in: index) else {
                    throw CommandFailure.refused("No repository offers \(name) for this device. Search with irisin-cli search, or refresh repositories in Irisin.")
                }
                return .install(package)
            }
            return ResolutionRequest(actions: actions)
        }
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove installed packages, and what depends on them."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var changeOptions: ChangeOptions

    @Argument(help: "Package identifiers.")
    var packages: [String]

    func run() throws {
        try change(options, changeOptions) { _, _ in
            ResolutionRequest(actions: packages.map { .remove($0.lowercased()) })
        }
    }
}

struct Upgrade: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install every update the catalogue offers, as Irisin's Update All does."
    )

    @OptionGroup var options: GlobalOptions
    @OptionGroup var changeOptions: ChangeOptions

    @Flag(help: "Install the packages held-back updates need from the repository that offers them, as Irisin's Migrate and Update does.")
    var migrate = false

    func run() throws {
        try change(options, changeOptions) { _, index in
            Session.warnIfStale(index, Output(json: options.json))
            return ResolutionRequest(updateAll: true)
        } revise: { plan in
            // what the app's Migrate and Update asks the queue for: the
            // update of every installed package, the moves among them
            guard migrate, let migration = plan.migration else { return nil }
            let installed = Set(plan.snapshot.installed.map(\.identity))
            return ResolutionRequest(actions: migration.install.filter { installed.contains($0.identity) }.map { .install($0) })
        }
    }
}

struct Respring: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restart the home screen.")

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let context = try Context.load()
            try await Runner(context: context, output: output).run(.respring)
        }
    }
}
