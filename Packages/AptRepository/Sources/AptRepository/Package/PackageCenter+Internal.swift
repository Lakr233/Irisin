//
//  Project Irisin
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

extension PackageCenter {
    /// send notification to ui to reload when install or repo record changes
    func dispatchNotification() {
        notificationThrottle.throttle {
            NotificationCenter.default.post(name: PackageCenter.packageRecordChanged, object: nil)
        }
    }

    /// The repository center wrote a repository's packages, or dropped
    /// them: the interface reloads, the packages the lists hold are read
    /// again and the traces catch up.
    func repositoryDidChange() {
        lookups.invalidate()
        dispatchNotification()
        updatePackageTracking(disableTableTrace: false)
    }

    // MARK: - LOCAL INSTALL

    /// Parses the dpkg status file and writes the installed table, with the
    /// origins of `sources` beside it. Off the main actor. Returns what the
    /// database now holds, for the center to answer from: the packages as
    /// parsed, and the origins read back, since the write decides which of
    /// them stay.
    nonisolated static func storeInstalled(
        from path: String,
        into db: AptDatabase,
        installedFrom sources: [Package] = []
    ) async -> InstalledSnapshot {
        guard let packages = await readInstalled(at: path) else { return InstalledSnapshot(reading: db) }
        db.replaceInstalled(packages, installedFrom: sources)
        return InstalledSnapshot(packages: Array(packages.values), origins: db.installOriginPackages())
    }

    nonisolated static func readInstalled(at path: String) async -> [String: Package]? {
        do {
            return try DpkgStatus.packages(in: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            aptLog(
                Self.self,
                "Could not read dpkg status; retaining previous installed records: \(error)",
                level: .error
            )
            return nil
        }
    }

    // MARK: - TRACING

    /// Records when packages appeared or changed. The walk runs off the main
    /// actor against the database, once things are quiet: a refresh writes
    /// one repository after another, and each asks, so a newer call cancels
    /// the one waiting or in flight and the walk runs once, after the last.
    /// A repository trace asked for and not yet run is kept through an
    /// installed-only call that replaces it.
    /// - Parameter disableTableTrace: only update table trace when a repo refreshed
    func updatePackageTracking(disableTableTrace: Bool) {
        traceTask?.cancel()
        if !disableTableTrace {
            traceWantsTable = true
        }
        traceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.traceQuietPeriod)
            guard let self, !Task.isCancelled else { return }
            let table = traceWantsTable
            traceWantsTable = false
            let date = Date()
            let traced = await Self.trace(
                index.db,
                disableTableTrace: !table,
                initialInstall: RepositoryCenter.default.repositories.mapValues {
                    ($0.attachment[.initialInstall] ?? "YES") == "YES"
                },
                installed: index.installedSnapshot.map { $0.packages.compactMapValues(\.latestVersion) },
                date: date
            )
            guard traced else {
                // cancelled: the call that did it runs what this one did not
                traceWantsTable = traceWantsTable || table
                return
            }
            let interval = Date().timeIntervalSince(date)
            aptLog(self, String(format: "package tracing database updated in %.2fs", interval), level: .info)
            dispatchNotification()
        }
    }

    /// how long tracing waits for the last of a burst of calls, in nanoseconds
    nonisolated static let traceQuietPeriod: UInt64 = 1_000_000_000

    /// false when cancelled part way; nothing is written then
    /// - Parameter installed: every installed identity's version, as the
    ///   center holds them; nil reads them from the database
    nonisolated static func trace(
        _ db: AptDatabase,
        disableTableTrace: Bool,
        initialInstall: [URL: Bool],
        installed: [String: String]? = nil,
        date: Date
    ) async -> Bool {
        // MARK: - INSTALL TRACE

        // identities and versions, never the payload: nothing here reads it
        let installed = installed ?? db.installedVersions()
        var installTraceBuilder = [String: TraceRow]()
        for row in db.traces(.install) where installed[row.identity] != nil {
            installTraceBuilder[row.identity] = row
        }
        for (identity, version) in installed {
            if Task.isCancelled {
                return false
            }
            guard installTraceBuilder[identity]?.version != version else { continue }
            installTraceBuilder[identity] = TraceRow(
                identity: identity,
                version: version,
                repo: nil,
                lastModification: date
            )
        }
        if disableTableTrace {
            db.replaceTraces(.install, with: [TraceRow](installTraceBuilder.values))
            return true
        }

        // MARK: - TABLE TRACE

        // newest version of every identity across the repositories, from a
        // projection of three columns: version order is not SQL's to decide
        let offered = db.newestVersions()
        if Task.isCancelled {
            return false
        }
        var newest = [String: (repo: String, version: String)]()
        for (identity, repo, version) in offered {
            // DebianVersion.compare rather than Package.compareVersion: the
            // latter validates both sides first, which parses each string
            // twice over, and an unparseable pair compares equal either way
            if let known = newest[identity],
               DebianVersion.compare(version, known.version) <= 0
            {
                continue
            }
            newest[identity] = (repo, version)
        }

        if Task.isCancelled {
            return false
        }
        var tableTraceBuilder = [String: TraceRow]()
        for row in db.traces(.repo) where newest[row.identity] != nil {
            // delete removed packages
            tableTraceBuilder[row.identity] = row
        }
        for (item, found) in newest {
            if Task.isCancelled {
                return false
            }
            let newestVersion = found.version
            let repoRef = found.repo
            // A downgrade, and a package first seen during a repository's
            // initial load, get no date, so they stay out of the recent-updates list.
            let lastModification: Date?
            if let fetch = tableTraceBuilder[item] {
                let compare = DebianVersion.compare(newestVersion, fetch.version)
                guard compare != 0 else { continue }
                lastModification = compare > 0 ? date : nil
            } else if let url = URL(string: repoRef), initialInstall[url] ?? true {
                lastModification = nil
            } else {
                lastModification = date
            }
            tableTraceBuilder[item] = TraceRow(
                identity: item,
                version: newestVersion,
                repo: repoRef,
                lastModification: lastModification
            )
        }
        if Task.isCancelled {
            return false
        }
        db.replaceTraces(.install, with: [TraceRow](installTraceBuilder.values))
        db.replaceTraces(.repo, with: [TraceRow](tableTraceBuilder.values))
        return true
    }
}
