@testable import AptRepository
import AptResolver
import Foundation
@testable import irisin
import Testing

/// What a swipe and a selection on the Installed page ask for: the package
/// page's own answer for the same dpkg row.
@MainActor
struct InstalledRowActionTests {
    private typealias Descriptor = PackageMenuAction.ActionDescriptor

    @Test
    func swipeKeepsItsOwnOrderAndNothingElse() {
        #expect(PackageMenuAction.swipeOrder(of: [.reinstall, .versionControl, .remove, .viewMeta])
            == [.remove, .reinstall])
        #expect(PackageMenuAction.swipeOrder(of: [.update, .remove, .blockUpdate]) == [.remove, .update])
        #expect(PackageMenuAction.swipeOrder(of: [.dequeue, .replace, .versionControl]) == [.dequeue])
        #expect(PackageMenuAction.swipeOrder(of: [.install, .download]).isEmpty)
    }

    @Test(arguments: [
        // the repository the package came from still has the version
        ("1.0", true, ["remove", "reinstall"], false),
        // and a newer one
        ("2.0", true, ["remove", "update"], true),
        // another package manager installed it, a repository has an update
        ("2.0", false, ["remove", "update"], true),
        // nobody installed it from here and nothing is newer: dpkg's row alone
        ("1.0", false, ["remove"], false),
    ])
    func installedRowOffersWhatItsPageWould(
        offered: String,
        installedFromRepository: Bool,
        swipe: [String],
        updates: Bool
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = AptDatabase(at: directory.appendingPathComponent("apt.db"))
        let center = PackageCenter.default
        let previous = center.index
        center.index = PackageIndex(db: db)
        defer { center.index = previous }

        let repository = try #require(URL(string: "https://example.test/"))
        let installed = Package(identity: "test.installed-row", payload: ["1.0": [
            "architecture": "all", "status": "install ok installed",
        ]])
        let origin = Package(identity: installed.identity, payload: ["1.0": [
            "architecture": "all", "filename": "pool/package-1.0.deb",
        ]], repoRef: repository)
        let remote = Package(identity: installed.identity, payload: [offered: [
            "architecture": "all", "filename": "pool/package-\(offered).deb",
        ]], repoRef: repository)
        db.replacePackages(of: repository, with: [remote.identity: remote])
        db.replaceInstalled([installed.identity: installed], installedFrom: installedFromRepository ? [origin] : [])

        let (package, actions) = PackageMenuAction.swipeActions(forInstalled: installed)
        #expect(actions.map(\.descriptor.rawValue) == swipe)
        #expect(package == PackageBannerView(package: installed).package)

        let request = PackageMenuAction.updateRequest(forInstalled: installed)
        #expect((request != nil) == updates)
        if case let .install(requested) = request {
            #expect(requested == remote)
        }

        // an update the user blocked is not one a selection takes either
        let blocked = center.blockedUpdateTable
        defer { center.blockedUpdateTable = blocked }
        center.blockedUpdateTable.append(installed.identity)
        #expect(PackageMenuAction.updateRequest(forInstalled: installed) == nil)
    }
}
