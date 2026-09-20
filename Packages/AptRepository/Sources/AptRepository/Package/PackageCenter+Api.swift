//
//  Project Irisin
//  Irisin
//
//  Created by Lakr Aream on 2021/8/14.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

public extension PackageCenter {
    /// Re-reads the bootstrap's dpkg status; returns once the new list is in
    /// place. The parse itself runs off the main actor.
    /// - Parameter sources: the packages a transaction just installed; each
    ///   repository package dpkg now reports becomes its identity's origin
    func reloadLocalPackages(installedFrom sources: [Package] = []) async {
        let count = await Self.storeInstalled(
            from: AptEnvironment.current.dpkgStatusLocation,
            into: index.db,
            installedFrom: sources
        )
        aptLog(self, "updating installation info reported \(count) pacakges")
        dispatchNotification()
        updatePackageTracking(disableTableTrace: true)
    }

    /// The repository package an installed identity came from, as the
    /// repository described it then: nil when this app did not install
    /// what dpkg reports.
    func obtainInstallOrigin(of identity: String) -> Package? {
        index.obtainInstallOrigin(of: identity)
    }

    /// every install origin by identity
    func obtainInstallOrigins() -> [String: Package] {
        index.obtainInstallOrigins()
    }

    /// The package a row or a page describes `package` with: the install
    /// origin of a dpkg row, the package itself otherwise.
    func obtainDescription(of package: Package) -> Package {
        index.obtainDescription(of: package)
    }

    // MARK: - QUERIES

    // Each of these is the same lookup on `index`; the value is public for
    // callers that run off the main actor.

    /// grab a summary of a package
    func obtainPackageSummary(with identity: String) -> [URL: Package] {
        index.obtainPackageSummary(with: identity)
    }

    /// one package as one repository offers it
    func obtainPackage(with identity: String, in repository: URL) -> Package? {
        index.obtainPackage(with: identity, in: repository)
    }

    /// a repository's sections and how many packages each holds
    func obtainSectionCounts(in repository: URL) -> [String: Int] {
        index.obtainSectionCounts(in: repository)
    }

    /// obtain packages written by author
    func obtainPackage(by author: String) -> [Package] {
        index.obtainPackage(by: author)
    }

    /// returns installed packages
    func obtainInstalledPackageList() -> [Package] {
        index.obtainInstalledPackageList()
    }

    /// returns installation info with package identity
    func obtainPackageInstallationInfo(with identity: String) -> InstallationInfo? {
        index.obtainPackageInstallationInfo(with: identity)
    }

    /// obtain update for package at current version
    func obtainUpdateForPackage(with identity: String, version current: String) -> [Package] {
        index.obtainUpdateForPackage(with: identity, version: current)
    }

    /// search for record table, get the last modification time if available
    func obtainLastModification(for identity: String, and table: TraceScope) -> Date? {
        index.obtainLastModification(for: identity, and: table)
    }

    /// obtain recent update list recorded inside repo
    func obtainRecentUpdatedList() -> [Date: [(String, URL?)]] {
        index.obtainRecentUpdatedList()
    }

    /// returns author names, email trimmed; pure, callable from anywhere
    nonisolated static func authors(of object: Package) -> [String] {
        func cleanEmails(str: String) -> String {
            if str.contains("<"),
               str.contains("@"),
               str.contains(">")
            {
                return str
                    .components(separatedBy: "<")
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
            }
            return str
        }

        guard let text = object.latestMetadata?["author"] else { return [] }
        return text
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { cleanEmails(str: $0) }
    }
}
