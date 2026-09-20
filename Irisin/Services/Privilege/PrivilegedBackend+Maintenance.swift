import IrisinProtocol
import SPIndicator
import UIKit

extension PrivilegedBackend {
    /// Runs one maintenance job (rebuild icons, respring) and keeps the last
    /// failure it reported, for a screen that started it and owes the user
    /// an answer.
    static func runMaintenance(_ job: InstallerJob) async -> OperationMonitor.Outcome {
        var problem: InstallerEvent.Problem?
        let status = await run(job) { @MainActor event in
            if case let .failure(reported) = event {
                problem = reported
            }
        }
        return .init(status: status, failure: problem)
    }
}

extension UIViewController {
    /// A toast for a job that worked, the reason for one that did not.
    func report(
        _ outcome: OperationMonitor.Outcome,
        succeeded: String.LocalizationValue,
        failed: String.LocalizationValue
    ) {
        switch outcome {
        case .succeeded:
            SPIndicator.present(title: String(resolving: succeeded), preset: .done)
        case let .failed(reason):
            presentNotice(title: failed, message: reason)
        }
    }
}
