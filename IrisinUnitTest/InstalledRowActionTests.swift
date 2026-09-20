@testable import AptRepository
import AptResolver
import Foundation
@testable import irisin
import Testing

/// What a swipe and a selection on the Installed page ask for: the package
/// page's own answer for the same dpkg row.
@MainActor
@Suite(.serialized)
struct InstalledRowActionTests {
    private static let identity = "test.installed-row"

    /// A dpkg row at 1.0 and what a repository offers under its identifier,
    /// in a catalogue of their own for as long as `body` runs.
    private func withInstalledRow(
        offered: String,
        installedFromRepository: Bool = true,
        tag: String? = nil,
        alongside others: [Package] = [],
        _ body: (_ installed: Package, _ remote: Package) throws -> Void
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
        let installed = Package(identity: Self.identity, payload: ["1.0": [
            "architecture": "all", "status": "install ok installed",
        ]])
        let origin = Package(identity: Self.identity, payload: ["1.0": [
            "architecture": "all", "filename": "pool/package-1.0.deb",
        ]], repoRef: repository)
        var metadata = ["architecture": "all", "filename": "pool/package-\(offered).deb"]
        metadata["tag"] = tag
        let remote = Package(identity: Self.identity, payload: [offered: metadata], repoRef: repository)
        db.replacePackages(of: repository, with: [remote.identity: remote])
        var rows = [installed.identity: installed]
        for other in others {
            rows[other.identity] = other
        }
        db.replaceInstalled(rows, installedFrom: installedFromRepository ? [origin] : [])
        try body(installed, remote)
    }

    @Test
    func swipeKeepsItsOwnOrderAndNothingElse() {
        #expect(PackageMenu.swipeOrder(of: [.reinstall, .versionControl, .remove, .viewMeta])
            == [.remove, .reinstall])
        #expect(PackageMenu.swipeOrder(of: [.update, .remove, .blockUpdate]) == [.remove, .update])
        #expect(PackageMenu.swipeOrder(of: [.dequeue, .replace, .versionControl]) == [.dequeue])
        #expect(PackageMenu.swipeOrder(of: [.install, .download]).isEmpty)
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
        try withInstalledRow(offered: offered, installedFromRepository: installedFromRepository) { installed, remote in
            let (package, actions) = PackageMenu.swipeActions(forInstalled: installed)
            #expect(actions.map(\.descriptor.rawValue) == swipe)
            #expect(package == PackageMenu.requestPackage(for: installed))

            let request = PackageMenu.updateRequest(forInstalled: installed)
            #expect((request != nil) == updates)
            if case let .install(requested) = request {
                #expect(requested == remote)
            }

            let removal = PackageMenu.removal(ofInstalled: [installed])
            #expect(removal.leftOut.isEmpty)
            guard case let .actions(asked) = removal.request, case let .remove(identity) = asked.first else {
                Issue.record("a selection of one installed row asks for its removal")
                return
            }
            #expect(asked.count == 1)
            #expect(identity == installed.identity)
        }
    }

    /// An update the user blocked is not one a selection takes, and the swipe
    /// does not offer it either.
    @Test
    func aBlockedUpdateIsNotTaken() throws {
        try withInstalledRow(offered: "2.0") { installed, _ in
            try #require(PackageMenu.updateRequest(forInstalled: installed) != nil)
            let center = PackageCenter.default
            let blocked = center.blockedUpdateTable
            defer { center.blockedUpdateTable = blocked }
            center.blockedUpdateTable.append(installed.identity)
            #expect(PackageMenu.updateRequest(forInstalled: installed) == nil)
            let swipe = PackageMenu.swipeActions(forInstalled: installed).actions
            #expect(!swipe.contains { $0.descriptor == .update })
        }
    }

    /// A paid package's update is a purchase check on its own page: its row
    /// swipes to Update, and a selection leaves it out.
    @Test
    func aCommercialUpdateIsLeftToItsPage() throws {
        try withInstalledRow(offered: "2.0", tag: "cydia::commercial") { installed, _ in
            let swipe = PackageMenu.swipeActions(forInstalled: installed).actions
            #expect(swipe.map(\.descriptor) == [.remove, .update])
            #expect(PackageMenu.updateRequest(forInstalled: installed) == nil)
        }
    }

    /// A queued row leaves the queue and offers nothing else, by swipe and
    /// alone in a selection; among other rows it is left out.
    @Test
    func aQueuedRowIsWithdrawn() throws {
        let other = Package(identity: "test.installed-row.other", payload: ["1.0": [
            "architecture": "all", "status": "install ok installed",
        ]])
        try withInstalledRow(offered: "2.0", alongside: [other]) { installed, _ in
            let manager = TaskManager.shared
            try #require(manager.plan == nil && manager.actions.isEmpty)
            defer { manager.clear() }
            try #require(manager.commit(.init(
                actions: [.remove(installed.identity)],
                cleanup: [],
                plan: nil,
                notices: [],
                revision: manager.revision
            )))

            let swipe = PackageMenu.swipeActions(forInstalled: installed).actions
            #expect(swipe.map(\.descriptor) == [.dequeue])
            #expect(PackageMenu.updateRequest(forInstalled: installed) == nil)

            let alone = PackageMenu.removal(ofInstalled: [installed])
            guard case let .withdraw(identity) = alone.request else {
                Issue.record("a queued row selected alone leaves the queue")
                return
            }
            #expect(identity == installed.identity)
            #expect(alone.leftOut.isEmpty)

            let both = PackageMenu.removal(ofInstalled: [installed, other])
            guard case let .actions(asked) = both.request, case let .remove(removed) = asked.first else {
                Issue.record("the row that is not queued is removed")
                return
            }
            #expect(asked.count == 1)
            #expect(removed == other.identity)
            #expect(both.leftOut == [installed])
        }
    }
}
