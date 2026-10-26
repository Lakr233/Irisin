import AptResolver
import IrisinProtocol

extension Installer {
    nonisolated struct OperationPayload: Sendable {
        let plan: ResolutionPlan
        let transaction: InstallerJob.Transaction
    }
}
