import Foundation

/// The refresh queue's decisions as a pure function of the clock: which
/// updates in flight are stalled, which are given up, and how many pending
/// ones go next (`order` says which). `RepositoryCenter` feeds it its state
/// once a second and whenever the queue moves, and carries out what comes
/// back.
///
/// A source is judged by progress, not by how long it takes: Procursus
/// downloading megabytes steadily is fine however long it runs, a server
/// that accepted the connection and went quiet is not. The bottleneck is
/// latency, not bandwidth, so a stalled update gives its slot away and the
/// next source starts while it waits.
enum UpdateSchedule {
    struct Limits: Sendable {
        /// no progress for this long: stalled, and out of its slot
        var stall: TimeInterval = 8
        /// no progress for this long: given up
        var kill: TimeInterval = 25
        /// a stalled update older than this is given up whatever its idle
        /// time; one that is receiving is never cut for its age
        var total: TimeInterval = 90
        /// updates in flight at once while none is stalled
        var base = 4
        /// the most in flight, stalled ones included
        var hardMax = 12
    }

    /// One update in flight: when it started and when it last moved.
    struct Flight: Sendable, Equatable {
        let url: URL
        let started: Date
        let lastActivity: Date
    }

    struct Decision: Sendable, Equatable {
        /// to cancel now; their cached packages stay
        var kill: [URL] = []
        /// in flight, not given up, and not in a slot
        var stalled: Set<URL> = []
        /// how many may be in flight after this decision
        var limit: Int
        /// every update in flight is stalled: likely the device is offline,
        /// so the limit stays at `base`
        var heldBack = false
        /// how many pending updates may start now
        var slots = 0
    }

    /// - Parameter inFlight: updates running, less any already given up
    static func decide(
        inFlight: [Flight],
        now: Date,
        limits: Limits = Limits()
    ) -> Decision {
        var decision = Decision(limit: limits.base)
        var remaining = [Flight]()
        for flight in inFlight {
            let idle = now.timeIntervalSince(flight.lastActivity)
            let age = now.timeIntervalSince(flight.started)
            if idle >= limits.kill || (idle >= limits.stall && age >= limits.total) {
                decision.kill.append(flight.url)
            } else {
                remaining.append(flight)
                if idle >= limits.stall {
                    decision.stalled.insert(flight.url)
                }
            }
        }
        if !remaining.isEmpty, decision.stalled.count == remaining.count {
            decision.heldBack = true
            decision.limit = limits.base
        } else {
            decision.limit = min(limits.base + decision.stalled.count, limits.hardMax)
        }
        decision.slots = max(0, decision.limit - remaining.count)
        return decision
    }

    /// Pending updates in the order to start them: sources that were
    /// healthy last time, fastest first, then those never refreshed, then
    /// those that failed or were given up, slowest last. Most of the list is
    /// done early, and the dead sources take their time at the end.
    static func order(_ pending: some Sequence<URL>, reports: [URL: RefreshReport]) -> [URL] {
        func rank(_ url: URL) -> (Int, TimeInterval) {
            guard let report = reports[url] else { return (1, 0) }
            return (report.failedToFetch ? 2 : 0, report.duration)
        }
        return pending.sorted { lhs, rhs in
            let (left, right) = (rank(lhs), rank(rhs))
            if left != right {
                return left < right
            }
            return lhs.absoluteString < rhs.absoluteString
        }
    }
}
