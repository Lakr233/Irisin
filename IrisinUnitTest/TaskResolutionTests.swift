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
        let operation = await TaskProcessor.shared.createOperationPayload(plan: refreshed)
        XCTAssertNil(operation, "A missing selected file must fail instead of installing a repository substitute")
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
        XCTAssertFalse(TaskProcessor.shared.inProcessingQueue)

        // a plan the catalogue has moved out from under is not run
        let old = Package(identity: "test.previous", payload: ["1": ["architecture": "all"]])
        let oldPlan = try PackageResolver.resolve(
            request: .init(actions: [.remove(old.identity)]),
            snapshot: .init(packages: [], installed: [old], architecture: "iphoneos-arm64")
        )
        let staleOperation = TaskProcessor.OperationPayload(
            plan: oldPlan,
            transaction: .init(install: [], remove: [old.identity])
        )
        let outcome = await TaskProcessor.shared.beginOperation(operation: staleOperation).finished
        XCTAssertFalse(outcome.succeeded, "A rejected operation must not display a success checkmark")
        XCTAssertFalse(TaskProcessor.shared.inProcessingQueue)
    }
}
