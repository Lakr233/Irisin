import AptResolver
import IrisinProtocol

extension TaskProcessor {
    nonisolated struct OperationPayload: Sendable {
        let plan: ResolutionPlan
        let transaction: InstallerJob.Transaction
    }
}
