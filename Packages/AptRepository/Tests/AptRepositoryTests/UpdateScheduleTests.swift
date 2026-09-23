@testable import AptRepository
import Foundation
import Testing

/// The refresh queue's decisions on a clock of the test's own.
struct UpdateScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func url(_ name: String) -> URL {
        URL(string: "https://\(name).test")!
    }

    /// in flight for `age` seconds, last heard from `idle` seconds ago
    private func flight(_ name: String, age: TimeInterval = 10, idle: TimeInterval = 0) -> UpdateSchedule.Flight {
        .init(url: url(name), started: now - age, lastActivity: now - idle)
    }

    @Test func freeSlotsFillInOrder() {
        let decision = UpdateSchedule.decide(inFlight: [flight("a")], now: now)
        #expect(decision.limit == 4)
        #expect(decision.slots == 3)
        #expect(decision.kill.isEmpty)
    }

    @Test func stalledUpdateGivesAwayItsSlot() {
        let inFlight = [flight("a"), flight("b"), flight("c"), flight("d", idle: 9)]
        let decision = UpdateSchedule.decide(inFlight: inFlight, now: now)
        #expect(decision.stalled == [url("d")])
        #expect(decision.limit == 5)
        #expect(decision.slots == 1)
        #expect(decision.kill.isEmpty)
    }

    /// Given up, and out of the count at once; what it had is the center's
    /// to keep, since nothing here touches the catalogue.
    @Test func silentUpdateIsGivenUp() {
        let inFlight = [flight("a"), flight("b"), flight("c"), flight("d", idle: 25)]
        let decision = UpdateSchedule.decide(inFlight: inFlight, now: now)
        #expect(decision.kill == [url("d")])
        #expect(decision.stalled.isEmpty)
        #expect(decision.slots == 1)
    }

    @Test func ageAloneNeverStopsADownloadThatIsMoving() {
        let moving = UpdateSchedule.decide(inFlight: [flight("a", age: 300, idle: 2)], now: now)
        #expect(moving.kill.isEmpty)
        let stalled = UpdateSchedule.decide(inFlight: [flight("a", age: 95, idle: 9)], now: now)
        #expect(stalled.kill == [url("a")])
        let young = UpdateSchedule.decide(inFlight: [flight("a", age: 30, idle: 9)], now: now)
        #expect(young.kill.isEmpty)
        #expect(young.stalled == [url("a")])
    }

    /// Everything stalled at once is the device, not the servers: no more
    /// sources are started into the silence.
    @Test func everythingStalledHoldsTheLimit() {
        let inFlight = (0 ..< 4).map { flight("s\($0)", idle: 10) }
        let decision = UpdateSchedule.decide(inFlight: inFlight, now: now)
        #expect(decision.heldBack)
        #expect(decision.limit == 4)
        #expect(decision.slots == 0)
    }

    @Test func limitStopsAtTheHardMaximum() {
        let inFlight = (0 ..< 10).map { flight("s\($0)", idle: 10) } + [flight("a"), flight("b")]
        let decision = UpdateSchedule.decide(inFlight: inFlight, now: now)
        #expect(!decision.heldBack)
        #expect(decision.limit == 12)
        #expect(decision.slots == 0)
    }

    @Test func healthyAndFastGoFirstAndFailuresLast() {
        let report = { (duration: TimeInterval, issues: [RefreshReport.Issue]) in
            RefreshReport(date: now, duration: duration, issues: issues)
        }
        let reports: [URL: RefreshReport] = [
            url("slow"): report(9, []),
            url("fast"): report(1, []),
            url("malformed"): report(2, [.releaseMalformed]),
            url("dead"): report(25, [.unreachable]),
            url("broken"): report(3, [.serverError(503)]),
        ]
        let order = UpdateSchedule.order(
            ["dead", "new", "slow", "broken", "fast", "malformed"].map(url),
            reports: reports
        )
        #expect(order == ["fast", "malformed", "slow", "new", "broken", "dead"].map(url))
    }
}
