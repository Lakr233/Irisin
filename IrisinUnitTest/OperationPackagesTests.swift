@testable import irisin
import IrisinProtocol
import XCTest

final class OperationPackagesTests: XCTestCase {
    private let stages: [InstallerStage] = [.remove(["old"]), .unpack(["a", "b"]), .configure(["a", "b"])]

    /// A row counts its files while they land, holds its share between its
    /// two steps, and is done when the second one closes.
    func testStepsFillTheRow() {
        var packages = OperationPackages(stages: stages)
        // checking ends without a word: the next package, or the next phase
        packages.record(.phase(.verifying))
        packages.record(.package(.verifying, identity: "a", version: ""))
        XCTAssertEqual(packages.states["a"]?.status, .running(.verifying, script: nil))
        packages.record(.package(.verifying, identity: "b", version: ""))
        XCTAssertEqual(packages.states["a"]?.status, .waiting)
        XCTAssertEqual(packages.states["a"]?.nextStep, .unpacking)
        packages.record(.phase(.applying))
        XCTAssertEqual(packages.states["b"]?.status, .waiting)
        XCTAssertEqual(packages.states["b"]?.fraction ?? 0, 0.1, accuracy: 0.001)

        packages.record(.progress(completed: 0, total: 5))
        packages.record(.package(.removing, identity: "old", version: "1"))
        packages.record(.script(identity: "old", member: "prerm", arguments: ["remove"]))
        XCTAssertEqual(packages.states["old"]?.status, .running(.removing, script: "prerm"))
        XCTAssertEqual(packages.states["old"]?.isIndeterminate, true)
        XCTAssertEqual(packages.current, "old")
        packages.record(.progress(completed: 1, total: 5))
        XCTAssertEqual(packages.states["old"]?.status, .done)
        XCTAssertNil(packages.current)

        packages.record(.package(.unpacking, identity: "a", version: "2"))
        packages.record(.packageProgress(identity: "a", completed: 5, total: 10))
        XCTAssertEqual(packages.states["a"]?.fraction ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(packages.states["a"]?.isIndeterminate, false)
        packages.record(.progress(completed: 2, total: 5))
        XCTAssertEqual(packages.states["a"]?.status, .waiting)
        XCTAssertEqual(packages.states["a"]?.nextStep, .configuring)
        XCTAssertEqual(packages.states["a"]?.fraction ?? 0, 0.7, accuracy: 0.001)

        // a trigger for a package the transaction never named moves no row
        packages.record(.package(.triggering, identity: "stranger", version: "1"))
        XCTAssertNil(packages.current)
        XCTAssertNil(packages.states["stranger"])
    }

    /// After a failure every row says what is true of its package.
    func testFailureSettlesEveryRow() {
        var packages = OperationPackages(stages: stages + [.unpack(["c"])])
        packages.record(.progress(completed: 0, total: 6))
        packages.record(.package(.removing, identity: "old", version: "1"))
        packages.record(.progress(completed: 1, total: 6))
        for identity in ["a", "b"] {
            packages.record(.package(.unpacking, identity: identity, version: "2"))
            packages.record(.progress(completed: identity == "a" ? 2 : 3, total: 6))
        }
        packages.record(.package(.configuring, identity: "a", version: "2"))
        let problem = InstallerEvent.Problem.packageFailed(identity: "a", step: .configuring, detail: "postinst returned 1")
        packages.record(.failure(problem))
        packages.finish(succeeded: false)

        XCTAssertEqual(packages.states["old"]?.status, .done)
        XCTAssertEqual(packages.states["a"]?.status, .failed(step: .configuring))
        XCTAssertEqual(packages.states["a"]?.problem, problem)
        XCTAssertEqual(packages.states["b"]?.status, .incomplete)
        XCTAssertEqual(packages.states["c"]?.status, .notStarted)
        XCTAssertEqual(packages.states.values.filter(\.hasProblem).count, 2)
    }

    /// A script another package runs within a step takes the output, not
    /// the step; a package's own failing script names itself on its row.
    func testStepBelongsToThePackageThatOpenedIt() {
        var packages = OperationPackages(stages: [.unpack(["new", "victim"]), .configure(["new"])])
        packages.record(.progress(completed: 0, total: 3))
        packages.record(.package(.unpacking, identity: "new", version: "2"))
        packages.record(.script(identity: "victim", member: "prerm", arguments: ["deconfigure", "in-favour", "new", "2"]))
        XCTAssertEqual(packages.current, "victim")
        packages.record(.progress(completed: 1, total: 3))
        XCTAssertEqual(packages.states["new"]?.nextStep, .configuring)
        XCTAssertEqual(packages.states["victim"]?.status, .waiting)

        packages.record(.package(.configuring, identity: "new", version: "2"))
        let problem = InstallerEvent.Problem.scriptFailed(identity: "new", step: .configuring, script: "postinst", status: 1)
        packages.record(.failure(problem))
        packages.finish(succeeded: false)
        XCTAssertEqual(packages.states["new"]?.status, .failed(step: .configuring))
        XCTAssertEqual(packages.states["new"]?.failedScript, "postinst")
    }

    /// A helper that went away mid-step leaves that row failed, with no
    /// reason to show; a repair warning marks its row.
    func testSilentEndAndRepair() {
        var packages = OperationPackages(stages: [.unpack(["a"]), .configure(["a"])])
        packages.record(.package(.unpacking, identity: "a", version: "2"))
        packages.record(.warning(.packageNeedsRepair(identity: "a")))
        packages.finish(succeeded: false)
        XCTAssertEqual(packages.states["a"]?.status, .failed(step: .unpacking))
        XCTAssertNil(packages.states["a"]?.problem)
        XCTAssertEqual(packages.states["a"]?.needsRepair, true)
    }

    /// A script error accepted by the recovery policy remains attached to
    /// its package after the step completes, without turning success into a
    /// stopped operation.
    func testIgnoredScriptFailureMarksCompletedPackage() {
        var packages = OperationPackages(stages: [.unpack(["a"]), .configure(["a"])])
        let problem = InstallerEvent.Problem.scriptFailureIgnored(
            identity: "a",
            script: "preinst",
            detail: "exited with status 3"
        )
        packages.record(.progress(completed: 0, total: 2))
        packages.record(.package(.unpacking, identity: "a", version: "1"))
        packages.record(.warning(problem))
        packages.record(.progress(completed: 1, total: 2))
        packages.record(.package(.configuring, identity: "a", version: "1"))
        packages.record(.progress(completed: 2, total: 2))
        packages.finish(succeeded: true)

        XCTAssertEqual(packages.states["a"]?.status, .done)
        XCTAssertEqual(packages.states["a"]?.ignoredScriptFailure, true)
        XCTAssertEqual(packages.states["a"]?.problem, problem)
        XCTAssertEqual(packages.states["a"]?.failedScript, "preinst")
        XCTAssertEqual(packages.states["a"]?.hasProblem, true)
    }
}
