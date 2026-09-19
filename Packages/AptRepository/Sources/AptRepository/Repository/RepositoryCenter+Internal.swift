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
    /// - Parameter target: the target repository
    /// - Returns: if it is eligible
    func repositoryeligibleForSmartUpdate(target: Repository) -> Bool {
        let oldest = min(target.lastUpdateRelease, target.lastUpdatePackage)
        return Date().timeIntervalSince(oldest) > Double(smartUpdateTimeInterval)
    }

    /// What one update needs from the repository, taken when it is dispatched
    /// so the download never reads the repositories.
    struct UpdateRequest: Sendable {
        let url: URL
        /// where the icon may be, in the order asked
        let avatarUrls: [URL]
        let releaseUrl: URL
        /// one entry per architecture in the order tried, each with one
        /// index per component; a flat repository has one of one
        let packageCandidates: [[URL]]
        let preferredSearchPath: String
        let availableSearchPath: [String]
        let networking: NetworkingConfiguration
        /// what the index paths were computed from, so a Release read by
        /// this very update can move them
        let suiteUrl: URL
        let distribution: String?
        let components: [String]

        /// The index paths as the given Release describes them.
        func packageCandidates(release: [String: String]) -> [[URL]] {
            Repository.packageIndexUrls(
                suiteUrl: suiteUrl,
                distribution: distribution,
                components: components,
                release: release,
                architectures: AptEnvironment.current.indexArchitectures
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
        var paymentEndpoint: URL?
        var featured: String?

        var succeeded: Bool {
            (packages?.count ?? 0) > 0
        }
    }

    private func updateRequest(for url: URL) -> UpdateRequest? {
        guard let repo = repositories[url] else { return nil }
        return UpdateRequest(
            url: url,
            avatarUrls: repo.avatarUrls,
            releaseUrl: repo.metaReleaseUrl,
            packageCandidates: repo.metaPackageCandidates,
            preferredSearchPath: repo.preferredSearchPath,
            availableSearchPath: repo.availableSearchPath,
            networking: networkingConfiguration,
            suiteUrl: repo.suiteUrl,
            distribution: repo.distribution,
            components: repo.components
        )
    }

    /// The update system: moves what fits under the concurrency limit from
    /// pending to in-flight and starts each download off the main actor.
    func dispatchUpdateOnCurrentCenter() {
        updateDispatchThrottle.throttle { [self] in
            var dispatchContainer = [URL]()
            while pendingUpdateRequest.count > 0,
                  dispatchContainer.count + currentlyInUpdate.count < updateConcurrencyLimit
            {
                dispatchContainer.append(pendingUpdateRequest.removeFirst())
            }

            for url in dispatchContainer {
                currentlyInUpdate.insert(url)
                currentUpdateProgress[url] = Progress(totalUnitCount: 100)
                guard let request = updateRequest(for: url) else {
                    aptLog(self, "the repository being dispatch to update was not found or broken", level: .error)
                    finishUpdate(UpdateOutcome(url: url))
                    continue
                }
                advanceUpdate(of: url)
                let db = AptDatabase.shared
                Task.detached(priority: .utility) {
                    let outcome = await Self.performUpdate(request) { units, absolute in
                        await self.advanceUpdate(of: url, by: units, to: absolute)
                    }
                    // the heavy write, still off the main actor
                    if let packages = outcome.packages {
                        db.replacePackages(of: url, with: packages)
                    }
                    await self.finishUpdate(outcome)
                }
            }
        }
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
            representedRepo: url,
            progress: progress,
            complete: false,
            success: false,
            queueLeft: currentlyInUpdate.count + pendingUpdateRequest.count
        )
        NotificationCenter.default.post(name: RepositoryCenter.metadataUpdate, object: object)
    }

    /// Writes what the update brought back into the repository, takes it out
    /// of the queue and tells the package center and the interface. The
    /// packages themselves are already in the database.
    func finishUpdate(_ outcome: UpdateOutcome) {
        let url = outcome.url
        var printName = url.absoluteString
        var printDescription = ""
        if repositories[url] == nil, outcome.packages != nil {
            // deleted while in flight: its rows landed after the delete
            AptDatabase.shared.deletePackages(of: url)
        }
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
            printName = builder.regenerateNickName(apply: true)
            if let description = builder.repositoryDescription {
                printDescription = description
            }
            if let paymentEndpoint = outcome.paymentEndpoint {
                builder.paymentInfo[.endpoint] = paymentEndpoint.absoluteString
            } else {
                builder.paymentInfo.removeValue(forKey: .endpoint)
            }
            if let featured = outcome.featured {
                builder.attachment[.featured] = featured
            } else {
                builder.attachment.removeValue(forKey: .featured)
            }
        }

        currentlyInUpdate.remove(url)
        currentUpdateProgress.removeValue(forKey: url)

        let finalLog = """
        \(outcome.succeeded ? "Complete" : "Failed") update on \(url.absoluteString)
        ===>
            Repository [\(printName)] \(printDescription)
            * Release: \(outcome.release?.keys.count ?? 0)
            * Package: \(outcome.packages?.keys.count ?? 0)
        ===>
        """
        // A refresh that fetched nothing used to read exactly like one that
        // worked, save for a `* Package: 0` line in the middle of the block.
        aptLog(self, finalLog, level: outcome.succeeded ? .info : .error)
        aptLog(
            self,
            "update engine reported \(pendingUpdateRequest.count) pending and \(currentlyInUpdate.count) in queue"
        )

        PackageCenter.default.repositoryDidChange()
        let object = UpdateNotification(
            representedRepo: url,
            progress: nil,
            complete: true,
            success: outcome.succeeded,
            queueLeft: currentlyInUpdate.count + pendingUpdateRequest.count
        )
        NotificationCenter.default.post(name: RepositoryCenter.metadataUpdate, object: object)
    }

    /// Every component's Packages index under one suffix, fetched at once
    /// and read as one: a component that does not answer is left out, and
    /// nil means none did.
    nonisolated static func downloadPackageIndexes(
        _ bases: [URL],
        suffix: String,
        networking: NetworkingConfiguration
    ) async -> String? {
        let parts = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for base in bases {
                group.addTask {
                    await downloadUpdatePackage(withBaseUrl: base, suffix: suffix, networking: networking)
                }
            }
            var parts = [String]()
            for await part in group {
                if let part {
                    parts.append(part)
                }
            }
            return parts
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Every suffix of one architecture's indexes at once: the first that
    /// compiles to a non-empty index, or nil when none does.
    private nonisolated static func probeSearchPaths(
        _ searchPaths: [String],
        of baseUrls: [URL],
        fromRepo: URL,
        networking: NetworkingConfiguration
    ) async -> SearchPathProbe? {
        await withTaskGroup(
            of: SearchPathProbe?.self,
            returning: SearchPathProbe?.self
        ) { group in
            for searchPath in searchPaths {
                group.addTask {
                    guard let body = await downloadPackageIndexes(
                        baseUrls,
                        suffix: searchPath,
                        networking: networking
                    )
                    else { return nil }
                    let packages = invokePackages(withContext: body, fromRepo: fromRepo)
                    guard packages.count > 0 else { return nil }
                    return SearchPathProbe(suffix: searchPath, packages: packages)
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

    /// The icon from the first address that has one.
    nonisolated static func downloadAvatar(
        from urls: [URL],
        networking: NetworkingConfiguration
    ) async -> Data? {
        for url in urls {
            if let data = await downloadData(fromUrl: url, networking: networking) {
                return data
            }
        }
        return nil
    }

    /// Downloads and compiles one repository. Off the main actor throughout;
    /// `progress` is the only way back in until the outcome is committed.
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

        // measuring
        let updateStart = Date()

        // MARK: - STAGE 1

        // STAGE 1 [try preferred search path]
        //
        // Five requests at once. Each carries `networkingTimeout` on its own
        // URLRequest, which is what actually bounds this stage.
        aptLog(Self.self, "update \(id) enter stage 1", level: .verbose)

        async let avatarTask: Data? = {
            let value = await downloadAvatar(from: request.avatarUrls, networking: networking)
            await progress(10, nil)
            return value
        }()
        async let releaseTask: String? = {
            let value = await downloadUpdateRelease(withUrl: request.releaseUrl, networking: networking)
            await progress(10, nil)
            return value
        }()
        async let packageTask: String? = {
            let value = await downloadPackageIndexes(
                request.packageCandidates.first ?? [],
                suffix: request.preferredSearchPath,
                networking: networking
            )
            await progress(10, nil)
            return value
        }()
        async let paymentTask: URL? = {
            let value = await detectPaymentEndpoint(withUrl: request.url, networking: networking)
            await progress(10, nil)
            return value.flatMap { URL(string: $0) }
        }()
        async let featuredTask: String? = {
            let value = await detectFeaturedMetadata(withUrl: request.url, networking: networking)
            await progress(10, nil)
            return value
        }()

        outcome.avatar = await avatarTask
        let releaseStr = await releaseTask
        let packageStr = await packageTask
        outcome.paymentEndpoint = await paymentTask
        outcome.featured = await featuredTask

        // MARK: - STAGE 2

        // STAGE 2 [compile data]
        aptLog(Self.self, "update \(id) enter stage 2", level: .verbose)
        let compileStart = Date()
        if let release = releaseStr {
            outcome.release = try? DebianControl.parse(release)
        }
        if let package = packageStr {
            outcome.packages = invokePackages(withContext: package, fromRepo: request.url)
        }
        do {
            let compileInterval = Date().timeIntervalSince(compileStart)
            let put = String(format: "%.2f", compileInterval)
            aptLog(Self.self, "\(id) complete compiler invoke in \(put) second", level: .info)
        }

        await progress(20, nil)

        // MARK: - STAGE 3

        // STAGE 3 [try every architecture and search path if needed]
        //
        // One architecture at a time, in order, so the device's own index
        // wins over a fallback wherever both exist. Within one, knock on
        // every compression suffix and keep the first that compiles to a
        // non-empty index; cancelling the group stops the rest.
        aptLog(Self.self, "update \(id) enter stage 3", level: .verbose)

        if outcome.packages?.count ?? 0 < 1 {
            // a Release fetched just now may name other index directories
            // than the stored one did (or an empty one, on a repository
            // added a moment ago): the probes read the fresh one
            let candidates = outcome.release.map { request.packageCandidates(release: $0) }
                ?? request.packageCandidates
            for baseUrls in candidates {
                guard let winner = await probeSearchPaths(
                    request.availableSearchPath,
                    of: baseUrls,
                    fromRepo: request.url,
                    networking: networking
                ) else { continue }
                if baseUrls != request.packageCandidates.first {
                    aptLog(Self.self, "update \(id) moves to \(baseUrls.map(\.absoluteString))", level: .info)
                }
                outcome.packages = winner.packages
                outcome.searchPath = winner.suffix
                break
            }
        } else {
            outcome.searchPath = request.preferredSearchPath
        }

        await progress(0, 90)

        let completeInterval = Date().timeIntervalSince(updateStart)
        aptLog(Self.self, String(format: "update \(id) fetched in %.2f seconds", completeInterval), level: .info)
        return outcome
    }

    // MARK: - Notification Emitter

    func issueNotification() {
        notificationThrotte.throttle {
            NotificationCenter.default.post(name: RepositoryCenter.registrationUpdate, object: nil)
        }
    }
}

/// One search-path suffix that produced a usable package index.
private struct SearchPathProbe: Sendable {
    let suffix: String
    let packages: [String: Package]
}
