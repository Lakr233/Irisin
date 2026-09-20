import Foundation
import IrisinProtocol
import Testing

struct OrderedTransactionTests {
    @Test func configureRequiresPriorUnpack() {
        let package = InstallerJob.Transaction.Item(identity: "aa", path: "/aa.deb")
        let job = InstallerJob.transaction(.init(install: [package], remove: [], stages: [.configure(["aa"]), .unpack(["aa"])]))
        #expect(throws: (any Error).self) { try job.validate() }
    }

    @Test func everyDeclaredPackageMustHaveExactlyOneStage() {
        let job = InstallerJob.transaction(.init(install: [], remove: ["aa", "bb"], stages: [.remove(["aa"])]))
        #expect(throws: (any Error).self) { try job.validate() }
        let duplicate = InstallerJob.transaction(.init(install: [], remove: ["aa"], stages: [.remove(["aa"]), .remove(["aa"])]))
        #expect(throws: (any Error).self) { try duplicate.validate() }
    }

    @Test func configureExistingPackageWithoutArchive() throws {
        let job = InstallerJob.transaction(.init(install: [], remove: [], stages: [.configure(["aa"])], configureExisting: ["aa"]))
        try job.validate()
        #expect(try InstallerJob.decode(job.encoded()) == job)
    }

    @Test func scriptFailurePolicyRoundTrips() throws {
        let transaction = InstallerJob.Transaction(install: [], remove: ["aa"], ignoreScriptFailures: true)
        #expect(try InstallerJob.decode(InstallerJob.transaction(transaction).encoded()) == .transaction(transaction))
    }

    @Test func recoveryPolicyRoundTrips() throws {
        let transaction = InstallerJob.Transaction(install: [], remove: ["aa"], recoveryMode: true)
        #expect(try InstallerJob.decode(InstallerJob.transaction(transaction).encoded()) == .transaction(transaction))
    }

    @Test func undeclaredPackageAndOverlappingActionsAreRejected() {
        let missing = InstallerJob.transaction(.init(install: [], remove: ["aa"], stages: [.remove(["bb"])]))
        #expect(throws: (any Error).self) { try missing.validate() }
        let overlap = InstallerJob.transaction(.init(install: [.init(identity: "aa", path: "/aa.deb")], remove: ["aa"]))
        #expect(throws: (any Error).self) { try overlap.validate() }
    }

    @Test func oldWireShapeCannotSilentlyUseUnorderedExecution() {
        let old = #"{"transaction":{"_0":{"install":[],"remove":["aa"],"dryRun":false}}}"#
        #expect(throws: (any Error).self) { try InstallerJob.decode(Data(old.utf8)) }
    }
}
