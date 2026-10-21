import ArgumentParser
import AptRepository
import Foundation

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search the catalogue by name, identifier, author or description."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "What to search for.")
    var words: [String]

    @Option(help: "Show at most this many results.")
    var limit = 50

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (context, index) = try Session.open(options)
            let installed = try Session.installed(context)
            let hits = index.search(words.joined(separator: " "), limit: limit)
            for hit in hits {
                let version = installed[hit.identity]?.latestVersion
                let name = hit.name.isEmpty || hit.name == hit.identity ? "" : "  \(hit.name)"
                output.line("\(hit.identity)\(version.map { " [installed \($0)]" } ?? "")\(name)")
                output.line("    \(Self.summary(hit.description))")
                output.object([
                    "package": hit.identity, "name": hit.name, "author": hit.author, "section": hit.section,
                    "description": hit.description, "repository": hit.repository.absoluteString,
                    "installed": version ?? NSNull(),
                ])
            }
            if hits.isEmpty {
                output.line("No packages found.")
            }
            Session.warnIfStale(index, output)
        }
    }
}

extension Search {
    /// The description's first line, cut to fit a terminal row.
    static func summary(_ description: String) -> String {
        let line = description.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 100 ? String(line.prefix(99)) + "…" : line
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show every repository's record of a package, and the installed one."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The package identifier.")
    var package: String

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (context, index) = try Session.open(options)
            let identity = package.lowercased()
            let installed = try Session.installed(context)[identity]
            let records = index.obtainPackageSummary(with: identity).sorted { $0.key.absoluteString < $1.key.absoluteString }
            guard installed != nil || !records.isEmpty else {
                throw CommandFailure.refused("No repository offers \(identity), and it is not installed.")
            }
            if let installed, let metadata = installed.latestMetadata {
                print(record: metadata, source: "installed", output: output)
            }
            for (repository, record) in records {
                guard let metadata = record.latestMetadata else { continue }
                print(record: metadata, source: repository.absoluteString, output: output)
            }
        }
    }

    private func print(record metadata: [String: String], source: String, output: Output) {
        let order = ["package", "name", "version", "architecture", "section", "author", "maintainer",
                     "depends", "pre-depends", "conflicts", "provides", "installed-size", "size", "tag", "description"]
        output.line("From: \(source)")
        for key in order {
            guard let value = metadata[key] else { continue }
            output.line("\(key.capitalized): \(value.replacingOccurrences(of: "\n", with: "\n  "))")
        }
        output.line("")
        var object: [String: Any] = metadata
        object["source"] = source
        output.object(object)
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List installed packages, or the updates the catalogue offers."
    )

    @OptionGroup var options: GlobalOptions

    @Flag(help: "List the installed packages that have an update.")
    var upgradable = false

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (context, index) = try Session.open(options)
            let installed = try Session.installed(context).values.sorted { $0.identity < $1.identity }
            for package in installed {
                guard let version = package.latestVersion else { continue }
                if upgradable {
                    let offers = index.obtainUpdateForPackage(with: package.identity, version: version)
                    guard let offer = offers.max(by: { DebianVersion.compareStrings($0.latestVersion, $1.latestVersion) < 0 }),
                          let newer = offer.latestVersion
                    else { continue }
                    output.line("\(package.identity)  \(version) -> \(newer)")
                    output.object([
                        "package": package.identity, "installed": version, "candidate": newer,
                        "repository": offer.repoRef?.absoluteString ?? NSNull(),
                    ])
                } else {
                    output.line("\(package.identity)  \(version)")
                    output.object(["package": package.identity, "installed": version])
                }
            }
            if upgradable {
                Session.warnIfStale(index, output)
            }
        }
    }
}

struct Repo: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List repositories, or add one through Irisin.",
        subcommands: [RepoList.self, RepoAdd.self],
        defaultSubcommand: RepoList.self
    )
}

struct RepoList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the repositories Irisin has.")

    @OptionGroup var options: GlobalOptions

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            let (_, index) = try Session.open(options)
            for repository in index.obtainRepositories().sorted(by: { $0.url.absoluteString < $1.url.absoluteString }) {
                output.line("\(repository.url.absoluteString)  \(repository.nickName)  \(repository.packageCount) packages, refreshed \(Session.describeAge(repository.lastUpdatePackage))")
                output.object([
                    "url": repository.url.absoluteString, "name": repository.nickName,
                    "source": repository.source.line, "packages": repository.packageCount,
                    "refreshed": ISO8601DateFormatter().string(from: repository.lastUpdatePackage),
                    "paid": repository.endpoint != nil,
                ])
            }
        }
    }
}

struct RepoAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Print the link that adds a repository in Irisin.",
        discussion: "irisin-cli never writes the catalogue: Irisin adds the repository and refreshes it."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "The repository's address.")
    var url: String

    @Option(help: "The suite of a repository that names one.")
    var suite: String?

    @Option(help: "The component of a repository that names a suite.")
    var component: String?

    func run() throws {
        let output = Output(json: options.json)
        try guarded(output) {
            _ = try Context.load()
            guard let address = RepositorySource.url(from: url) else {
                throw CommandFailure.refused("\(url) is not a repository address.")
            }
            var link = URLComponents()
            link.scheme = "irisin"
            link.host = "repository"
            link.path = "/add"
            link.queryItems = [URLQueryItem(name: "url", value: address.absoluteString)]
                + (suite.map { [URLQueryItem(name: "suite", value: $0)] } ?? [])
                + (component.map { [URLQueryItem(name: "component", value: $0)] } ?? [])
            let text = link.url?.absoluteString ?? ""
            output.line("Open this link on the device to add the repository in Irisin:")
            output.line(text)
            output.object(["link": text])
        }
    }
}
