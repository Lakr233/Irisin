import IrisinProtocol
import SPIndicator
import UIKit

extension PrivilegedBackend {
    /// Runs one maintenance job (rebuild icons, respring) and keeps the last
    /// failure it reported, for a screen that started it and owes the user
    /// an answer.
    static func runMaintenance(_ job: InstallerJob) async -> OperationMonitor.Outcome {
        let box = FailureBox()
        let status = await run(job) { event in
            if case let .failure(problem) = event {
                await box.record(problem)
            }
        }
        return .init(status: status, failure: box.problem)
    }

    private final class FailureBox {
        private(set) var problem: InstallerEvent.Problem?

        func record(_ problem: InstallerEvent.Problem) {
            self.problem = problem
        }
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
            SPIndicator.present(title: String(localized: succeeded), preset: .done)
        case let .failed(reason):
            presentNotice(title: failed, message: reason)
        }
    }
}
