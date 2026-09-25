//
//  RepositoryCenter+Api.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/6.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Foundation

public extension RepositoryCenter {
    /// Register a repo to let us manage it
    /// - Parameter source: the address, with the suite and components of a
    ///   distribution when it has them
    func registerRepository(_ source: RepositorySource) {
        defer { issueNotification() }
        guard source.isValid else {
            aptLog(self, "repository source \(source.line) is malformed, abort!", level: .error)
            return
        }

        if repositories[source.url] != nil {
            aptLog(self, "repository already exists, abort!", level: .error)
            return
        }

        let builder = Repository(source: source)
        commit(builder)

        aptLog(self, "registering repository \(source.line) giving nickname \(builder.nickName)")

        dispatchUpdateOnRepository(withUrl: source.url)
    }

    /// grab repo detail
    /// - Parameter withUrl: the url of repository
    func obtainImmutableRepository(withUrl url: URL) -> Repository? {
        guard let access = repositories[url] else {
            aptLog(self, "repository \(url.absoluteString) was not found")
            return nil
        }
        return access
    }

    /// grab count of remaining update task
    /// - Returns: count
    func obtainUpdateRemain() -> Int {
        pendingUpdateRequest.count + currentlyInUpdate.subtracting(deletedUpdates).count
    }

    /// Where a repository stands in the update queue. Changes are announced
    /// by `metadataUpdate`, with the fraction moving as the download does.
    enum UpdateState: Equatable, Sendable {
        case idle
        case pending
        case updating(fraction: Double)
    }

    func updateState(withUrl url: URL) -> UpdateState {
        if let progress = currentUpdateProgress[url] {
            return .updating(fraction: progress.fractionCompleted)
        }
        if pendingUpdateRequest.contains(url) {
            return .pending
        }
        return .idle
    }

    /// How the repository stands, for its dot; nil when there is none.
    /// Packages from a refresh that had trouble, or from over a day ago,
    /// are still packages: degraded, not failed.
    func refreshHealth(withUrl url: URL) -> RepositoryHealth? {
        guard let repo = repositories[url] else {
            aptLog(self, "requested repository \(url.absoluteString) was not found")
            return nil
        }
        if isRepositoryPreparedForUpdate(withUrl: url) {
            return .pending
        }
        if repo.packageCount < 1 {
            return .failed
        }
        if Date().timeIntervalSince(repo.lastUpdatePackage) > Double(smartUpdateTimeInterval) {
            return .degraded
        }
        guard let report = repo.refreshReport else {
            // refreshed before reports were kept: the next refresh says
            return repo.metaRelease.isEmpty ? .degraded : .ready
        }
        return report.issues.isEmpty ? .ready : .degraded
    }

    /// indicates if this repo is in update queue, both pending and current
    /// - Parameter url: the url of repository
    /// - Returns: if it is
    func isRepositoryPreparedForUpdate(withUrl url: URL) -> Bool {
        pendingUpdateRequest.contains(url) || currentlyInUpdate.contains(url)
    }

    /// grab the count of repo
    /// - Returns: count
    func obtainRepositoryCount() -> Int {
        repositories.count
    }

    /// grab all repo urls
    /// - Returns: url can be used to identify the repo
    func obtainRepositoryUrls(sortedByName: Bool = false) -> [URL] {
        if sortedByName {
            return repositories.values.sorted { $0.nickName < $1.nickName }.map(\.url)
        }
        return [URL](repositories.keys).sorted { $0.absoluteString < $1.absoluteString }
    }

    /// modify repository within sync call block
    /// - Parameters:
    ///   - url: the url of repository
    ///   - withUpdate: modify the value passed in this sync inout block
    func updateRepository(withUrl url: URL, withUpdate: (inout Repository) -> Void) {
        guard var builder = repositories[url] else {
            aptLog(self, "requesting update on repository \(url.absoluteString) was not found")
            return
        }
        withUpdate(&builder)
        commit(builder)
    }

    /// delete repository, default will save it to history
    /// - Parameter withUrl: the url of repository
    @discardableResult
    func deleteRepository(withUrl: URL) -> Repository? {
        defer {
            issueNotification()
        }
        let deleted = repositories.removeValue(forKey: withUrl)
        pendingUpdateRequest.remove(withUrl)
        refreshRound?.ordered.remove(withUrl)
        currentUpdateProgress.removeValue(forKey: withUrl)
        // A fetch in flight is cancelled, not waited for. It stays in the
        // queue until its task ends, so a re-added repository's refresh
        // still waits its turn behind it.
        if let task = updateTasks[withUrl], !deletedUpdates.contains(withUrl) {
            task.cancel()
            deletedUpdates.insert(withUrl)
            stalledUpdates.remove(withUrl)
            aptLog(self, "update \(withUrl.absoluteString) cancelled: the repository was deleted", level: .info)
        }
        guard let deleted else {
            aptLog(self, "requesting delete on repository \(withUrl.absoluteString) was not found")
            return nil
        }
        historyRecords.insert(deleted.source.line)
        // in order, so a re-added repository's refresh, which writes after
        // every write asked before it began, cannot land its rows before
        // this delete runs; the packages are gone once it has
        write { db in
            db.delete(repository: withUrl)
            db.deletePackages(of: withUrl)
        } then: {
            PackageCenter.default.repositoryDidChange()
        }
        return deleted
    }

    /// How old a repository may be before the Repositories page's refresh
    /// asks for it: a day, or the automatic refresh's interval when that is
    /// shorter, so the page never calls current what is about to be
    /// refreshed on its own.
    var smartUpdateAge: TimeInterval {
        let day = Double(smartUpdateTimeInterval)
        let automatic = automaticRefreshInterval
        return automatic > 0 ? min(automatic, day) : day
    }

    /// check every repository if it requires an update
    /// and dispatch them if needed
    /// - Returns: has update dispatched
    @discardableResult
    func dispatchSmartUpdateRequestOnAll() -> Bool {
        !dispatchUpdates(olderThan: smartUpdateAge).isEmpty
    }

    /// Refreshes what is older than `automaticRefreshInterval`, and nothing
    /// while that is zero. Once the database is read: an empty list before
    /// that says nothing. A repository it queued is not queued by it again
    /// for an interval, whether or not that refresh succeeded: one that
    /// keeps failing is tried once per interval, not at every look.
    /// - Returns: has update dispatched
    @discardableResult
    func dispatchAutomaticRefresh() -> Bool {
        let interval = automaticRefreshInterval
        guard isLoaded, interval > 0 else { return false }
        let now = Date()
        let queued = dispatchUpdates(olderThan: interval) { [automaticAttempts] repo in
            automaticAttempts[repo.url].map { now.timeIntervalSince($0) > interval } ?? true
        }
        for url in queued {
            automaticAttempts[url] = now
        }
        if !queued.isEmpty {
            aptLog(
                self,
                "automatic refresh: \(queued.count) repositories older than \(Self.seconds(interval)) queued",
                level: .info
            )
        }
        return !queued.isEmpty
    }

    /// Queues every repository older than `age`, not in flight, and let
    /// through by `include`; returns those queued.
    private func dispatchUpdates(
        olderThan age: TimeInterval,
        include: (Repository) -> Bool = { _ in true }
    ) -> [URL] {
        let queued = repositories
            .values
            .filter { repositoryeligibleForSmartUpdate(target: $0, age: age) }
            .filter { !currentlyInUpdate.contains($0.url) }
            .filter(include)
            .map(\.url)
        pendingUpdateRequest.formUnion(queued)
        dispatchUpdateOnCurrentCenter()
        return queued
    }

    /// send everything to update queue
    func dispatchForceUpdateRequestOnAll() {
        // asked for by the user: a host that did not answer earlier in this
        // round gets asked again
        refreshRound?.unreachableHosts.removeAll()
        repositories
            .values
            .filter { !currentlyInUpdate.contains($0.url) }
            .map(\.url)
            .forEach { pendingUpdateRequest.insert($0) }
        dispatchUpdateOnCurrentCenter()
    }

    /// send this repo to update
    /// - Parameter url: the url of repository
    func dispatchUpdateOnRepository(withUrl url: URL) {
        guard repositories[url] != nil else {
            aptLog(self, "repository \(url.absoluteString) was not found for metadata update")
            return
        }
        // asked for again while it is being fetched: that fetch is the
        // answer, unless it belongs to a deletion and is only winding down
        guard !currentlyInUpdate.contains(url) || deletedUpdates.contains(url) else { return }
        if let host = url.host {
            refreshRound?.unreachableHosts.remove(host)
        }
        pendingUpdateRequest.insert(url)
        dispatchUpdateOnCurrentCenter()
    }

    /// Registered, not refreshing right now, and empty: what
    /// `cleanBrokenRepos` removes, for a screen that wants to say so first.
    func brokenRepositoryUrls() -> [URL] {
        repositories
            .values
            .filter { $0.packageCount < 1 }
            .filter { !isRepositoryPreparedForUpdate(withUrl: $0.url) }
            .map(\.url)
    }

    /// delete repository that is not in or pending refresh and has no package available
    func cleanBrokenRepos() {
        for brokenRepo in brokenRepositoryUrls() {
            deleteRepository(withUrl: brokenRepo)
        }
    }
}

extension RepositoryCenter {
    /// The repository as the center now knows it: in memory now, and on
    /// disk once the writes before it are.
    func commit(_ repository: Repository) {
        repositories[repository.url] = repository
        write { $0.save(repository) }
    }

    /// Returns once every write asked for so far has run.
    public func writesLanded() async {
        await lastWrite?.value
    }

    /// Runs `body` off the main actor once every write asked for before it
    /// has run, then `landed` back on it. The main actor never waits on the
    /// database's lock: a refresh writing a repository's packages holds it
    /// for as long as that takes.
    func write(
        _ body: @escaping @Sendable (AptDatabase) -> Void,
        then landed: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let before = lastWrite
        let db = AptDatabase.shared
        lastWrite = Task.detached(priority: .userInitiated) {
            await before?.value
            body(db)
            if let landed {
                await landed()
            }
        }
    }
}
