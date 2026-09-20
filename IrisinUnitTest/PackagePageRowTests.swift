import AptRepository
@testable import irisin
import Testing
import UIKit

/// The package page's rows follow the views inside them by snapshot alone:
/// iOS 16 throws from the table's own mutation calls while its data source
/// is a diffable one (issue 125).
@MainActor
struct PackagePageRowTests {
    @Test
    func thePhotoRowFollowsThePhoto() async throws {
        let controller = PackageController(package: Package(identity: "wiki.qaq.irisin.test"))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let artwork = try #require(controller.dataSource.indexPath(for: .artwork))
        func rowFitsBanner() -> Bool {
            let height = controller.tableView.rectForRow(at: artwork).height
            return abs(height - (controller.preferredBannerHeight + controller.inset)) < 1
        }
        try await waitUntil { rowFitsBanner() }

        let handwriting = controller.preferredBannerHeight
        let size = CGSize(width: 400, height: 50)
        controller.bannerArtwork.imageView.image = UIGraphicsImageRenderer(size: size).image { _ in }
        try await waitUntil { controller.preferredBannerHeight != handwriting && rowFitsBanner() }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition())
    }
}
