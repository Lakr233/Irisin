//
//  AptDatabase.swift
//  AptRepository
//
//  The catalogue on disk: every repository, every package every repository
//  offers, what dpkg reports installed, and when each of those changed.
//

import Foundation
import WCDBSwift

/// One WCDB database under the working location. `Database` keeps a handle
/// per thread and is documented thread-safe, but is not `Sendable` in
/// 2.1.16; this wrapper is the deliberate annotation. No actor around it:
/// that would serialise away the concurrency WCDB exists to provide.
final class AptDatabase: @unchecked Sendable {
    nonisolated static let shared = AptDatabase(
        at: AptEnvironment.current.workingLocation.appendingPathComponent("apt.db")
    )

    enum Table {
        static let repository = "repository"
        static let package = "package"
        static let installed = "installed"
        static let installOrigin = "installOrigin"
        static let virtual = "virtual"
        static let installTrace = "installTrace"
        static let repoTrace = "repoTrace"
        static let search = "packageSearch"
        static let resolutionRevision = "resolutionRevision"
    }

    private let database: Database

    init(at url: URL) {
        database = Database(at: url)
        database.add(tokenizer: BuiltinTokenizer.Verbatim)
        database.setAutoMergeFTS5Index(enable: true)
        // The source list and where each package was installed from are
        // the two things here no refresh can rebuild.
        database.setAutoBackup(enable: true)
        database.filterBackup { $0 == Table.repository || $0 == Table.installOrigin }
        do {
            try database.create(table: Table.resolutionRevision, of: ResolutionRevisionRow.self)
            try database.create(table: Table.repository, of: Repository.self)
            try database.create(table: Table.package, of: PackageRow.self)
            try database.create(table: Table.installed, of: PackageRow.self)
            try database.create(table: Table.installOrigin, of: OriginRow.self)
            try database.create(table: Table.virtual, of: VirtualRow.self)
            try database.create(table: Table.installTrace, of: TraceRow.self)
            try database.create(table: Table.repoTrace, of: TraceRow.self)
            try database.create(virtualTable: Table.search, of: SearchRow.self)
        } catch {
            aptLog(Self.self, "database at \(url.path) failed to open: \(error)", level: .critical)
        }
    }

    func resolutionCatalogue() throws -> (packages: [Package], revision: Int64) {
        var packages: [Package] = []
        var revision: Int64 = 0
        try database.run(transaction: { handle in
            let rows: [PackageRow] = try handle.getObjects(fromTable: Table.package)
            let row: ResolutionRevisionRow? = try handle.getObject(fromTable: Table.resolutionRevision)
            packages = rows.map(\.package)
            revision = row?.revision ?? 0
        })
        return (packages, revision)
    }

    func resolutionRevision() throws -> Int64 {
        let row: ResolutionRevisionRow? = try database.getObject(fromTable: Table.resolutionRevision)
        return row?.revision ?? 0
    }

    // MARK: - Helpers

    private func read<T>(_ fallback: T, _ body: () throws -> T) -> T {
        do {
            return try body()
        } catch {
            aptLog(Self.self, "query failed: \(error)", level: .error)
            return fallback
        }
    }

    private func write(resolutionChanged: Bool = false, _ body: @escaping (Handle) throws -> Void) {
        do {
            try database.run(transaction: { handle in
                try body(handle)
                if resolutionChanged {
                    let row: ResolutionRevisionRow? = try handle.getObject(fromTable: Table.resolutionRevision)
                    try handle.insertOrReplace(
                        ResolutionRevisionRow(revision: (row?.revision ?? 0) + 1),
                        intoTable: Table.resolutionRevision
                    )
                }
            })
        } catch {
            aptLog(Self.self, "write failed: \(error)", level: .error)
        }
    }

    // MARK: - Repositories

    func repositories() -> [Repository] {
        read([]) { try database.getObjects(on: Repository.Properties.all, fromTable: Table.repository) }
    }

    func save(_ repository: Repository) {
        write { try $0.insertOrReplace(repository, intoTable: Table.repository) }
    }

    func delete(repository url: URL) {
        write { try $0.delete(fromTable: Table.repository, where: Repository.Properties.url == url.absoluteString) }
    }

    // MARK: - Packages

    /// One transaction: the repository's old rows go, the new ones come.
    func replacePackages(of url: URL, with packages: [String: Package]) {
        let repo = url.absoluteString
        var rows = [PackageRow]()
        var virtuals = [VirtualRow]()
        var searches = [SearchRow]()
        rows.reserveCapacity(packages.count)
        searches.reserveCapacity(packages.count)
        for package in packages.values {
            rows.append(PackageRow(package, repo: repo))
            searches.append(SearchRow(package, repo: repo))
            for element in package.provides {
                virtuals.append(VirtualRow(name: element.representPackage, identity: package.identity, repo: repo))
            }
        }
        write(resolutionChanged: true) { handle in
            try Self.deletePackages(of: repo, on: handle)
            try handle.insert(rows, intoTable: Table.package)
            try handle.insert(virtuals, intoTable: Table.virtual)
            try handle.insert(searches, intoTable: Table.search)
        }
    }

    func deletePackages(of url: URL) {
        let repo = url.absoluteString
        write(resolutionChanged: true) { try Self.deletePackages(of: repo, on: $0) }
    }

    private static func deletePackages(of repo: String, on handle: Handle) throws {
        try handle.delete(fromTable: Table.package, where: PackageRow.Properties.repo == repo)
        try handle.delete(fromTable: Table.virtual, where: VirtualRow.Properties.repo == repo)
        try handle.delete(fromTable: Table.search, where: SearchRow.Properties.repo == repo)
    }

    func packages(identity: String) -> [Package] {
        read([]) {
            let rows: [PackageRow] = try database.getObjects(
                on: PackageRow.Properties.all,
                fromTable: Table.package,
                where: PackageRow.Properties.identity == identity
            )
            return rows.map(\.package)
        }
    }

    func package(identity: String, repo: URL) -> Package? {
        read(nil) {
            let row: PackageRow? = try database.getObject(
                on: PackageRow.Properties.all,
                fromTable: Table.package,
                where: PackageRow.Properties.identity == identity && PackageRow.Properties.repo == repo.absoluteString
            )
            return row?.package
        }
    }

    func packages(in repo: URL, section: String?) -> [Package] {
        read([]) {
            var condition: WCDBSwift.Expression = PackageRow.Properties.repo == repo.absoluteString
            if let section {
                condition = condition && PackageRow.Properties.section == section
            }
            let rows: [PackageRow] = try database.getObjects(
                on: PackageRow.Properties.all,
                fromTable: Table.package,
                where: condition
            )
            return rows.map(\.package)
        }
    }

    func sectionCounts(in repo: URL) -> [String: Int] {
        read([:]) {
            let section = PackageRow.Properties.section
            let rows = try database
                .prepareRowSelect(on: section, section.count(), fromTable: Table.package)
                .where(PackageRow.Properties.repo == repo.absoluteString && section != "")
                .group(by: section)
                .allRows()
            return Dictionary(uniqueKeysWithValues: rows.map { ($0[0].stringValue, $0[1].intValue) })
        }
    }

    func identities() -> [String] {
        read([]) {
            try database.getDistinctColumn(on: PackageRow.Properties.identity, fromTable: Table.package)
                .map(\.stringValue)
        }
    }

    func authors() -> [String] {
        read([]) {
            try database.getDistinctColumn(
                on: PackageRow.Properties.author,
                fromTable: Table.package,
                where: PackageRow.Properties.author != ""
            ).map(\.stringValue)
        }
    }

    func packages(by author: String) -> [Package] {
        read([]) {
            let rows: [PackageRow] = try database.getObjects(
                on: PackageRow.Properties.all,
                fromTable: Table.package,
                where: PackageRow.Properties.author == author
            )
            return rows.map(\.package)
        }
    }

    func identities(by author: String) -> [String] {
        read([]) {
            try database.getDistinctColumn(
                on: PackageRow.Properties.identity,
                fromTable: Table.package,
                where: PackageRow.Properties.author == author
            ).map(\.stringValue)
        }
    }

    /// Every (identity, repository, newest version) without the payload:
    /// what tracing needs, three small columns per row.
    func newestVersions() -> [(identity: String, repo: String, version: String)] {
        read([]) {
            try database.getRows(
                on: [PackageRow.Properties.identity, PackageRow.Properties.repo, PackageRow.Properties.version],
                fromTable: Table.package
            ).map { ($0[0].stringValue, $0[1].stringValue, $0[2].stringValue) }
        }
    }

    func virtualProviders(of name: String) -> [String] {
        read([]) {
            try database.getDistinctColumn(
                on: VirtualRow.Properties.identity,
                fromTable: Table.virtual,
                where: VirtualRow.Properties.name == name
            ).map(\.stringValue)
        }
    }

    // MARK: - Installed

    /// dpkg's list replaces the installed table, and the origins follow it
    /// in the same transaction. `sources` are the packages a transaction
    /// just installed: each one from a repository that dpkg now reports at
    /// that version becomes the origin of its identity. A local `.deb` has
    /// no repository to come back to and clears any previous origin, even
    /// at the same version. An origin whose identity or version dpkg no
    /// longer reports is dropped: the origin
    /// table never knows more than dpkg does.
    func replaceInstalled(_ packages: [String: Package], installedFrom sources: [Package] = []) {
        let rows = packages.values.map { PackageRow($0, repo: "") }
        let origins = sources
            .filter { $0.repoRef != nil && packages[$0.identity]?.latestVersion == $0.latestVersion }
            .map(OriginRow.init)
        write { handle in
            try handle.delete(fromTable: Table.installed)
            try handle.insert(rows, intoTable: Table.installed)
            for source in sources where source.localFileURL != nil
                && packages[source.identity]?.latestVersion == source.latestVersion
            {
                try handle.delete(
                    fromTable: Table.installOrigin,
                    where: OriginRow.Properties.identity == source.identity
                )
            }
            try handle.insertOrReplace(origins, intoTable: Table.installOrigin)
            // two columns, not the payload: the decoder needs every column
            // of a row, and the row is the heavy part
            let kept = try handle.getRows(
                on: [OriginRow.Properties.identity, OriginRow.Properties.version],
                fromTable: Table.installOrigin
            ).map { (identity: $0[0].stringValue, version: $0[1].stringValue) }
            for stale in kept where packages[stale.identity]?.latestVersion != stale.version {
                try handle.delete(
                    fromTable: Table.installOrigin,
                    where: OriginRow.Properties.identity == stale.identity
                )
            }
        }
    }

    /// The repository of every origin, by identity: two columns, not the
    /// payload, for the resolver's snapshot.
    func installOrigins() -> [String: URL] {
        read([:]) {
            let rows = try database.getRows(
                on: [OriginRow.Properties.identity, OriginRow.Properties.repo],
                fromTable: Table.installOrigin
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                URL(string: row[1].stringValue).map { (row[0].stringValue, $0) }
            })
        }
    }

    /// Every origin whole, by identity.
    func installOriginPackages() -> [String: Package] {
        read([:]) {
            let rows: [OriginRow] = try database.getObjects(
                on: OriginRow.Properties.all,
                fromTable: Table.installOrigin
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.identity, $0.package) })
        }
    }

    /// The repository package an identity was installed from, or nil when
    /// this app did not install what dpkg reports.
    func installOrigin(identity: String) -> Package? {
        read(nil) {
            let row: OriginRow? = try database.getObject(
                on: OriginRow.Properties.all,
                fromTable: Table.installOrigin,
                where: OriginRow.Properties.identity == identity
            )
            return row?.package
        }
    }

    func installed() -> [Package] {
        read([]) {
            let rows: [PackageRow] = try database.getObjects(on: PackageRow.Properties.all, fromTable: Table.installed)
            return rows.map(\.package)
        }
    }

    func installed(identity: String) -> Package? {
        read(nil) {
            let row: PackageRow? = try database.getObject(
                on: PackageRow.Properties.all,
                fromTable: Table.installed,
                where: PackageRow.Properties.identity == identity
            )
            return row?.package
        }
    }

    // MARK: - Traces

    private static func table(for scope: TraceScope) -> String {
        switch scope {
        case .install: Table.installTrace
        case .repo: Table.repoTrace
        }
    }

    func trace(_ scope: TraceScope, identity: String) -> TraceRow? {
        read(nil) {
            try database.getObject(
                on: TraceRow.Properties.all,
                fromTable: Self.table(for: scope),
                where: TraceRow.Properties.identity == identity
            )
        }
    }

    func traces(_ scope: TraceScope) -> [TraceRow] {
        read([]) { try database.getObjects(on: TraceRow.Properties.all, fromTable: Self.table(for: scope)) }
    }

    func replaceTraces(_ scope: TraceScope, with rows: [TraceRow]) {
        let table = Self.table(for: scope)
        write { handle in
            try handle.delete(fromTable: table)
            try handle.insert(rows, intoTable: table)
        }
    }

    func recentUpdates() -> [TraceRow] {
        read([]) {
            try database.getObjects(
                on: TraceRow.Properties.all,
                fromTable: Table.repoTrace,
                where: TraceRow.Properties.lastModification.isNotNull()
            )
        }
    }

    // MARK: - Search

    /// Full-text hits for the key, best first. Every word must match, as a
    /// prefix, so a half-typed word already finds its package.
    func search(_ key: String, limit: Int) -> [SearchRow] {
        let words = key
            .split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        guard !words.isEmpty else { return [] }
        return read([]) {
            try database.getObjects(
                on: SearchRow.Properties.all,
                fromTable: Table.search,
                where: Column(named: Table.search).match(words.joined(separator: " ")),
                orderBy: [Column(named: "rank").asOrder()],
                limit: limit
            )
        }
    }
}

// MARK: - Rows

/// One package of one repository, or one installed package (`repo` empty).
/// The columns the app filters or sorts on are real; the rest is the
/// payload, the same `[version: control fields]` the `Package` value holds.
struct PackageRow: TableCodable {
    var repo = ""
    var identity = ""
    var version = ""
    var name = ""
    var author = ""
    var section = ""
    var payload: [String: [String: String]] = [:]

    enum CodingKeys: String, CodingTableKey {
        typealias Root = PackageRow
        case repo, identity, version, name, author, section, payload

        nonisolated(unsafe) static let objectRelationalMapping = TableBinding(CodingKeys.self) {
            BindIndex(identity, namedWith: "_identity")
            BindIndex(author, namedWith: "_author")
            BindIndex(repo, section, namedWith: "_repo_section")
        }
    }

    init(_ package: Package, repo: String) {
        let meta = package.latestMetadata ?? [:]
        self.repo = repo
        identity = package.identity
        version = package.latestVersion ?? ""
        name = meta["name"] ?? ""
        author = PackageCenter.authors(of: package).joined(separator: ", ")
        section = meta["section"] ?? ""
        payload = package.payload
    }

    var package: Package {
        Package(identity: identity, payload: payload, repoRef: repo.isEmpty ? nil : URL(string: repo))
    }
}

/// What this app installed an identity from: the repository's package as it
/// described that version at the time, so the row draws and reinstalls
/// without the repository. One row per identity, as dpkg installs one.
struct OriginRow: TableCodable {
    var identity = ""
    var repo = ""
    var version = ""
    var payload: [String: [String: String]] = [:]

    enum CodingKeys: String, CodingTableKey {
        typealias Root = OriginRow
        case identity, repo, version, payload

        nonisolated(unsafe) static let objectRelationalMapping = TableBinding(CodingKeys.self) {
            BindColumnConstraint(identity, isPrimary: true)
        }
    }

    init(_ package: Package) {
        identity = package.identity
        repo = package.repoRef?.absoluteString ?? ""
        version = package.latestVersion ?? ""
        payload = package.payload
    }

    var package: Package {
        Package(identity: identity, payload: payload, repoRef: repo.isEmpty ? nil : URL(string: repo))
    }
}

/// A `Provides:` entry and the package that provides it.
struct VirtualRow: TableCodable {
    var name = ""
    var identity = ""
    var repo = ""

    enum CodingKeys: String, CodingTableKey {
        typealias Root = VirtualRow
        case name, identity, repo

        nonisolated(unsafe) static let objectRelationalMapping = TableBinding(CodingKeys.self) {
            BindIndex(name, namedWith: "_name")
            BindIndex(repo, namedWith: "_repo")
        }
    }

    init(name: String, identity: String, repo: String) {
        self.name = name
        self.identity = identity
        self.repo = repo
    }
}

/// Which of the two trace tables a question is about.
public enum TraceScope: String, Sendable {
    case install
    case repo
}

/// When a package was first seen or last changed; one table for the
/// installed side, one for the repositories.
struct TraceRow: TableCodable {
    var identity = ""
    var version = ""
    var repo: String?
    var lastModification: Date?

    enum CodingKeys: String, CodingTableKey {
        typealias Root = TraceRow
        case identity, version, repo, lastModification

        nonisolated(unsafe) static let objectRelationalMapping = TableBinding(CodingKeys.self) {
            BindColumnConstraint(identity, isPrimary: true)
        }
    }

    init(identity: String, version: String, repo: String?, lastModification: Date?) {
        self.identity = identity
        self.version = version
        self.repo = repo
        self.lastModification = lastModification
    }
}

/// The FTS5 side of `package`. WCDB's `Verbatim` tokenizer makes every CJK
/// character its own token, so a two-character Chinese key is a two-token
/// phrase; `repo` is stored, not indexed, so a refresh can drop its rows.
struct SearchRow: TableCodable {
    var identity = ""
    var repo = ""
    var name = ""
    var author = ""
    var section = ""
    var description = ""

    enum CodingKeys: String, CodingTableKey {
        typealias Root = SearchRow
        case identity, repo, name, author, section, description

        nonisolated(unsafe) static let objectRelationalMapping = TableBinding(CodingKeys.self) {
            BindVirtualTable(withModule: .FTS5, and: BuiltinTokenizer.Verbatim)
            BindColumnConstraint(repo, isNotIndexed: true)
        }
    }

    init(_ package: Package, repo: String) {
        let meta = package.latestMetadata ?? [:]
        identity = package.identity
        self.repo = repo
        name = meta["name"] ?? ""
        author = meta["author"] ?? ""
        section = meta["section"] ?? ""
        description = meta["description"] ?? ""
    }
}
