//
//  RepositoryCenter+Schedule.swift
//  AptRepository
//

import Foundation

/// One refresh of the queue, from its first dispatch until nothing is
/// pending or in flight, for the line that sums it up.
struct RefreshRound {
    enum Result {
        case ok
        case degraded
        case givenUp
        case failed
    }

    let started: Date
    /// hosts that did not answer at all this round: their other
    /// repositories are not asked
    var unreachableHosts: Set<String> = []
    var results: [URL: (result: Result, duration: TimeInterval)] = [:]
    /// what the dispatch order was last logged for
    var ordered: Set<URL> = []
}

extension RepositoryCenter {
    // MARK: - SCHEDULE

    /// The update system: gives up on updates that stopped moving, then
    /// starts pending ones in the slots `UpdateSchedule` allows, each off
    /// the main actor. Runs on the one-second tick and whenever the queue
    /// moves; every line it logs is one of its decisions.
    func dispatchUpdateOnCurrentCenter() {
        let now = Date()
        // One update per repository at a time: two would share a
        // progress, the first to finish would call the repository idle,
        // and the older fetch could land its rows last. A request for
        // one in flight (deleted and added again, say) waits its turn.
        let flights = currentlyInUpdate.subtracting(givenUpUpdates).compactMap { url in
            updateStarted[url].map {
                UpdateSchedule.Flight(url: url, started: $0, lastActivity: lastActivity[url] ?? $0)
            }
        }
        let waiting = pendingUpdateRequest.subtracting(currentlyInUpdate)
        let decision = UpdateSchedule.decide(inFlight: flights, now: now, limits: updateLimits)

        for url in decision.kill {
            giveUp(url, now: now)
        }
        let active = flights.count - decision.kill.count - decision.stalled.count
        let counts = "active \(active), stalled \(decision.stalled.count), limit \(decision.limit)"
        for url in decision.stalled.subtracting(stalledUpdates).sorted(by: { $0.absoluteString < $1.absoluteString }) {
            let idle = now.timeIntervalSince(lastActivity[url] ?? now)
            aptLog(
                self,
                "update \(url.absoluteString) gives away its slot: no progress for \(Self.seconds(idle)) (\(counts))",
                level: .info
            )
        }
        stalledUpdates = decision.stalled
        if decision.heldBack, !updateLimitHeldBack, !waiting.isEmpty {
            aptLog(
                self,
                "every update in flight is stalled; limit held at \(decision.limit) (device may be offline)",
                level: .error
            )
        }
        updateLimitHeldBack = decision.heldBack
        if decision.limit != updateLimit {
            aptLog(
                self,
                "update limit \(updateLimit) -> \(decision.limit) (\(decision.stalled.count) stalled)",
                level: .verbose
            )
            updateLimit = decision.limit
        }

        // ordered only with a slot to fill: the reports are decoded for it,
        // and an import calls this once per repository it adds
        guard decision.slots > 0, !waiting.isEmpty else { return }
        let order = UpdateSchedule.order(waiting, reports: waiting.reduce(into: [:]) { reports, url in
            reports[url] = repositories[url]?.refreshReport
        })
        if refreshRound == nil {
            refreshRound = RefreshRound(started: now)
        }
        if let round = refreshRound, !waiting.isSubset(of: round.ordered) {
            refreshRound?.ordered.formUnion(waiting)
            aptLog(self, "update dispatch order: \(describeOrder(order))", level: .verbose)
        }

        // started after the loop: finishing one starts the next, and the
        // queue has to be what this decision left before that happens
        var notAttempted = [UpdateOutcome]()
        for url in order.prefix(decision.slots) {
            pendingUpdateRequest.remove(url)
            guard let request = updateRequest(for: url) else {
                aptLog(self, "the repository being dispatch to update was not found or broken", level: .error)
                notAttempted.append(UpdateOutcome(url: url))
                continue
            }
            if let host = url.host, refreshRound?.unreachableHosts.contains(host) == true {
                aptLog(
                    self,
                    "update \(url.absoluteString) not attempted: host \(host) was unreachable earlier in this refresh",
                    level: .error
                )
                // never asked, so nothing is said about it: the report of
                // its last refresh stays
                notAttempted.append(UpdateOutcome(url: url))
                continue
            }
            start(request, now: now)
        }
        // all in the queue before the first is finished, or that one would
        // find the queue empty and close the round without the rest
        currentlyInUpdate.formUnion(notAttempted.map(\.url))
        for outcome in notAttempted {
            finishUpdate(outcome)
        }
    }

    /// Puts one update in flight.
    private func start(_ request: UpdateRequest, now: Date) {
        let url = request.url
        currentlyInUpdate.insert(url)
        currentUpdateProgress[url] = Progress(totalUnitCount: 100)
        updateStarted[url] = now
        lastActivity[url] = now
        advanceUpdate(of: url)
        let db = AptDatabase.shared
        updateTasks[url] = Task.detached(priority: .utility) {
            let outcome = await Self.performUpdate(request) { units, absolute in
                await self.advanceUpdate(of: url, by: units, to: absolute)
            }
            // the heavy write, still off the main actor and still progress
            // to the watchdog; an update that read nothing leaves the rows
            // that are there
            if outcome.succeeded, let packages = outcome.packages {
                Self.beating(request.networking.activity) {
                    db.replacePackages(of: url, with: packages)
                }
            }
            await self.finishUpdate(outcome)
        }
    }

    /// Cancels an update that made no progress. Its request is cancelled
    /// with it, the packages it had stay, and it is not asked again this
    /// round: the next launch or a pull to refresh tries it again.
    private func giveUp(_ url: URL, now: Date) {
        givenUpUpdates.insert(url)
        stalledUpdates.remove(url)
        updateTasks[url]?.cancel()
        let idle = Self.seconds(now.timeIntervalSince(lastActivity[url] ?? now))
        let age = Self.seconds(now.timeIntervalSince(updateStarted[url] ?? now))
        let keeping = repositories[url].map { repo in
            repo.packageCount > 0
                ? "keeping \(repo.packageCount) packages from \(repo.lastUpdatePackage)"
                : "nothing to keep"
        } ?? "deleted meanwhile"
        aptLog(
            self,
            "update \(url.absoluteString) given up: no progress for \(idle), \(age) in total; \(keeping)",
            level: .error
        )
    }

    /// The server said something to an update: it is moving, and one that
    /// was stalled takes its slot back.
    func noteActivity(of url: URL) {
        guard currentlyInUpdate.contains(url), !givenUpUpdates.contains(url) else { return }
        let now = Date()
        if stalledUpdates.remove(url) != nil {
            let idle = now.timeIntervalSince(lastActivity[url] ?? now)
            aptLog(self, "update \(url.absoluteString) is moving again after \(Self.seconds(idle)), back in its slot", level: .info)
        }
        lastActivity[url] = now
    }

    /// Notes how a finished update went for the round's summary, and logs
    /// the summary once the queue is empty.
    func recordInRound(_ outcome: UpdateOutcome, givenUp: Bool) {
        let url = outcome.url
        if outcome.hostUnreachable, let host = url.host {
            refreshRound?.unreachableHosts.insert(host)
        }
        let result: RefreshRound.Result = if givenUp {
            .givenUp
        } else if outcome.succeeded, outcome.report?.issues.isEmpty == true {
            .ok
        } else if (repositories[url]?.packageCount ?? 0) > 0 {
            .degraded
        } else {
            .failed
        }
        refreshRound?.results[url] = (result, outcome.report?.duration ?? 0)

        guard pendingUpdateRequest.isEmpty, currentlyInUpdate.isEmpty, let round = refreshRound else { return }
        refreshRound = nil
        let results = round.results.values
        func count(_ result: RefreshRound.Result) -> Int {
            results.count { $0.result == result }
        }
        var line = "refresh round done in \(Self.seconds(Date().timeIntervalSince(round.started))): "
            + "\(count(.ok)) ok, \(count(.degraded)) degraded, \(count(.givenUp)) given up, \(count(.failed)) failed"
        if let slowest = round.results.max(by: { $0.value.duration < $1.value.duration }) {
            line += "; slowest \(slowest.key.absoluteString) \(Self.seconds(slowest.value.duration))"
        }
        aptLog(self, line, level: .info)
    }

    /// `<url> (ok, 1.2s), …, <url> (failed last time)`
    private func describeOrder(_ order: [URL]) -> String {
        order.map { url in
            guard let report = repositories[url]?.refreshReport else {
                return "\(url.absoluteString) (never refreshed)"
            }
            if report.failedToFetch {
                return "\(url.absoluteString) (failed last time)"
            }
            return "\(url.absoluteString) (\(report.issues.isEmpty ? "ok" : "degraded"), \(Self.seconds(report.duration)))"
        }.joined(separator: ", ")
    }

    nonisolated static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", interval)
    }
}
