@testable import AptRepository
import Foundation
@testable import irisin
import Testing
import UIKit

@MainActor
struct PackageVersionPickerTests {
    @Test
    func localPackageRecordDoesNotSelectTheSameVersionFromARepository() throws {
        let repository = try #require(URL(string: "https://local-record.example.test/"))
        let local = package(version: "1.0", repository: nil)
        let offered = package(version: "1.0", repository: repository)

        try withPicker(current: local, offered: offered) { controller in
            let tableView = try #require(controller.tableView)
            #expect(tableView.numberOfSections == 2)
            #expect(tableView.numberOfRows(inSection: 0) == 0)
            #expect(try headerTitle(in: tableView, section: 0) == String(localized: "Current Selection: Local Version"))
            #expect(try cell(in: tableView, at: IndexPath(row: 0, section: 1)).accessoryType == .none)
        }
    }

    @Test
    func exactRepositoryVersionIsSelected() throws {
        let repository = try #require(URL(string: "https://selected.example.test/"))
        let current = package(version: "1.0", repository: repository)

        try withPicker(current: current, offered: current) { controller in
            let tableView = try #require(controller.tableView)
            #expect(tableView.numberOfSections == 1)
            #expect(try headerTitle(in: tableView, section: 0) == nil)
            #expect(try cell(in: tableView, at: IndexPath(row: 0, section: 0)).accessoryType == .checkmark)
        }
    }

    @Test
    func unmatchedRepositoryVersionDoesNotPretendToBeLocal() throws {
        let selectedRepository = try #require(URL(string: "https://selected.example.test/"))
        let offeredRepository = try #require(URL(string: "https://offered.example.test/"))
        let current = package(version: "1.0", repository: selectedRepository)
        let offered = package(version: "1.0", repository: offeredRepository)

        try withPicker(current: current, offered: offered) { controller in
            let tableView = try #require(controller.tableView)
            #expect(tableView.numberOfSections == 1)
            #expect(try headerTitle(in: tableView, section: 0) == nil)
            #expect(try cell(in: tableView, at: IndexPath(row: 0, section: 0)).accessoryType == .none)
        }
    }

    private func withPicker(
        current: Package,
        offered: Package,
        assertions: (PackageVersionPickerController) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = AptDatabase(at: directory.appendingPathComponent("apt.db"))
        let center = PackageCenter.default
        let previous = center.index
        center.index = PackageIndex(db: database)
        defer { center.index = previous }

        let repository = try #require(offered.repoRef)
        database.replacePackages(of: repository, with: [offered.identity: offered])

        let controller = PackageVersionPickerController(package: current)
        controller.loadViewIfNeeded()
        try assertions(controller)
    }

    private func package(version: String, repository: URL?) -> Package {
        var metadata = ["architecture": "all"]
        if repository == nil {
            metadata["status"] = "install ok installed"
        } else {
            metadata["filename"] = "pool/test.version-picker.deb"
        }
        return Package(
            identity: "test.version-picker",
            payload: [version: metadata],
            repoRef: repository
        )
    }

    private func headerTitle(in tableView: UITableView, section: Int) throws -> String? {
        let dataSource = try #require(tableView.dataSource)
        return dataSource.tableView?(tableView, titleForHeaderInSection: section)
    }

    private func cell(in tableView: UITableView, at indexPath: IndexPath) throws -> UITableViewCell {
        let dataSource = try #require(tableView.dataSource)
        return dataSource.tableView(tableView, cellForRowAt: indexPath)
    }
}
