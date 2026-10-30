//
//  WebCalls.swift
//  Irisin
//

import AptRepository
import AptResolver
import Foundation
import IrisinProtocol
import IrisinWeb
import UIKit

/// What a browser's calls do on this device: the ops of
/// `Packages/IrisinWeb/README.md`, answered on the main actor, where the
/// centers keep their state. A read answers at once. A change answers with
/// a request that waits for the owner's yes on the device (`WebRun`), and
/// the page polls it.
///
/// Paid packages are not offered: a vendor sign-in is the device's own, and
/// the page has no way to it.
enum WebCalls {
    /// What the server holds. Each call hops to the main actor.
    nonisolated struct Responder: WebResponder {
        func answer(_ op: String, _ args: JSONValue) async -> WebAnswer {
            await WebCalls.answer(op, args)
        }

        func stream(after: Int, send: @escaping @Sendable (JSONValue) async -> Bool) async {
            await WebCalls.stream(after: after, send: send)
        }
    }

    static func answer(_ op: String, _ args: JSONValue) async -> WebAnswer {
        switch op {
        case "device":
            return .result(device())
        case "repositories":
            return .result(repositories())
        case "refresh":
            RepositoryCenter.default.dispatchForceUpdateRequestOnAll()
            return .result(.object([:]))
        case "addRepository":
            return addRepository(args["url"]?.string ?? "")
        case "removeRepository":
            return removeRepository(args["url"]?.string ?? "")
        case "search":
            return await search(args["query"]?.string ?? "", limit: args["limit"]?.integer ?? 50)
        case "package":
            return package(args["id"]?.string ?? "")
        case "installed":
            return .result(installed())
        case "updates":
            return .result(updates())
        case "propose":
            return await propose(args)
        case "plan":
            return .result(plan())
        case "clear":
            guard !isBusy else { return .failure(busy) }
            PackageQueue.shared.clear()
            return .result(.object([:]))
        case "confirm":
            return WebRun.confirm(plan: args["plan"]?.string ?? "")
        case "respring":
            return WebRun.respring()
        case "request":
            guard let id = args["id"]?.string.flatMap(UUID.init(uuidString:)),
                  let request = WebManagement.shared.requests.json(id)
            else {
                return .failure(String(localized: "The device no longer knows this request."))
            }
            return .result(request)
        case "storage":
            return .result(storage())
        case "clearDownloads":
            return clearDownloads()
        case "exportRepositories":
            return exportRepositories()
        case "importRepositories":
            // a file the page read, base64, or text typed or pasted
            let file = args["base64"]?.string.flatMap { Data(base64Encoded: $0) }
            return importRepositories(file ?? Data((args["text"]?.string ?? "").utf8))
        default:
            return .failure(String(localized: "The device does not answer \(op)."))
        }
    }

    /// The operation's frames after `after`, read a few times a second
    /// until it has ended.
    static func stream(after: Int, send: @escaping @Sendable (JSONValue) async -> Bool) async {
        var last = after
        while true {
            let (frames, finished) = WebManagement.shared.feed.frames(after: last)
            for frame in frames {
                guard await send(frame) else { return }
                last += 1
            }
            if finished {
                return
            }
            try? await Task.sleep(continuousSeconds: OperationFeed.interval)
        }
    }

    // MARK: - Device

    /// An operation stages or runs, here or from the page.
    static var isBusy: Bool {
        Installer.shared.inProcessingQueue || WebRun.isRunning
    }

    static let busy = String(localized: "Another operation is already running. Wait for it to finish, then try again.")

    /// Update All held back updates that a move to another repository lets
    /// through. The page does not move anything: on iOS the app's Update
    /// All offers the move.
    static let needsMigration = String(localized: "Some updates were held back: they need packages from a repository other than the one each was installed from.")

    private static func device() -> JSONValue {
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary
        let version = [info?["CFBundleShortVersionString"], info?["CFBundleVersion"]]
            .compactMap { $0 as? String }
        let free = (try? documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity ?? 0
        return .object([
            "name": .string(device.name),
            "model": .string(DeviceIdentity.machine),
            "system": .string("\(device.systemName) \(device.systemVersion)"),
            "bootstrap": .string(bootstrap),
            "architecture": .string(PackagedArchitecture.architecture),
            "irisinVersion": .string(version.count == 2 ? "\(version[0]) (\(version[1]))" : version.first ?? ""),
            "freeSpace": .integer(free),
            "busy": .bool(isBusy),
            "canInstall": .bool(PrivilegedBackend.backend?.isPrivileged == true),
            "backend": .string(PrivilegedBackend.localizedStatus),
        ])
    }

    private static var bootstrap: String {
        #if targetEnvironment(simulator)
            "Simulator"
        #else
            JailbreakRoot.isRoothide ? "RootHide" : "rootless"
        #endif
    }

    // MARK: - Repositories

    private static func repositories() -> JSONValue {
        let center = RepositoryCenter.default
        let dates = ISO8601DateFormatter()
        return .array(center.obtainRepositoryUrls(sortedByName: true).compactMap { url -> JSONValue? in
            guard let repository = center.repositories[url] else { return nil }
            let refreshing = center.isRepositoryPreparedForUpdate(withUrl: url)
            let refreshed = repository.lastUpdatePackage.timeIntervalSince1970 > 0
                ? JSONValue.string(dates.string(from: repository.lastUpdatePackage))
                : .null
            return .object([
                "url": .string(url.absoluteString),
                "name": .string(repository.nickName),
                "packageCount": .integer(repository.packageCount),
                "refreshed": refreshed,
                "refreshing": .bool(refreshing),
                "problem": refreshing ? .null : problem(of: repository).map(JSONValue.string) ?? .null,
            ])
        })
    }

    /// What the last refresh said went wrong, as the repository's page
    /// says it; nil when it went through or never ran.
    private static func problem(of repository: Repository) -> String? {
        guard let report = repository.refreshReport, !report.issues.isEmpty else { return nil }
        let refreshed = DateFormatter.localizedString(from: report.date, dateStyle: .medium, timeStyle: .short)
        return report.issues.map { $0.sentence(refreshed: refreshed) }.uniqued().joined(separator: " ")
    }

    /// The repository a page names, by its address as `repositories` gave it.
    private static func repository(named text: String) -> URL? {
        RepositoryCenter.default.repositories.keys.first { $0.absoluteString == text }
    }

    private static func addRepository(_ text: String) -> WebAnswer {
        guard let source = RepositorySource(line: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(String(localized: "This is not a repository address."))
        }
        guard RepositoryCenter.default.repositories[source.url] == nil else {
            return .failure(String(localized: "This repository is already added."))
        }
        return WebRun.ask(.init(
            title: String(localized: "Add Repository"),
            lines: [source.line],
            confirmTitle: String(localized: "Add"),
            destructive: false
        )) {
            RepositoryCenter.default.registerRepository(source)
            return nil
        }
    }

    private static func removeRepository(_ text: String) -> WebAnswer {
        guard let url = repository(named: text), let repository = RepositoryCenter.default.repositories[url] else {
            return .failure(String(localized: "This repository is not added."))
        }
        return WebRun.ask(.init(
            title: String(localized: "Delete Repository"),
            lines: [repository.nickName, url.absoluteString],
            confirmTitle: String(localized: "Delete"),
            destructive: true
        )) {
            RepositoryCenter.default.deleteRepository(withUrl: url)
            return nil
        }
    }

    // MARK: - Packages

    private static func search(_ query: String, limit: Int) async -> WebAnswer {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return .result(.array([])) }
        let names = RepositoryCenter.default.repositories.mapValues(\.nickName)
        let rows = await searchRows(
            key,
            limit: min(max(limit, 1), 200),
            index: PackageCenter.default.index,
            repositoryNames: names
        )
        return .result(.array(rows))
    }

    /// The full-text index's hits, a name or identity that starts with the
    /// words first, as the search page ranks them; off the main actor, where
    /// a query over every repository belongs.
    @concurrent
    private nonisolated static func searchRows(
        _ key: String,
        limit: Int,
        index: PackageIndex,
        repositoryNames: [URL: String]
    ) async -> [JSONValue] {
        let hits = index.search(key, limit: 200).enumerated().map { order, hit in
            let name = hit.name.isEmpty ? hit.identity : hit.name
            let score = [name, hit.identity].filter { $0.lowercased().hasPrefix(key) }.count
            return (hit: hit, name: name, score: score, order: order)
        }
        return hits
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit)
            .map { row in
                let record = index.obtainPackage(with: row.hit.identity, in: row.hit.repository)
                let installed = index.obtainPackageInstallationInfo(with: row.hit.identity)?.version
                return .object([
                    "id": .string(row.hit.identity),
                    "name": .string(row.name),
                    "version": .string(record?.latestVersion ?? ""),
                    "section": .string(row.hit.section),
                    "summary": .string(firstLine(of: row.hit.description)),
                    "repository": .string(repositoryNames[row.hit.repository] ?? row.hit.repository.host ?? ""),
                    "installed": installed.map(JSONValue.string) ?? .null,
                ])
            }
    }

    private nonisolated static func firstLine(of text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }

    /// Every repository's record of the package, newest first, and the one
    /// to install: the newest that installs here, from the repository it
    /// came from when versions tie.
    private static func records(of identity: String) -> (all: [Package], newest: Package?) {
        let index = PackageCenter.default.index
        let all = Array(index.obtainPackageSummary(with: identity).values)
        let origin = index.obtainInstallOrigin(of: identity)?.repoRef
        return (all, PackageCenter.default.newestPackage(of: all, preferring: origin))
    }

    private static func package(_ identity: String) -> WebAnswer {
        let index = PackageCenter.default.index
        let (all, newest) = records(of: identity)
        let installed = index.obtainPackageInstallationInfo(with: identity)
        guard let package = newest ?? installed?.representObject else {
            return .failure(String(localized: "No repository offers this package."))
        }
        let meta = package.latestMetadata ?? [:]
        let device = PackagedArchitecture.architecture
        let versions = Set(all.flatMap { ($0.versions(builtFor: device) ?? $0).payload.keys })
            .sorted { DebianVersion.compare($0, $1) > 0 }
        let description = meta["description"] ?? ""
        let lines = description.components(separatedBy: "\n")
        let long = lines.dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0 == "." ? "" : $0 }
            .joined(separator: "\n")
        return .result(.object([
            "id": .string(identity),
            "name": .string(PackageCenter.default.name(of: package)),
            "version": .string(package.latestVersion ?? ""),
            "versions": .array(versions.map(JSONValue.string)),
            "section": .string(meta["section"] ?? ""),
            "author": .string(meta["author"] ?? ""),
            "maintainer": .string(meta["maintainer"] ?? ""),
            "summary": .string(lines.first ?? ""),
            "description": .string(long),
            "depends": .string(meta["depends"] ?? meta["pre-depends"] ?? ""),
            "repository": .string(package.repoRef.flatMap { RepositoryCenter.default.repositories[$0]?.nickName } ?? ""),
            "installed": installed.map { .string($0.version) } ?? .null,
            "size": .integer(Int(meta["size"] ?? "") ?? 0),
            "installedSize": .integer((Int(meta["installed-size"] ?? "") ?? 0) * 1024),
            "homepage": meta["homepage"].map(JSONValue.string) ?? .null,
            "paid": .bool(isPaid(package)),
        ]))
    }

    private static func isPaid(_ package: Package) -> Bool {
        package.latestMetadata?["tag"]?.contains("cydia::commercial") ?? false
    }

    private static func installed() -> JSONValue {
        .array(PackageCenter.default.index.obtainInstalledPackageList().map { package in
            .object([
                "id": .string(package.identity),
                "name": .string(PackageCenter.default.name(of: package)),
                "version": .string(package.latestVersion ?? ""),
                "section": .string(package.latestMetadata?["section"] ?? ""),
            ])
        })
    }

    private static func updates() -> JSONValue {
        .array(PackageCenter.default.index.updateCandidates().map { installed, candidate in
            .object([
                "id": .string(installed.identity),
                "name": .string(PackageCenter.default.name(of: candidate)),
                "installed": .string(installed.latestVersion ?? ""),
                "available": .string(candidate.latestVersion ?? ""),
                "repository": .string(candidate.repoRef.flatMap { RepositoryCenter.default.repositories[$0]?.nickName } ?? ""),
            ])
        })
    }

    // MARK: - Queue

    /// Solves the queue with what the page asked for and takes it as the
    /// queue, as the app's own sheet does once its plan is shown: the page
    /// shows this plan, and the owner sees it again on the device before
    /// anything runs.
    private static func propose(_ args: JSONValue) async -> WebAnswer {
        guard !isBusy else { return .failure(busy) }
        var actions: [ResolutionAction] = []
        var notices: [String] = []
        if args["updateAll"] == .bool(true) {
            switch await PackageQueue.shared.updateAllActions() {
            case let .success(found):
                actions += found.actions
                notices += found.notices
                if found.migration != nil {
                    notices.append(Self.needsMigration)
                }
            case let .failure(failure):
                return .failure(failure.message)
            }
        }
        for item in args["install"]?.array ?? [] {
            guard let identity = item["id"]?.string else { continue }
            switch candidate(identity, version: item["version"]?.string) {
            case let .success(package):
                actions.append(.install(package))
            case let .failure(reason):
                return .failure(reason.message)
            }
        }
        for item in args["remove"]?.array ?? [] {
            guard let identity = item.string else { continue }
            guard PackageCenter.default.index.obtainPackageInstallationInfo(with: identity) != nil else {
                return .failure(String(localized: "\(identity) is not installed."))
            }
            actions.append(.remove(identity))
        }
        guard !actions.isEmpty else {
            // an update of everything that held every update back says why
            return .failure(notices.isEmpty ? String(localized: "There is nothing to change.") : notices.joined(separator: "\n"))
        }
        // a proposal the queue moved under is solved once more
        for _ in 0 ..< 2 {
            switch await PackageQueue.shared.propose(actions, notices: notices) {
            case let .success(proposal):
                if PackageQueue.shared.commit(proposal) {
                    return .result(plan())
                }
            case let .failure(failure):
                return .failure(failure.message)
            }
        }
        return .failure(String(localized: "Packages changed while checking dependencies. Try again."))
    }

    private struct Refusal: Error {
        let message: String
    }

    /// The record to install: the version asked for, or the newest that
    /// installs here.
    private static func candidate(_ identity: String, version: String?) -> Result<Package, Refusal> {
        let (all, newest) = records(of: identity)
        let chosen: Package?
        if let version, !version.isEmpty {
            let origin = PackageCenter.default.index.obtainInstallOrigin(of: identity)?.repoRef
            // the repository it came from first, then the rest
            chosen = all.sorted { $0.repoRef == origin && $1.repoRef != origin }
                .lazy
                .compactMap { PackageCenter.default.trim(package: $0, toVersion: version) }
                .first { $0.isSupportedOnDevice }
            guard chosen != nil else {
                return .failure(Refusal(message: String(localized: "No repository offers version \(version) of \(identity).")))
            }
        } else {
            chosen = newest
        }
        guard let chosen else {
            return .failure(Refusal(message: String(localized: "No repository offers \(identity) for this device.")))
        }
        guard !isPaid(chosen) else {
            return .failure(Refusal(message: String(localized: "\(PackageCenter.default.name(of: chosen)) is a paid package. Paid packages cannot be installed from a browser.")))
        }
        return .success(chosen)
    }

    /// The queue's plan as the page shows it, or null when the queue is empty.
    static func plan() -> JSONValue {
        let queue = PackageQueue.shared
        guard let plan = queue.plan else { return .null }
        let names = RepositoryCenter.default.repositories.mapValues(\.nickName)
        let install = plan.install.map { package -> JSONValue in
            .object([
                "id": .string(package.identity),
                "name": .string(PackageCenter.default.name(of: package)),
                "version": .string(package.latestVersion ?? ""),
                "repository": .string(package.repoRef.flatMap { names[$0] } ?? ""),
                "size": .integer(size(of: package)),
            ])
        }
        let remove = plan.remove.map { package -> JSONValue in
            .object([
                "id": .string(package.identity),
                "name": .string(PackageCenter.default.name(of: package)),
                "version": .string(package.latestVersion ?? ""),
            ])
        }
        let downloads = plan.install.filter { $0.localFileURL == nil }.map(size(of:)).reduce(0, +)
        return .object([
            "id": .string(plan.id.uuidString),
            "install": .array(install),
            "remove": .array(remove),
            "downloadSize": .integer(downloads),
            "notes": .array(queue.notices.map(JSONValue.string)),
            "blocked": queue.blocked.map(JSONValue.string) ?? .null,
        ])
    }

    private static func size(of package: Package) -> Int {
        Int(package.latestMetadata?["size"] ?? "") ?? 0
    }

    // MARK: - Data

    /// What Irisin keeps on this device, in bytes: everything in its folder,
    /// and of that the catalogue, the downloads and the logs.
    private static func storage() -> JSONValue {
        let downloads = [Downloads.shared.workingLocation, PartialDownloads.directory, Installer.shared.workingLocation]
            .map(allocatedSize(of:)).reduce(0, +)
        let catalogue = ["apt.db", "apt.db-wal", "apt.db-shm"]
            .map { allocatedSize(of: documentsDirectory.appendingPathComponent($0)) }.reduce(0, +)
        let total = allocatedSize(of: documentsDirectory)
        let free = (try? documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity ?? 0
        return .object([
            "total": .integer(total),
            "catalogue": .integer(catalogue),
            "downloads": .integer(downloads),
            "other": .integer(max(total - catalogue - downloads, 0)),
            "freeSpace": .integer(free),
            "repositories": .integer(RepositoryCenter.default.obtainRepositoryCount()),
        ])
    }

    /// A file's size on disk, or everything under a directory.
    private static func allocatedSize(of url: URL) -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return (try? url.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0
        }
        var total = (try? url.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: keys).totalFileAllocatedSize) ?? 0
        }
        return total
    }

    /// What Settings' Clear Downloads does: every download, the partial
    /// ones and the staged copies, never while an operation reads them.
    private static func clearDownloads() -> WebAnswer {
        guard !isBusy else { return .failure(busy) }
        Downloads.shared.clear()
        try? FileManager.default.removeItem(at: documentsDirectory.appendingPathComponent("DirectInstallCache"))
        try? FileManager.default.removeItem(at: Installer.shared.workingLocation)
        return .result(storage())
    }

    /// The repository list as Export Repository List writes it: addresses
    /// only, a `.irisinrepos` another Irisin imports.
    private static func exportRepositories() -> WebAnswer {
        let center = RepositoryCenter.default
        let sources = center.obtainRepositoryUrls(sortedByName: true).compactMap { center.repositories[$0]?.source }
        guard let data = try? RepositoryListFile(sources: sources).encoded() else {
            return .failure(String(localized: "The repository list could not be written."))
        }
        return .result(.object([
            "name": .string("Repositories.irisinrepos"),
            "text": .string(String(decoding: data, as: UTF8.self)),
            "count": .integer(sources.count),
        ]))
    }

    /// A `.irisinrepos` or `.irisinrepo`, or a plain list of addresses, one
    /// a line: the addresses and nothing else, as every import takes them.
    /// Those not yet added are put to the owner.
    private static func importRepositories(_ data: Data) -> WebAnswer {
        var sources: [RepositorySource]
        do {
            sources = try RepositoryListFile.sources(in: data)
        } catch RepositoryFileFailure.unsupportedFormat {
            return .failure(String(localized: "This file was made by a newer Irisin."))
        } catch {
            // a list is read for its addresses alone: a line that names no
            // scheme is prose, which the parser would take for a host
            sources = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("deb ") || $0.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil }
                .compactMap(RepositorySource.init(line:))
        }
        let known = RepositoryCenter.default.repositories
        sources = sources.uniqued().filter { known[$0.url] == nil }
        guard !sources.isEmpty else {
            return .failure(String(localized: "There are no new repositories in it."))
        }
        return WebRun.ask(.init(
            title: String(localized: "Add Repositories"),
            lines: sources.map(\.line),
            confirmTitle: String(localized: "Add"),
            destructive: false
        )) {
            for source in sources where RepositoryCenter.default.repositories[source.url] == nil {
                RepositoryCenter.default.registerRepository(source)
            }
            return nil
        }
    }
}
