//
//  RepositoryCenter+Internal.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/6.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Foundation

extension RepositoryCenter {
    // MARK: - UPDATE ENGINE

    /// if any part of the repo outdated then it's eligible for it
    /// - Parameters:
    ///   - target: the target repository
    ///   - age: how old a part may be
    /// - Returns: if it is eligible
    func repositoryeligibleForSmartUpdate(target: Repository, age: TimeInterval) -> Bool {
        let oldest = min(target.lastUpdateRelease, target.lastUpdatePackage)
        return Date().timeIntervalSince(oldest) > age
    }

    /// What one update needs from the repository, taken when it is dispatched
    /// so the download never reads the repositories.
    struct UpdateRequest: Sendable {
        let url: URL
        /// where the icon may be, in the order asked
        let avatarUrls: [URL]
        let releaseUrl: URL
        /// the entries in the order tried, each read as one catalogue
        /// (`Repository.packageIndexUrls`); a flat repository has one of one
        let packageCandidates: [[URL]]
        let preferredSearchPath: String
        let availableSearchPath: [String]
        /// the Release of the last refresh, to tell an older one by
        let storedRelease: [String: String]
        let networking: NetworkingConfiguration
        /// what the index paths were computed from, so a Release read by
        /// this very update can move them
        let suiteUrl: URL
        let distribution: String?
        let components: [String]
        /// the bootstrap's index directories and what installs on it
        var architectures = AptEnvironment.current.indexArchitectures
        var installable = AptEnvironment.current.installableArchitectures
        /// How long the icon, the payment endpoint and the featured banners
        /// may take in all, and how much longer than the Release and the
        /// index they are waited for. What they bring is optional; the
        /// catalogue is not held up for it.
        var optionalBudget: TimeInterval = 10
        var optionalGrace: TimeInterval = 3

        /// The index paths as the given Release describes them.
        func packageCandidates(release: [String: String]) -> [[URL]] {
            Repository.packageIndexUrls(
                suiteUrl: suiteUrl,
                distribution: distribution,
                components: components,
                release: release,
                architectures: architectures,
                installable: installable
            )
        }
    }

    /// What one update brings back; nil fields leave the repository as it was.
    struct UpdateOutcome: Sendable {
        let url: URL
        var avatar: Data?
        var release: [String: String]?
        var packages: [String: Package]?
        var searchPath: String?
        var paymentEndpoint = Detected<URL>.unanswered
        var featured = Detected<String>.unanswered
        /// what went wrong, kept with the repository; nil when nothing was
        /// attempted for want of the repository itself
        var report: RefreshReport?
        /// neither the Release nor the index got any answer: the rest of
        /// this round leaves the host alone
        var hostUnreachable = false

        var succeeded: Bool {
            (packages?.count ?? 0) > 0
        }
    }

    func updateRequest(for url: URL) -> UpdateRequest? {
        guard let repo = repositories[url] else { return nil }
        var networking = networkingConfiguration
        networking.activity = { Task { @MainActor in self.noteActivity(of: url) } }
        var request = UpdateRequest(
            url: url,
            avatarUrls: repo.avatarUrls,
            releaseUrl: repo.metaReleaseUrl,
            packageCandidates: repo.metaPackageCandidates,
            preferredSearchPath: repo.preferredSearchPath,
            availableSearchPath: repo.availableSearchPath,
            storedRelease: repo.metaRelease,
            networking: networking,
            suiteUrl: repo.suiteUrl,
            distribution: repo.distribution,
            components: repo.components
        )
        // nothing remembered to keep: a repository refreshed for the first
        // time waits the whole budget for its icon and payment endpoint
        if repo.lastUpdatePackage.timeIntervalSince1970 == 0 {
            request.optionalGrace = request.optionalBudget
        }
        return request
    }

    /// Moves the repository's progress and tells the interface.
    func advanceUpdate(of url: URL, by units: Int64 = 0, to absolute: Int64? = nil) {
        // deleted while in flight: nothing to show
        guard let progress = currentUpdateProgress[url] else { return }
        if let absolute {
            progress.completedUnitCount = absolute
        } else {
            progress.completedUnitCount += units
        }
        let object = UpdateNotification(
            repository: url,
            progress: progress,
            complete: false,
            success: false,
            queueLeft: currentlyInUpdate.count + pendingUpdateRequest.count
        )
        NotificationCenter.default.post(name: RepositoryCenter.metadataUpdate, object: object)
    }

    /// Writes what the update brought back into the repository, takes it out
    /// of the queue, tells the package center and the interface, and
    /// starts the next one at once. The packages themselves are already in
    /// the database.
    func finishUpdate(_ outcome: UpdateOutcome) {
        let url = outcome.url
        // Deleted while in flight: its rows may have landed after the delete,
        // and nothing it brought back belongs to a repository added again
        // at the same address, whose own refresh waits for this one.
        let deleted = deletedUpdates.remove(url) != nil
        if deleted, outcome.packages != nil {
            write { $0.deletePackages(of: url) } then: {
                PackageCenter.default.repositoryDidChange()
            }
        }
        if !deleted {
            apply(outcome)
        }

        let givenUp = givenUpUpdates.contains(url)
        currentlyInUpdate.remove(url)
        currentUpdateProgress.removeValue(forKey: url)
        updateTasks.removeValue(forKey: url)
        updateStarted.removeValue(forKey: url)
        lastActivity.removeValue(forKey: url)
        stalledUpdates.remove(url)
        givenUpUpdates.remove(url)
        refreshRound?.ordered.remove(url)

        if deleted {
            aptLog(self, "update \(url.absoluteString) ended after its repository was deleted")
        } else {
            recordInRound(outcome, givenUp: givenUp)
        }
        aptLog(
            self,
            "update engine reported \(pendingUpdateRequest.count) pending and \(currentlyInUpdate.count) in queue"
        )
        closeRoundIfDone()

        PackageCenter.default.repositoryDidChange()
        let object = UpdateNotification(
            repository: url,
            progress: nil,
            complete: true,
            success: !deleted && outcome.succeeded,
            queueLeft: currentlyInUpdate.count + pendingUpdateRequest.count
        )
        NotificationCenter.default.post(name: RepositoryCenter.metadataUpdate, object: object)

        // the slot is free now, not at the next tick
        dispatchUpdateOnCurrentCenter()
    }

    /// Writes what an update brought back into its repository, and logs it.
    private func apply(_ outcome: UpdateOutcome) {
        let url = outcome.url
        var printName = url.absoluteString
        var printDescription = ""
        updateRepository(withUrl: url) { builder in
            if let avatar = outcome.avatar {
                builder.avatar = avatar
            }
            if let release = outcome.release {
                builder.metaRelease = release
                builder.lastUpdateRelease = Date()
            }
            if let searchPath = outcome.searchPath {
                builder.preferredSearchPath = searchPath
            }
            if let package = outcome.packages {
                // check if any package already available
                if builder.packageCount > 0 {
                    builder.attachment[.initialInstall] = "NO"
                } else {
                    builder.attachment[.initialInstall] = "YES"
                }
                builder.packageCount = package.count
                builder.lastUpdatePackage = Date()
            }
            if let report = outcome.report {
                builder.setRefreshReport(report)
            }
            printName = builder.regenerateNickName(apply: true)
            if let description = builder.repositoryDescription {
                printDescription = description
            }
            // a refresh with no network is no reason to forget where a
            // repository takes payment
            switch outcome.paymentEndpoint {
            case let .found(paymentEndpoint):
                builder.paymentInfo[.endpoint] = paymentEndpoint.absoluteString
            case .absent:
                builder.paymentInfo.removeValue(forKey: .endpoint)
            case .unanswered:
                break
            }
            switch outcome.featured {
            case let .found(featured):
                builder.attachment[.featured] = featured
            case .absent:
                builder.attachment.removeValue(forKey: .featured)
            case .unanswered:
                break
            }
        }

        let issues = outcome.report?.issues ?? []
        let finalLog = """
        \(outcome.succeeded ? "Complete" : "Failed") update on \(url.absoluteString)
        ===>
            Repository [\(printName)] \(printDescription)
            * Release: \(outcome.release?.keys.count ?? 0)
            * Package: \(outcome.packages?.keys.count ?? 0)
            * Issues: \(issues.isEmpty ? "none" : issues.map { "\($0)" }.joined(separator: ", "))
        ===>
        """
        // A refresh that fetched nothing used to read exactly like one that
        // worked, save for a `* Package: 0` line in the middle of the block.
        aptLog(self, finalLog, level: outcome.succeeded ? .info : .error)
    }

    /// Every index of one entry under one suffix, fetched at once, each
    /// with what asking for it came to, by the address asked.
    nonisolated static func downloadPackageIndexes(
        _ bases: [URL],
        suffix: String,
        networking: NetworkingConfiguration
    ) async -> [URL: Download] {
        await withTaskGroup(of: (URL, Download).self, returning: [URL: Download].self) { group in
            for base in bases {
                let url = base.appendingPathExtension(suffix)
                group.addTask {
                    await (url, download(fromUrl: url, networking: networking))
                }
            }
            var downloads = [URL: Download]()
            for await (url, download) in group {
                downloads[url] = download
            }
            return downloads
        }
    }

    /// The indexes that arrived, as served; the rest are left out.
    nonisolated static func fetchedIndexes(_ downloads: [URL: Download]) -> [FetchedIndex] {
        downloads.compactMap { url, download in
            download.data.map { FetchedIndex(url: url, data: $0) }
        }
    }

    /// An entry's indexes read as one, in the entry's order, or
    /// nil when there is nothing to read or the suffix cannot be taken
    /// whole: one index is not the file the Release lists, or one the
    /// Release lists did not arrive or cannot be read. Another spelling then
    /// gets its turn, rather than a catalogue short of a component or half
    /// from an older publish. A component the Release does not list is one
    /// the repository may never have had, and is left out as before.
    /// - Parameter digests: from the Release this very update fetched, nil
    ///   when it fetched none. Never a stored one, which every index would
    ///   differ from the day the repository publishes.
    nonisolated static func readPackageIndexes(
        _ indexes: [FetchedIndex],
        of bases: [URL],
        suffix: String,
        digests: IndexDigests?
    ) -> String? {
        var parts = [String]()
        for base in bases {
            let url = base.appendingPathExtension(suffix)
            let index = indexes.first { $0.url == url }
            if let index, digests?.verdict(of: index.data, at: url) == .differs {
                aptLog(
                    Self.self,
                    "\(url.absoluteString) is not the file its Release lists, so it is not read",
                    level: .error
                )
                return nil
            }
            if let index, let part = decodeUpdatePackage(index, suffix: suffix) {
                parts.append(part)
            } else if digests?.lists(url) == true {
                aptLog(Self.self, "\(url.absoluteString) is in the Release and could not be had", level: .error)
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Runs `work`, calling `activity` once a second until it returns: a
    /// long decompress, parse or database write is progress too, and the
    /// refresh queue hears only what it is told. The beat comes from a
    /// dispatch timer, not a task: `work` holds a thread of the
    /// cooperative pool, and with several such at once a task would wait
    /// for a thread until the work was done.
    nonisolated static func beating<T>(_ activity: @escaping @Sendable () -> Void, _ work: () throws -> T) rethrows -> T {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler(handler: activity)
        timer.resume()
        defer { timer.cancel() }
        return try work()
    }

    /// An entry's indexes read and compiled into packages, nil when that
    /// comes to nothing (a captive portal's page under HTTP 200 is no
    /// catalogue), with the refresh queue told it is still moving.
    nonisolated static func compilePackageIndexes(
        _ indexes: [FetchedIndex],
        of bases: [URL],
        suffix: String,
        digests: IndexDigests?,
        fromRepo: URL,
        networking: NetworkingConfiguration
    ) -> [String: Package]? {
        beating(networking.activity) {
            guard let body = readPackageIndexes(indexes, of: bases, suffix: suffix, digests: digests) else { return nil }
            let packages = invokePackages(withContext: body, fromRepo: fromRepo)
            return packages.isEmpty ? nil : packages
        }
    }

    /// The spellings among `searchPaths` the Release lists for any of
    /// `bases`, in the order given; none without a Release or its digests.
    nonisolated static func listedSearchPaths(
        _ searchPaths: [String],
        of bases: [URL],
        digests: IndexDigests?
    ) -> [String] {
        guard let digests, digests.listsAnything else { return [] }
        return searchPaths.filter { suffix in
            bases.contains { digests.lists($0.appendingPathExtension(suffix)) }
        }
    }

    /// Every suffix of one entry's indexes at once: the first that
    /// is what the Release lists and compiles to a non-empty index, or nil
    /// when none does.
    private nonisolated static func probeSearchPaths(
        _ searchPaths: [String],
        of baseUrls: [URL],
        fromRepo: URL,
        digests: IndexDigests?,
        networking: NetworkingConfiguration
    ) async -> SearchPathProbe? {
        await withTaskGroup(
            of: SearchPathProbe?.self,
            returning: SearchPathProbe?.self
        ) { group in
            for searchPath in searchPaths {
                group.addTask {
                    let indexes = await fetchedIndexes(downloadPackageIndexes(
                        baseUrls,
                        suffix: searchPath,
                        networking: networking
                    ))
                    guard let packages = compilePackageIndexes(
                        indexes,
                        of: baseUrls,
                        suffix: searchPath,
                        digests: digests,
                        fromRepo: fromRepo,
                        networking: networking
                    )
                    else { return nil }
                    return SearchPathProbe(suffix: searchPath, packages: packages, read: indexes.map(\.url))
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// The icon from the first address in `urls` that has one, all asked at
    /// once: a later address that answers first waits only for the earlier
    /// ones to say they have none, so which icon wins never depends on
    /// which server was quicker.
    nonisolated static func downloadAvatar(
        from urls: [URL],
        networking: NetworkingConfiguration
    ) async -> Data? {
        await withTaskGroup(of: (Int, Data?).self, returning: Data?.self) { group in
            for (position, url) in urls.enumerated() {
                group.addTask { await (position, downloadData(fromUrl: url, networking: networking)) }
            }
            var answers = [Int: Data?]()
            for await (position, data) in group {
                answers[position] = data
                // the earliest address not yet known to have none
                for earlier in urls.indices {
                    guard let answer = answers[earlier] else { break }
                    if let answer {
                        group.cancelAll()
                        return answer
                    }
                }
            }
            return nil
        }
    }

    /// What a repository offers besides its catalogue.
    struct OptionalParts: Sendable {
        var avatar: Data?
        var paymentEndpoint = Detected<URL>.unanswered
        var featured = Detected<String>.unanswered
    }

    /// The icon, the payment endpoint and the featured banners, each given
    /// up once `request.optionalBudget` has passed or `cutoff` says the
    /// catalogue's own files are in and its grace has run out; what was not
    /// in by then is `unanswered`, and what the repository had stays.
    /// - Parameter cutoff: yields once, the grace to allow from then on
    nonisolated static func fetchOptionalParts(
        _ request: UpdateRequest,
        cutoff: AsyncStream<TimeInterval>,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async -> OptionalParts {
        enum Part: Sendable {
            case avatar(Data?)
            case paymentEndpoint(Detected<URL>)
            case featured(Detected<String>)
            case cutoff
        }
        let networking = request.networking
        let started = Date()
        return await withTaskGroup(of: Part.self, returning: OptionalParts.self) { group in
            group.addTask {
                let value = await downloadAvatar(from: request.avatarUrls, networking: networking)
                await progress(10, nil)
                return .avatar(value)
            }
            group.addTask {
                let value = await detectPaymentEndpoint(withUrl: request.url, networking: networking)
                await progress(10, nil)
                return .paymentEndpoint(value)
            }
            group.addTask {
                let value = await detectFeaturedMetadata(withUrl: request.url, networking: networking)
                await progress(10, nil)
                return .featured(value)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(request.optionalBudget))
                return .cutoff
            }
            group.addTask {
                for await grace in cutoff {
                    try? await Task.sleep(for: .seconds(grace))
                    return .cutoff
                }
                // the catalogue's files never came: the budget decides
                try? await Task.sleep(for: .seconds(request.optionalBudget))
                return .cutoff
            }
            var parts = OptionalParts()
            var waiting: Set = ["avatar", "payment_endpoint", "sileo-featured"]
            for await part in group {
                switch part {
                case let .avatar(value):
                    parts.avatar = value
                    waiting.remove("avatar")
                case let .paymentEndpoint(value):
                    parts.paymentEndpoint = value
                    waiting.remove("payment_endpoint")
                case let .featured(value):
                    parts.featured = value
                    waiting.remove("sileo-featured")
                case .cutoff:
                    let waited = String(format: "%.1f", Date().timeIntervalSince(started))
                    aptLog(
                        Self.self,
                        "update \(request.url.absoluteString) gave up waiting for \(waiting.sorted().joined(separator: ", ")) after \(waited)s; keeping the old ones",
                        level: .verbose
                    )
                    waiting.removeAll()
                }
                if waiting.isEmpty {
                    group.cancelAll()
                    break
                }
            }
            return parts
        }
    }

    /// Downloads and compiles one repository. Off the main actor throughout;
    /// `progress` and `networking.activity` are the only ways back in until
    /// the outcome is committed. Cancelled, it stops asking and says the
    /// server stalled.
    /// - Parameters:
    ///   - request: what to fetch and how
    ///   - progress: units to add, or an absolute value, out of 100
    /// - Returns: what was fetched
    nonisolated static func performUpdate(
        _ request: UpdateRequest,
        progress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async -> UpdateOutcome {
        let id = request.url.absoluteString
        let networking = request.networking
        var outcome = UpdateOutcome(url: request.url)
        var issues = [RefreshReport.Issue]()

        // measuring
        let updateStart = Date()

        // MARK: - STAGE 1

        // STAGE 1 [try preferred search path]
        //
        // The Release and the preferred index, with the optional parts
        // beside them on a budget of their own. Each request carries
        // `networkingTimeout`; the refresh queue's watchdog gives up on the
        // whole update sooner when nothing arrives at all.
        aptLog(Self.self, "update \(id) enter stage 1", level: .verbose)

        let (catalogueArrived, announceCatalogue) = AsyncStream<TimeInterval>.makeStream()
        async let optionalTask = fetchOptionalParts(request, cutoff: catalogueArrived, progress: progress)
        async let releaseTask: Download = {
            let value = await download(fromUrl: request.releaseUrl, networking: networking)
            await progress(10, nil)
            return value
        }()
        async let packageTask: [URL: Download] = {
            let value = await downloadPackageIndexes(
                request.packageCandidates.first ?? [],
                suffix: request.preferredSearchPath,
                networking: networking
            )
            await progress(10, nil)
            return value
        }()

        let releaseDownload = await releaseTask
        let preferredDownloads = await packageTask
        // Neither the Release nor the index had any answer: the host is
        // down, or the path to it is. Every other spelling in stage 3 would
        // wait out the same silence, once per entry.
        let noAnswer = !releaseDownload.reachedServer && !preferredDownloads.values.contains { $0.reachedServer }
        announceCatalogue.yield(noAnswer ? 0 : request.optionalGrace)
        announceCatalogue.finish()
        networking.activity()

        // MARK: - STAGE 2

        // STAGE 2 [compile data]
        aptLog(Self.self, "update \(id) enter stage 2", level: .verbose)
        let compileStart = Date()
        switch releaseDownload {
        case let .data(data):
            // a Release is read leniently: its name and architectures are
            // worth having even when its digests are not
            if let reading = ReleaseFile.read(IndexText.decode(data)) {
                outcome.release = reading.fields
                if reading.digestsDuplicated {
                    aptLog(Self.self, "update \(id) has a Release that lists its digests twice; none is used", level: .error)
                    issues.append(.releaseMalformed)
                }
            } else {
                aptLog(Self.self, "update \(id) has a Release that cannot be read", level: .error)
                issues.append(.releaseMalformed)
            }
        case .absent:
            issues.append(.releaseMissing)
        case let .serverError(code):
            issues.append(.serverError(code))
        case .unreachable, .stalled:
            // not the Release's fault: with the index in, a hiccup that
            // leaves the Release kept as it was; without, the verdict on
            // the whole update below says what the connection did
            break
        }
        // A CDN can as well have the old Release beside new indexes. Held
        // to that one every index would differ and the refresh fail, so a
        // Release written before the one already read is not read at all.
        if let release = outcome.release,
           let written = IndexDigests.date(of: release),
           let known = IndexDigests.date(of: request.storedRelease),
           written < known
        {
            aptLog(Self.self, "update \(id) was served a Release older than the one it has", level: .error)
            outcome.release = nil
            issues.append(.releaseOutdated)
        }
        // The index came down beside the Release, not after it, so it is
        // held to the Release here. One that differs is dropped, and stage
        // 3 asks for every spelling: a CDN that still has yesterday's
        // `Packages.xz` has usually let go of yesterday's `Packages`.
        let digests = outcome.release.map { IndexDigests(release: $0, releaseUrl: request.releaseUrl) }
        let preferredIndexes = fetchedIndexes(preferredDownloads)
        let preferredIsStale = preferredIndexes.contains {
            digests?.verdict(of: $0.data, at: $0.url) == .differs
        }
        // A Release that lists other spellings of the entry than the
        // preferred one vouches for those and not for it: stage 3 reads one
        // it lists, and that one is remembered.
        let listed = listedSearchPaths(request.availableSearchPath, of: request.packageCandidates.first ?? [], digests: digests)
        let preferredIsUnlisted = !listed.isEmpty && !listed.contains(request.preferredSearchPath)
        // the index files the catalogue was read from, to ask the Release
        // whether it vouches for them
        var readFrom = [URL]()
        if !preferredIsUnlisted, let packages = compilePackageIndexes(
            preferredIndexes,
            of: request.packageCandidates.first ?? [],
            suffix: request.preferredSearchPath,
            digests: digests,
            fromRepo: request.url,
            networking: networking
        ) {
            outcome.packages = packages
            readFrom = preferredIndexes.map(\.url)
        }
        do {
            let compileInterval = Date().timeIntervalSince(compileStart)
            let put = String(format: "%.2f", compileInterval)
            aptLog(Self.self, "\(id) complete compiler invoke in \(put) second", level: .info)
        }

        await progress(20, nil)
        networking.activity()

        // MARK: - STAGE 3

        // STAGE 3 [try every entry and search path if needed]
        //
        // One entry at a time, in order: what installs here first, then the
        // other bootstraps' indexes one by one. Within one, knock on
        // every compression suffix and keep the first that compiles to a
        // non-empty index; cancelling the group stops the rest. Only worth
        // it when the server answered and the file name or its compression
        // was wrong.
        aptLog(Self.self, "update \(id) enter stage 3", level: .verbose)

        if outcome.packages?.count ?? 0 < 1 {
            if noAnswer, !Task.isCancelled {
                let index = preferredDownloads.values.first?.summary ?? "none"
                aptLog(
                    Self.self,
                    "update \(id) skips probing: Release \(releaseDownload.summary), index \(index)",
                    level: .error
                )
            } else if !Task.isCancelled {
                // a Release fetched just now may name other index directories
                // than the stored one did (or an empty one, on a repository
                // added a moment ago): the probes read the fresh one
                let candidates = outcome.release.map { request.packageCandidates(release: $0) }
                    ?? request.packageCandidates
                for baseUrls in candidates {
                    if Task.isCancelled {
                        break
                    }
                    // the spellings the Release lists first, so what is read
                    // is what it vouches for whenever the server has it
                    let listed = listedSearchPaths(request.availableSearchPath, of: baseUrls, digests: digests)
                    var winner: SearchPathProbe?
                    for searchPaths in [listed, request.availableSearchPath.filter { !listed.contains($0) }]
                        where winner == nil && !searchPaths.isEmpty && !Task.isCancelled
                    {
                        winner = await probeSearchPaths(
                            searchPaths,
                            of: baseUrls,
                            fromRepo: request.url,
                            digests: digests,
                            networking: networking
                        )
                    }
                    networking.activity()
                    guard let winner else { continue }
                    if baseUrls != request.packageCandidates.first {
                        aptLog(Self.self, "update \(id) moves to \(baseUrls.map(\.absoluteString))", level: .info)
                    }
                    outcome.packages = winner.packages
                    readFrom = winner.read
                    // a spelling that stood in for a stale one is not the one
                    // to remember: the preferred is back with the CDN's next
                    // fetch, and the stand-in may be the uncompressed index
                    if !(preferredIsStale && baseUrls == request.packageCandidates.first) {
                        outcome.searchPath = winner.suffix
                    }
                    break
                }
            }
        } else {
            outcome.searchPath = request.preferredSearchPath
        }

        if !outcome.succeeded {
            if Task.isCancelled {
                // given up by the refresh queue for making no progress
                issues = [.stalled]
            } else if noAnswer {
                let downloads = [releaseDownload] + preferredDownloads.values
                issues = [downloads.contains(where: \.isStalled) ? .stalled : .unreachable]
                // a device with no network says nothing about the host
                outcome.hostUnreachable = issues == [.unreachable] && !downloads.contains(where: \.deviceOffline)
            } else if !issues.contains(where: {
                if case .serverError = $0 {
                    true
                } else {
                    false
                }
            }) {
                // the server answered something; what became of the index
                // is what the report says: its own error, the connection
                // dropping on it, or that there is none for this device
                let unanswered = preferredDownloads.values.first { !$0.reachedServer }
                let serverError = preferredDownloads.values.lazy.compactMap { download -> Int? in
                    if case let .serverError(code) = download {
                        code
                    } else {
                        nil
                    }
                }.first
                if let serverError {
                    issues.append(.serverError(serverError))
                } else if let unanswered {
                    issues.append(unanswered.isStalled ? .stalled : .unreachable)
                } else {
                    issues.append(.noIndex)
                }
            }
        } else if let digests, digests.listsAnything, readFrom.contains(where: { !digests.lists($0) }) {
            aptLog(Self.self, "update \(id) read an index its Release does not list", level: .error)
            issues.append(.indexUnverified)
        }

        let optional = await optionalTask
        outcome.avatar = optional.avatar
        outcome.paymentEndpoint = optional.paymentEndpoint
        outcome.featured = optional.featured

        await progress(0, 90)

        let completeInterval = Date().timeIntervalSince(updateStart)
        var unique = [RefreshReport.Issue]()
        for issue in issues where !unique.contains(issue) {
            unique.append(issue)
        }
        outcome.report = RefreshReport(date: Date(), duration: completeInterval, issues: unique)
        aptLog(Self.self, String(format: "update \(id) fetched in %.2f seconds", completeInterval), level: .info)
        return outcome
    }

    // MARK: - Notification Emitter

    func issueNotification() {
        notificationThrottle.throttle {
            NotificationCenter.default.post(name: RepositoryCenter.registrationUpdate, object: nil)
        }
    }
}

/// One search-path suffix that produced a usable package index.
private struct SearchPathProbe: Sendable {
    let suffix: String
    let packages: [String: Package]
    /// the index files it was read from
    let read: [URL]
}
