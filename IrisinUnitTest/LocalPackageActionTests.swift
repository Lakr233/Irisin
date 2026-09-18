@testable import AptRepository
import AptResolver
import Foundation
@testable import irisin
import Testing
import UIKit

@MainActor
struct LocalPackageActionTests {
    @Test(arguments: ["4.0.6", "4.0.5", "4.0.3", "4.0.2"])
    func localFileSurvivesAnAvailableRepositoryUpdate(version: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = AptDatabase(at: directory.appendingPathComponent("apt.db"))
        let center = PackageCenter.default
        let previous = center.index
        center.index = PackageIndex(db: db)
        defer { center.index = previous }

        let repository = try #require(URL(string: "https://example.test/"))
        let installed = Package(identity: "test.local", payload: ["4.0.3": [
            "architecture": "all", "status": "install ok installed",
        ]])
        let remote = Package(identity: installed.identity, payload: ["4.0.5": [
            "architecture": "all", "filename": "pool/package.deb",
        ]], repoRef: repository)
        db.replaceInstalled([installed.identity: installed])
        db.replacePackages(of: repository, with: [remote.identity: remote])
        #expect(PackageBannerView(package: installed).package == remote)

        let file = directory.appendingPathComponent("AirDrop package.deb")
        let local = Package(identity: installed.identity, payload: [version: [
            "architecture": "all", "filename": file.absoluteString, "depends": "test.dependency",
        ]])
        let page = PackageController(package: local)
        page.loadViewIfNeeded()
        page.viewWillAppear(false)
        let banner = page.bannerPackageView
        #expect(page.packageObject == local)
        #expect(banner.package == local)
        #expect(banner.obtainQuickAction()?.descriptor == .directInstall)
        #expect(banner.package.localFileURL == file)
        #expect(banner.package.repoRef == nil)

        let dependency = Package(identity: "test.dependency", payload: ["1": [
            "architecture": "all", "filename": "pool/dependency.deb",
        ]], repoRef: repository)
        let requested = try #require(center.trim(package: banner.package, toVersion: version))
        let plan = try PackageResolver.resolve(
            request: .init(actions: [.install(requested)]),
            snapshot: .init(packages: [remote, dependency], installed: [installed], architecture: "iphoneos-arm64")
        )
        #expect(Set(plan.install) == [local, dependency])

        // Choosing a repository version is explicit too, including a downgrade.
        let picked = Package(identity: installed.identity, payload: ["4.0.2": [
            "architecture": "all", "filename": "pool/older.deb",
        ]], repoRef: repository)
        page.show(picked)
        page.viewWillAppear(false)
        #expect(page.packageObject == picked)
        #expect(page.bannerPackageView.package == picked)
    }

    @Test
    func anotherFileAtTheSameVersionCanReplaceTheQueuedPackage() throws {
        let identity = "test.local-replacement"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("first.deb")
        let local = Package(identity: identity, payload: ["1": [
            "architecture": "all", "filename": file.absoluteString,
        ]])
        let request = ResolutionAction.install(local)
        let plan = try PackageResolver.resolve(
            request: .init(actions: [request]),
            snapshot: .init(packages: [], installed: [], architecture: "iphoneos-arm64")
        )
        let manager = TaskManager.shared
        try #require(manager.plan == nil)
        defer { manager.clear() }
        try #require(manager.commit(.init(
            actions: [request], cleanup: [], plan: plan, notices: [], revision: manager.revision
        )))
        #expect(PackageBannerView(package: local).obtainQuickAction() == nil)

        let other = Package(identity: identity, payload: ["1": [
            "architecture": "all", "filename": file.deletingLastPathComponent().appendingPathComponent("second.deb").absoluteString,
        ]])
        #expect(PackageBannerView(package: other).obtainQuickAction()?.descriptor == .replace)
        var metadata = try #require(local.latestMetadata)
        metadata["sha256"] = "changed-archive"
        let changed = Package(identity: identity, payload: ["1": metadata])
        #expect(PackageBannerView(package: changed).obtainQuickAction()?.descriptor == .replace)
        let remote = Package(identity: identity, payload: ["1": [
            "architecture": "all", "filename": "https://example.test/package.deb",
        ]], repoRef: URL(string: "https://example.test/"))
        #expect(PackageBannerView(package: remote).obtainQuickAction()?.descriptor == .replace)
    }
}
