import AptRepository
import Foundation
@testable import irisin
import Testing

@MainActor
struct NotificationBindingTests {
    @Test
    func mergedReloadSignalsKeepTrailingAndLaterInvalidations() async throws {
        let notifications = NotificationCenter()
        let controller = RecordingUpdateController(notificationCenter: notifications)
        controller.loadViewIfNeeded()
        controller.reloadCount = 0

        notifications.post(name: RepositoryCenter.metadataUpdate, object: nil)
        try await waitUntil { controller.reloadCount == 1 }
        for name in [PackageCenter.packageRecordChanged, RepositoryCenter.registrationUpdate, RepositoryCenter.metadataUpdate] {
            notifications.post(name: name, object: nil)
        }
        try await waitUntil { controller.reloadCount == 2 }
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(controller.reloadCount == 2)

        // Identical, payload-free invalidations still represent new work.
        notifications.post(name: RepositoryCenter.metadataUpdate, object: nil)
        try await waitUntil { controller.reloadCount == 3 }
    }

    @Test
    func slowerDashboardRefreshCannotOverwriteNewerSections() async throws {
        let controller = DataOnlyDashboardController()
        controller.loadViewIfNeeded()
        var olderResult: CheckedContinuation<[DashboardController.Section], Never>?
        let older = Task {
            await controller.reload(animated: false) {
                await withCheckedContinuation { olderResult = $0 }
            }
        }
        try await waitUntil { olderResult != nil }

        await controller.reload(animated: false) {
            [DashboardController.Section(
                title: "New sections",
                packages: [],
                shouldLimit: false,
                action: nil
            )]
        }
        olderResult?.resume(returning: [DashboardController.Section(
            title: "Old sections",
            packages: [],
            shouldLimit: false,
            action: nil
        )])
        await older.value

        #expect(controller.dataSource.map(\.title) == ["New sections"])
        #expect(controller.diffableDataSource.snapshot().sectionIdentifiers == ["New sections"])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}

@MainActor
private final class RecordingUpdateController: UpdateController {
    var reloadCount = 0

    override func reload() {
        #expect(Thread.isMainThread)
        reloadCount += 1
    }
}

@MainActor
private final class DataOnlyDashboardController: DashboardController {
    /// Exercise reload and snapshot commits without starting app-wide subscriptions.
    override func viewDidLoad() {}
}
