//
//  PackageIndex.swift
//  AptRepository
//

import Foundation

/// Everything the package center knows, as one value.
///
/// The catalogue lives in the database; this is the handle the center hands
/// out. Work that walks the whole catalogue off the main actor — search,
/// dependency resolution, the dashboard, the traces — takes a copy and asks
/// it, and every answer is a query. The one thing held in the value itself
/// is the user's update block list.
public struct PackageIndex: Sendable {
    let db: AptDatabase

    /// identities the user asked never to be offered an update for
    public internal(set) var blockedUpdateTable: [String] = []

    /// whether a newer version an adapter would have to rewrite counts as
    /// an update; off, a converted package stays at the version it has
    public internal(set) var offersAdaptedUpdates = false

    // MARK: - QUERIES

    /// grab every package identity, useful for search
    /// - Returns: identities
    public func obtainAllPackageIdentity() -> [String] {
        db.identities()
    }

    /// grab a summary of a package
    /// - Parameter identity: identity of the package
    /// - Returns: summary of them
    public func obtainPackageSummary(with identity: String) -> [URL: Package] {
        var result = [URL: Package]()
        for package in db.packages(identity: identity) {
            guard let repo = package.repoRef else { continue }
            result[repo] = package
        }
        return result
    }

    /// one package as one repository offers it
    public func obtainPackage(with identity: String, in repository: URL) -> Package? {
        db.package(identity: identity, repo: repository)
    }

    /// every package a repository offers, or those under one of its sections
    public func obtainPackageList(in repository: URL, section: String? = nil) -> [Package] {
        db.packages(in: repository, section: section)
    }

    /// a repository's sections and how many packages each holds
    public func obtainSectionCounts(in repository: URL) -> [String: Int] {
        db.sectionCounts(in: repository)
    }

    /// grab available authors
    /// - Returns: list of author name
    public func obtainAuthorList() -> [String] {
        db.authors()
    }

    /// obtain packages written by author
    /// - Parameter author: author name
    /// - Returns: packages
    public func obtainPackage(by author: String) -> [Package] {
        db.packages(by: author)
    }

    /// grab package written by author
    /// - Parameter author: author name
    /// - Returns: package identities
    public func obtainAvailablePackageList(writtenBy author: String) -> [String] {
        db.identities(by: author)
    }

    /// returns installed packages
    /// - Returns: array of packages
    public func obtainInstalledPackageList() -> [Package] {
        db.installed()
    }

    /// Every installed package with a newer version on offer, paired with
    /// the newest one. Cydia's own role packages are left out, as every
    /// list that shows updates does. This walks the whole installed list
    /// with a query per package, so ask once, off the main actor.
    public func updateCandidates() -> [(installed: Package, candidate: Package)] {
        obtainInstalledPackageList().compactMap { installed in
            guard !(installed.latestMetadata?["tag"]?.contains("role::cydia") ?? false),
                  let version = installed.latestVersion,
                  let candidate = PackageCenter.default.newestPackage(
                      of: obtainUpdateForPackage(with: installed.identity, version: version),
                      preferring: obtainInstallOrigin(of: installed.identity)?.repoRef
                  )
            else { return nil }
            return (installed, candidate)
        }
    }

    /// returns installation info with package identity
    /// - Parameter identity: id
    /// - Returns: any result if installed, otherwise not installed
    public func obtainPackageInstallationInfo(with identity: String) -> PackageCenter.InstallationInfo? {
        guard let lookup = db.installed(identity: identity),
              let version = lookup.latestVersion
        else {
            return nil
        }
        return .init(
            identity: identity,
            version: version,
            representObject: lookup
        )
    }

    /// The repository package an installed identity came from, as the
    /// repository described it at install time. It draws and reinstalls
    /// without the repository. nil when this app did not install what dpkg
    /// reports, or the version has since changed under it.
    public func obtainInstallOrigin(of identity: String) -> Package? {
        db.installOrigin(identity: identity)
    }

    /// Every install origin by identity, for a list that sorts and searches
    /// its installed rows by what they show.
    public func obtainInstallOrigins() -> [String: Package] {
        db.installOriginPackages()
    }

    /// The package a row or a page describes `package` with. dpkg's record
    /// is the control file and rarely names an icon or a depiction; the
    /// origin is the repository's record of that same version and does. Only
    /// a dpkg row is described by another: a repository's package or a
    /// `.deb` on disk is its own description.
    public func obtainDescription(of package: Package) -> Package {
        guard package.repoRef == nil, package.localFileURL == nil else { return package }
        return obtainInstallOrigin(of: package.identity) ?? package
    }

    /// The updates on offer for an installed package: a newer version from
    /// the repository it was installed from, and from nowhere else. An
    /// identity with no origin (another package manager installed it, or
    /// dpkg by hand) has no repository to keep to, so every repository's
    /// newer version is on offer, as apt would have it; installing one makes
    /// that repository the origin. A version built for another bootstrap is
    /// an update only while `offersAdaptedUpdates` says so: what converted
    /// once and works may not convert as well the next time.
    /// - Parameters:
    ///   - identity: identity in string
    ///   - current: current version
    /// - Returns: the newer versions, one per repository that may offer one
    public func obtainUpdateForPackage(with identity: String, version current: String) -> [Package] {
        guard !blockedUpdateTable.contains(identity) else { return [] }
        let offers = if let origin = obtainInstallOrigin(of: identity)?.repoRef {
            [db.package(identity: identity, repo: origin)].compactMap(\.self)
        } else {
            db.packages(identity: identity)
        }
        return offers.compactMap { updateOffer(in: $0, over: current) }
    }

    /// What of a repository's record is an update over `current`, nil when
    /// nothing is. Judged on the versions that may be one, not on the
    /// newest: a repository can offer a version built for this bootstrap
    /// under a newer one an adapter would have to rewrite, which is an
    /// update only with `offersAdaptedUpdates`, and then only once the
    /// native ones are behind.
    public func updateOffer(in record: Package, over current: String) -> Package? {
        record.update(
            over: current,
            device: AptEnvironment.current.deviceArchitecture,
            accepted: updateArchitectures
        )
    }

    /// What a version may be built for and be an update: the bootstrap's
    /// own, and what an adapter rewrites only with `offersAdaptedUpdates`.
    public var updateArchitectures: Set<String> {
        offersAdaptedUpdates
            ? AptEnvironment.current.installableArchitectures
            : [AptEnvironment.current.deviceArchitecture]
    }

    /// search with virtual package identity that provided by package in return value
    /// - Parameter withIdentity: package identity
    /// - Returns: package that provides this virtual package
    public func obtainVirtualPackageReference(withIdentity: String) -> [String] {
        db.virtualProviders(of: withIdentity)
    }

    /// search for record table, get the last modification time if available
    /// - Parameters:
    ///   - identity: package identity
    ///   - table: the table to search for, either installed or repo table
    /// - Returns: date for last modification, nil if not modified or found
    public func obtainLastModification(for identity: String, and table: TraceScope) -> Date? {
        db.trace(table, identity: identity)?.lastModification
    }

    /// obtain recent update list recorded inside repo
    /// - Returns: list of them, unsorted
    public func obtainRecentUpdatedList() -> [Date: [(String, URL?)]] {
        var result = [Date: [(String, URL?)]]()
        for row in db.recentUpdates() {
            guard let date = row.lastModification else { continue }
            result[date, default: []].append((row.identity, row.repo.flatMap(URL.init(string:))))
        }
        return result
    }

    // MARK: - SEARCH

    /// One full-text hit: the columns the search table holds, enough to draw
    /// a row without touching the package itself.
    public struct SearchHit: Sendable {
        public let identity: String
        public let repository: URL
        public let name: String
        public let author: String
        public let section: String
        public let description: String
    }

    /// Full-text search over every repository package, best match first.
    public func search(_ key: String, limit: Int = 200) -> [SearchHit] {
        db.search(key, limit: limit).compactMap { row in
            guard let repository = URL(string: row.repo) else { return nil }
            return SearchHit(
                identity: row.identity,
                repository: repository,
                name: row.name,
                author: row.author,
                section: row.section,
                description: row.description
            )
        }
    }
}
