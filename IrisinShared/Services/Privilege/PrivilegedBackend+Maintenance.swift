import IrisinProtocol

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
