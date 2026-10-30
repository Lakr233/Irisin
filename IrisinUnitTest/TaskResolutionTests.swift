@testable import AptRepository
import AptResolver
@testable import irisin
import UIKit
import XCTest

final class TaskResolutionTests: XCTestCase {
    @MainActor
    func testMissingLocalFileStaysPinnedAcrossQueueRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = AptDatabase(at: directory.appendingPathComponent("apt.db"))
        let center = PackageCenter.default
        let previous = center.index
        center.index = PackageIndex(db: db)
        let manager = PackageQueue.shared
        XCTAssertNil(manager.plan)
        defer {
            manager.clear()
            center.index = previous
        }

        let file = directory.appendingPathComponent("local.deb")
        try Data().write(to: file)
        let local = Package(identity: "test.pinned", payload: ["1": [
            "architecture": "all", "filename": file.absoluteString,
        ]])
        let dependent = Package(identity: "test.dependent", payload: ["1": [
            "architecture": "all", "filename": directory.appendingPathComponent("dependent.deb").absoluteString,
            "depends": local.identity,
        ]])
        guard case let .success(proposal) = await manager.propose([.install(local), .install(dependent)]) else {
            return XCTFail("The explicitly selected local packages must solve")
        }
        XCTAssertTrue(manager.commit(proposal))

        try FileManager.default.removeItem(at: file)
        let repository = try XCTUnwrap(URL(string: "https://example.test/"))
        let remote = Package(identity: local.identity, payload: ["2": [
            "architecture": "all", "filename": "pool/replacement.deb",
        ]], repoRef: repository)
        db.replacePackages(of: repository, with: [remote.identity: remote])
        NotificationCenter.default.post(name: PackageCenter.packageRecordChanged, object: nil)
        // Let receive(on: .main) schedule the queue's refresh before awaiting it.
        await withCheckedContinuation { done in
            DispatchQueue.main.async { done.resume() }
        }
        await manager.settled()

        let refreshed = try XCTUnwrap(manager.plan)
        XCTAssertNotEqual(refreshed.id, proposal.plan?.id)
        XCTAssertEqual(Set(manager.actions.map(\.identity)), [local.identity, dependent.identity])
        XCTAssertEqual(Set(refreshed.install), [local, dependent])
        let operation = await Installer.shared.createOperationPayload(plan: refreshed)
        XCTAssertNil(operation, "A missing selected file must fail instead of installing a repository substitute")
    }

    @MainActor
    func testQueueCoversTheUpdatesItAsksForOrBringsIn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = AptDatabase(at: directory.appendingPathComponent("apt.db"))
        let center = PackageCenter.default
        let previous = center.index
        center.index = PackageIndex(db: db)
        let manager = PackageQueue.shared
        defer {
            manager.clear()
            center.index = previous
        }

        let repository = try XCTUnwrap(URL(string: "https://example.test/"))
        let library = Package(identity: "test.library", payload: ["2": [
            "architecture": "all", "filename": "pool/library.deb",
        ]], repoRef: repository)
        let tweak = Package(identity: "test.tweak", payload: ["2": [
            "architecture": "all", "filename": "pool/tweak.deb", "depends": "test.library (>= 2)",
        ]], repoRef: repository)
        db.replacePackages(of: repository, with: [library.identity: library, tweak.identity: tweak])
        guard case let .success(proposal) = await manager.propose([.install(tweak)]) else {
            return XCTFail("A package and its dependency must solve")
        }
        XCTAssertTrue(manager.commit(proposal))

        // Update All keeps the queue's own request, whatever version it is for
        XCTAssertTrue(manager.coversUpdate(of: tweak.identity, to: "3"))
        // and a dependency the queue brings in is as new as what it installs
        XCTAssertTrue(manager.coversUpdate(of: library.identity, to: "2"))
        XCTAssertTrue(manager.coversUpdate(of: library.identity, to: "1.5"))
        XCTAssertFalse(manager.coversUpdate(of: library.identity, to: "2.1"))
        XCTAssertFalse(manager.coversUpdate(of: "test.other", to: "1"))
    }

    @MainActor
    func testRefusedRequestReportsAndLeavesNothingBehind() async throws {
        let broken = Package(
            identity: "test.broken",
            payload: ["1": ["architecture": "all", "depends": "invalid (>=)"]]
        )
        let result = await PackageQueue.shared.propose([.install(broken)])
        guard case let .failure(failure) = result else { return XCTFail("Malformed requirements must fail") }

        // the failure says why, the queue did not take it, and nothing is left running
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertNil(PackageQueue.shared.plan)
        XCTAssertTrue(PackageQueue.shared.actions.isEmpty)
        XCTAssertFalse(Installer.shared.inProcessingQueue)

        // a plan the catalogue has moved out from under is not run
        let old = Package(identity: "test.previous", payload: ["1": ["architecture": "all"]])
        let oldPlan = try PackageResolver.resolve(
            request: .init(actions: [.remove(old.identity)]),
            snapshot: .init(packages: [], installed: [old], architecture: "iphoneos-arm64")
        )
        let staleOperation = Installer.OperationPayload(
            plan: oldPlan,
            transaction: .init(install: [], remove: [old.identity])
        )
        let outcome = await Installer.shared.beginOperation(operation: staleOperation).finished
        XCTAssertFalse(outcome.succeeded, "A rejected operation must not display a success checkmark")
        XCTAssertFalse(Installer.shared.inProcessingQueue)
    }
}
