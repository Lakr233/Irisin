import AptRepository
import Foundation

extension Downloads {
    /// Waits until every one of these packages is on disk, or answers the
    /// first download's failure. Stops when `plan` is no longer the queue's.
    /// The queue page and a browser's confirmed plan both wait here.
    func awaitFiles(
        of packages: [Package],
        in plan: UUID,
        progress: @MainActor () -> Void = {}
    ) async -> String? {
        // ponytail: polls the statuses four times a second; a publisher on
        // the statuses if the tick ever shows
        while !Task.isCancelled, PackageQueue.shared.plan?.id == plan {
            let statuses = packages.map { (package: $0, status: status(for: $0.obtainDownloadLink())) }
            // a retry's download keeps the old error until it first reports
            if let failed = statuses.first(where: {
                $0.status?.errorDescription != nil && !isDownloading($0.package.obtainDownloadLink())
            })?.status?.errorDescription {
                return failed
            }
            if statuses.allSatisfy({ $0.status?.file != nil }) {
                return nil
            }
            // the queue starts every download it needs; one that is neither
            // done nor running was stopped from outside
            if statuses.contains(where: { $0.status?.file == nil && !isDownloading($0.package.obtainDownloadLink()) }) {
                return String(localized: "The download was interrupted.")
            }
            progress()
            try? await Task.sleep(continuousSeconds: 0.25)
        }
        return nil
    }
}
