import AptRepository
import AptResolver
import Combine
@testable import irisin
import IrisinProtocol
import XCTest

final class OperationMonitorTests: XCTestCase {
    @MainActor
    private func monitor(removing identity: String = "test.old") throws -> OperationMonitor {
        let plan = try PackageResolver.resolve(
            request: .init(actions: [.remove(identity)]),
            snapshot: .init(
                packages: [],
                installed: [Package(identity: identity, payload: ["1": ["architecture": "all"]])],
                architecture: "iphoneos-arm64"
            )
        )
        return OperationMonitor(operation: .init(plan: plan, transaction: .init(install: [], remove: [identity])))
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

    /// The button closes the page, reloads the home screen when the tweaks
    /// changed, failed run or not, and leaves for an update of the app
    /// whatever the tweaks did.
    @MainActor
    func testEndingFollowsTweaksUnlessTheAppLeaves() throws {
        let unchanged = try monitor()
        unchanged.finish(.succeeded)
        XCTAssertEqual(unchanged.ending, .close)

        let changed = try monitor()
        changed.finish(.succeeded, changedTweaks: true)
        XCTAssertEqual(changed.ending, .reloadHomeScreen)

        let failed = try monitor()
        failed.finish(.failed("postinst failed"), changedTweaks: true)
        XCTAssertEqual(failed.ending, .reloadHomeScreen)

        let leaving = try monitor(removing: InstallerJob.selfIdentityPrefix + "test")
        leaving.finish(.succeeded, changedTweaks: true)
        XCTAssertEqual(leaving.ending, .updateApp)
    }

    /// A file put in place, replaced under the same name or taken away is a
    /// change; reading again with nothing done is not, a directory reached
    /// through a link is read once, and roothide's hidden `.jbroot` link is
    /// no tweak.
    func testTweakInjectionSeesEveryChange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TweakInjection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tweaks = root.appendingPathComponent("usr/lib/TweakInject")
        try FileManager.default.createDirectory(at: tweaks, withIntermediateDirectories: true)
        let substrate = root.appendingPathComponent("Library/MobileSubstrate")
        try FileManager.default.createDirectory(at: substrate, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: substrate.appendingPathComponent("DynamicLibraries"),
            withDestinationURL: tweaks
        )
        let paths = TweakInjection.directories.map { root.path + $0 } + [root.path + "/missing"]

        let empty = TweakInjection.read(paths)
        XCTAssertEqual(TweakInjection.read(paths), empty)
        try FileManager.default.createSymbolicLink(
            at: tweaks.appendingPathComponent(".jbroot"),
            withDestinationURL: root
        )
        XCTAssertEqual(TweakInjection.read(paths), empty)

        let dylib = tweaks.appendingPathComponent("Example.dylib")
        try Data("one".utf8).write(to: dylib)
        let installed = TweakInjection.read(paths)
        XCTAssertNotEqual(installed, empty)
        XCTAssertEqual(TweakInjection.read(paths), installed)
        XCTAssertEqual(TweakInjection.read([tweaks.path]), installed)

        // a reinstall: the same name and size, a new file
        let staged = root.appendingPathComponent("Example.dylib")
        try Data("two".utf8).write(to: staged)
        XCTAssertEqual(rename(staged.path, dylib.path), 0)
        let reinstalled = TweakInjection.read(paths)
        XCTAssertNotEqual(reinstalled, installed)

        try FileManager.default.removeItem(at: dylib)
        XCTAssertEqual(TweakInjection.read(paths), empty)
    }
}
