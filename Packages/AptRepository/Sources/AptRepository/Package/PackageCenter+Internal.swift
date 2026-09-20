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
    /// them: the interface reloads and the traces catch up.
    func repositoryDidChange() {
        dispatchNotification()
        updatePackageTracking(disableTableTrace: false)
    }

    // MARK: - LOCAL INSTALL

    /// Parses the dpkg status file and writes the installed table, with the
    /// origins of `sources` beside it. Off the main actor. Returns how many
    /// packages were found.
    nonisolated static func storeInstalled(
        from path: String,
        into db: AptDatabase,
        installedFrom sources: [Package] = []
    ) async -> Int {
        guard let packages = await readInstalled(at: path) else { return db.installed().count }
        db.replaceInstalled(packages, installedFrom: sources)
        return packages.count
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
    /// actor against the database; a newer call cancels the one in flight.
    /// - Parameter disableTableTrace: only update table trace when a repo refreshed
    func updatePackageTracking(disableTableTrace: Bool) {
        traceTask?.cancel()
        let db = index.db
        let initialInstall = RepositoryCenter.default.repositories.mapValues {
            ($0.attachment[.initialInstall] ?? "YES") == "YES"
        }
        let date = Date()
        traceTask = Task { [weak self] in
            guard await Self.trace(
                db,
                disableTableTrace: disableTableTrace,
                initialInstall: initialInstall,
                date: date
            ) else { return }
            guard let self, !Task.isCancelled else { return }
            let interval = Date().timeIntervalSince(date)
            aptLog(self, String(format: "package tracing database updated in %.2fs", interval), level: .info)
            dispatchNotification()
        }
    }

    /// false when cancelled part way; nothing is written then
    nonisolated static func trace(
        _ db: AptDatabase,
        disableTableTrace: Bool,
        initialInstall: [URL: Bool],
        date: Date
    ) async -> Bool {
        // MARK: - INSTALL TRACE

        let installed = db.installed()
        let installedIdentities = Set(installed.map(\.identity))
        var installTraceBuilder = [String: TraceRow]()
        for row in db.traces(.install) where installedIdentities.contains(row.identity) {
            installTraceBuilder[row.identity] = row
        }
        for item in installed {
            if Task.isCancelled {
                return false
            }
            guard let version = item.latestVersion else { continue }
            guard installTraceBuilder[item.identity]?.version != version else { continue }
            installTraceBuilder[item.identity] = TraceRow(
                identity: item.identity,
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
        var newest = [String: (repo: String, version: String)]()
        for (identity, repo, version) in db.newestVersions() {
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
