@testable import AptRepository
import AptResolver
import Foundation
import XCTest

/// The queue keeps a pool read ahead from the database and the dpkg status
/// file, and solves the next tap with it. Whatever is written to either in
/// between, the next plan is the one the packages as written give.
final class ResolutionPoolDatabaseTests: XCTestCase {
    private let db = TestEnvironment.database()
    private let repository = URL(string: "https://pool.example")!
    /// The environment's dpkg status file, absent unless a test writes it.
    private let status = TestEnvironment.root.appendingPathComponent("status")

    private var index: PackageIndex {
        PackageIndex(db: db)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: status)
        super.tearDown()
    }

    private func package(_ identity: String, _ version: String, _ fields: [String: String] = [:]) -> Package {
        var meta = fields
        meta["package"] = identity
        meta["version"] = version
        meta["architecture"] = "iphoneos-arm64"
        meta["filename"] = "debs/\(identity)_\(version).deb"
        return Package(identity: identity, payload: [version: meta], repoRef: repository)
    }

    private func offer(_ packages: [Package]) {
        db.replacePackages(of: repository, with: Dictionary(uniqueKeysWithValues: packages.map { ($0.identity, $0) }))
    }

    private var app: Package {
        package("com.example.app", "1", ["depends": "com.example.library"])
    }

    private func installs(_ snapshot: ResolutionSnapshot, pool: ResolutionPool?) throws -> [String: String] {
        let plan = try PackageResolver.resolve(request: .init(actions: [.install(app)]), snapshot: snapshot, pool: pool)
        return Dictionary(uniqueKeysWithValues: plan.install.map { ($0.identity, $0.latestVersion ?? "") })
    }

    func testCatalogueIsReusedUntilTheDatabaseIsWritten() throws {
        offer([app, package("com.example.library", "1")])
        let first = try index.resolutionSnapshot()
        let again = try index.resolutionSnapshot(reusingCatalogueOf: first)
        XCTAssertTrue(again.sharesCatalogue(with: first))
        XCTAssertEqual(again.packages, first.packages)

        offer([app, package("com.example.library", "2")])
        let written = try index.resolutionSnapshot(reusingCatalogueOf: first)
        XCTAssertFalse(written.sharesCatalogue(with: first))
        XCTAssertGreaterThan(written.catalogueRevision, first.catalogueRevision)
        XCTAssertEqual(written.packages.first { $0.identity == "com.example.library" }?.latestVersion, "2")
    }

    /// Two databases written as often stand at the same revision.
    func testAnotherDatabaseIsNeverTakenForThisOne() throws {
        offer([app, package("com.example.library", "1")])
        let first = try index.resolutionSnapshot()
        let other = TestEnvironment.database()
        let library = package("com.example.library", "2")
        other.replacePackages(of: repository, with: [app.identity: app, library.identity: library])
        let read = try PackageIndex(db: other).resolutionSnapshot(reusingCatalogueOf: first)
        XCTAssertEqual(read.catalogueRevision, first.catalogueRevision)
        XCTAssertFalse(read.sharesCatalogue(with: first))
        XCTAssertEqual(read.packages.first { $0.identity == "com.example.library" }?.latestVersion, "2")
    }

    func testAPoolNeverOutlivesAWrite() throws {
        offer([app, package("com.example.library", "1")])
        let read = try index.resolutionSnapshot()
        var pool = try ResolutionPool(snapshot: read)
        XCTAssertTrue(try pool.serves(index.resolutionSnapshot(reusingCatalogueOf: pool.snapshot)))
        XCTAssertEqual(try installs(read, pool: pool), ["com.example.app": "1", "com.example.library": "1"])

        // a refresh wrote a newer library
        offer([app, package("com.example.library", "2")])
        var now = try index.resolutionSnapshot(reusingCatalogueOf: pool.snapshot)
        XCTAssertFalse(pool.serves(now))
        XCTAssertEqual(try installs(now, pool: pool), ["com.example.app": "1", "com.example.library": "2"])

        // dpkg installed it
        pool = try ResolutionPool(snapshot: now)
        try Data("""
        Package: com.example.library
        Status: install ok installed
        Version: 2
        Architecture: iphoneos-arm64

        """.utf8).write(to: status)
        now = try index.resolutionSnapshot(reusingCatalogueOf: pool.snapshot)
        XCTAssertTrue(now.sharesCatalogue(with: pool.snapshot))
        XCTAssertFalse(pool.serves(now))
        XCTAssertEqual(try installs(now, pool: pool), ["com.example.app": "1"])
    }
}
