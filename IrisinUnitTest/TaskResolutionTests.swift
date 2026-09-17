import AptRepository
import AptResolver
@testable import irisin
import UIKit
import XCTest

final class TaskResolutionTests: XCTestCase {
    @MainActor
    func testRefusedRequestReportsAndLeavesNothingBehind() async throws {
        let broken = Package(
            identity: "test.broken",
            payload: ["1": ["architecture": "all", "depends": "invalid (>=)"]]
        )
        let result = await TaskManager.shared.propose([.install(broken)])
        guard case let .failure(failure) = result else { return XCTFail("Malformed requirements must fail") }

        // the failure says why, the queue did not take it, and nothing is left running
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertNil(TaskManager.shared.plan)
        XCTAssertTrue(TaskManager.shared.actions.isEmpty)
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
