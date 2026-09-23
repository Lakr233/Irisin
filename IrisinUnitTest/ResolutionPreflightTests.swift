@testable import AptRepository
import AptResolver
@testable import irisin
import UIKit
import XCTest

/// The queue solves a tap against the pool it read last
/// (`ResolutionPool`). Written packages it was not told of yet, or a pool
/// dropped under memory pressure, change how long a solve takes and never
/// what it answers.
final class ResolutionPreflightTests: XCTestCase {
    private let repository = URL(string: "https://preflight.example.test/")!

    private func package(_ identity: String, _ version: String, depends: String? = nil) -> Package {
        var fields = ["package": identity, "version": version, "architecture": "all", "filename": "debs/\(identity)_\(version).deb"]
        fields["depends"] = depends
        return Package(identity: identity, payload: [version: fields], repoRef: repository)
    }

    @MainActor
    private func version(of identity: String, in proposal: PackageQueue.Proposal) -> String? {
        proposal.plan?.install.first { $0.identity == identity }?.latestVersion
    }

    @MainActor
    func testAKeptPoolNeverAnswersForAWrittenCatalogue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = AptDatabase(at: directory.appendingPathComponent("apt.db"))
        let center = PackageCenter.default
        let previous = center.index
        center.index = PackageIndex(db: db)
        let manager = PackageQueue.shared
        defer {
            manager.clear()
            center.index = previous
        }

        let app = package("com.example.preflight.app", "1", depends: "com.example.preflight.library")
        let old = package("com.example.preflight.library", "1")
        db.replacePackages(of: repository, with: [app.identity: app, old.identity: old])
        guard case let .success(first) = await manager.propose([.install(app)]) else {
            return XCTFail("the app and its library must solve")
        }
        XCTAssertEqual(version(of: old.identity, in: first), "1")

        // a refresh wrote a newer library, and the queue has not heard yet:
        // the pool of the first solve is kept, and must not answer
        let new = package("com.example.preflight.library", "2")
        db.replacePackages(of: repository, with: [app.identity: app, new.identity: new])
        guard case let .success(second) = await manager.propose([.install(app)]) else {
            return XCTFail("the app and its newer library must solve")
        }
        XCTAssertEqual(version(of: new.identity, in: second), "2")

        // under memory pressure the pool goes; the next solve reads its own
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        await withCheckedContinuation { done in
            DispatchQueue.main.async { done.resume() }
        }
        let newest = package("com.example.preflight.library", "3")
        db.replacePackages(of: repository, with: [app.identity: app, newest.identity: newest])
        guard case let .success(third) = await manager.propose([.install(app)]) else {
            return XCTFail("the app and its newest library must solve")
        }
        XCTAssertEqual(version(of: newest.identity, in: third), "3")
    }

    /// A preflight read while the packages settle, then the catalogue
    /// written again before the tap: the tap is solved against what was
    /// written last.
    @MainActor
    func testAPreflightOvertakenByAWriteIsNotSolvedWith() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = AptDatabase(at: directory.appendingPathComponent("apt.db"))
        let center = PackageCenter.default
        let previous = center.index
        center.index = PackageIndex(db: db)
        let manager = PackageQueue.shared
        defer {
            manager.clear()
            center.index = previous
        }

        let app = package("com.example.preflight.app", "1", depends: "com.example.preflight.library")
        let old = package("com.example.preflight.library", "1")
        db.replacePackages(of: repository, with: [app.identity: app, old.identity: old])
        // the packages moved: the preflight is waiting to read them, and a
        // solve now starts the read at once and waits for it
        manager.schedulePreflight()
        guard case let .success(first) = await manager.propose([.install(app)]) else {
            return XCTFail("the app and its library must solve")
        }
        XCTAssertEqual(version(of: old.identity, in: first), "1")

        let new = package("com.example.preflight.library", "2")
        db.replacePackages(of: repository, with: [app.identity: app, new.identity: new])
        manager.schedulePreflight()
        guard case let .success(second) = await manager.propose([.install(app)]) else {
            return XCTFail("the app and its newer library must solve")
        }
        XCTAssertEqual(version(of: new.identity, in: second), "2")
    }
}
