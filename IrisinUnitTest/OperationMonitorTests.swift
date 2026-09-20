import AptRepository
import AptResolver
import Combine
@testable import irisin
import IrisinProtocol
import XCTest

final class OperationMonitorTests: XCTestCase {
    @MainActor
    private func monitor() throws -> OperationMonitor {
        let plan = try PackageResolver.resolve(
            request: .init(actions: [.remove("test.old")]),
            snapshot: .init(
                packages: [],
                installed: [Package(identity: "test.old", payload: ["1": ["architecture": "all"]])],
                architecture: "iphoneos-arm64"
            )
        )
        return OperationMonitor(operation: .init(plan: plan, transaction: .init(install: [], remove: ["test.old"])))
    }

    /// Events become rows, a phase, a progress count and a warning list; the
    /// summary is the last row and the outcome is published after it.
    @MainActor
    func testEventsPopulatePublishedState() async throws {
        let monitor = try monitor()
        var outcomes: [OperationMonitor.Outcome] = []
        var lineCountsAtOutcome: [Int] = []
        let subscription = monitor.$outcome.compactMap(\.self).sink { outcome in
            outcomes.append(outcome)
            lineCountsAtOutcome.append(monitor.lines.count)
        }
        defer { subscription.cancel() }

        monitor.append("Ready")
        monitor.record(.phase(.applying))
        monitor.record(.progress(completed: 0, total: 2))
        monitor.record(.package(.removing, identity: "test.old", version: "1"))
        monitor.record(.script(identity: "test.old", member: "prerm", arguments: ["remove"]))
        monitor.record(.output("bye"))
        monitor.record(.progress(completed: 1, total: 2))
        monitor.record(.warning(.noProcess(name: "sharingd")))
        monitor.record(.warning(.noProcess(name: "sharingd")))
        monitor.finish(.succeeded)
        monitor.finish(.failed("ignored"))

        XCTAssertEqual(monitor.phase, .applying)
        XCTAssertEqual(monitor.progress, .init(completed: 1, total: 2))
        let warning = InstallerEvent.Problem.noProcess(name: "sharingd").localizedDescription
        XCTAssertEqual(monitor.warnings, [warning, warning])
        XCTAssertEqual(monitor.transcript.count, 8)
        XCTAssertEqual(monitor.lines, [
            "Ready",
            InstallerEvent.Phase.applying.localizedTitle,
            String(localized: "Removing \("test.old (1)")"),
            String(localized: "Running \("test.old.prerm remove")"),
            "bye",
            "[!] " + warning,
            "[!] " + warning,
            String(localized: "Operation completed."),
        ])
        XCTAssertEqual(outcomes, [.succeeded])
        XCTAssertEqual(lineCountsAtOutcome, [monitor.lines.count])
        let finished = await monitor.finished
        XCTAssertEqual(finished, .succeeded)
    }

    @MainActor
    func testProgressFractionAndFailureSummary() throws {
        XCTAssertEqual(OperationMonitor.Progress(completed: 0, total: 0).fraction, 0)
        XCTAssertEqual(OperationMonitor.Progress(completed: 3, total: 4).fraction, 0.75)
        let monitor = try monitor()
        monitor.finish(.failed("nope"))
        XCTAssertEqual(monitor.lines, ["nope"])
        XCTAssertFalse(monitor.outcome?.succeeded ?? true)
    }

    /// A retry that only repairs dpkg state has stages but no package diff;
    /// its running and completed pages still carry a visible status row.
    @MainActor
    func testMaintenanceRowForRecoveryWithoutPackageChanges() {
        XCTAssertTrue(OperationController.showsMaintenanceRow(changeCount: 0, outcome: nil))
        XCTAssertTrue(OperationController.showsMaintenanceRow(changeCount: 0, outcome: .succeeded))
        XCTAssertFalse(OperationController.showsMaintenanceRow(changeCount: 0, outcome: .failed("postrm failed")))
        XCTAssertFalse(OperationController.showsMaintenanceRow(changeCount: 1, outcome: nil))
    }
}
