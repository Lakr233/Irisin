import Darwin
import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

struct RemovedBundleTests {
    @Test func absentBundleIsGone() throws {
        let fixture = try NativeInstallFixture()
        let path = fixture.root.appendingPathComponent("Applications/Absent.app").path
        #expect(try RemovedApplicationBundle.isGone(path))
        try RemovedApplicationBundle.removeHusk(path)
    }

    @Test(arguments: [false, true])
    func runtimeLinksAndEmptyDirectoriesAreRemoved(nested: Bool) throws {
        let fixture = try NativeInstallFixture()
        let bundle = try makeBundle(fixture, nested: nested)
        try Data("keep".utf8).write(to: fixture.root.appendingPathComponent("sentinel"))
        #expect(try RemovedApplicationBundle.isGone(bundle.path))
        try RemovedApplicationBundle.removeHusk(bundle.path)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
        #expect(try fixture.text("sentinel") == "keep")
    }

    @Test(arguments: ["Info.plist", "Frameworks/Example.framework/Example", ".jbroot"])
    func realFilesPreventCleanup(_ file: String) throws {
        let fixture = try NativeInstallFixture()
        let bundle = fixture.root.appendingPathComponent("Applications/Example.app")
        let url = bundle.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: url)
        #expect(try !RemovedApplicationBundle.isGone(bundle.path))
        #expect(throws: (any Error).self) { try RemovedApplicationBundle.removeHusk(bundle.path) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep")
    }

    @Test(arguments: ["Example.app", "Example.app/Frameworks/Other"])
    func ordinarySymlinksArePreserved(_ name: String) throws {
        let fixture = try NativeInstallFixture()
        let link = fixture.root.appendingPathComponent("Applications/" + name)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.root.path)
        let bundle = fixture.root.appendingPathComponent("Applications/Example.app")
        #expect(try !RemovedApplicationBundle.isGone(bundle.path))
        #expect(throws: (any Error).self) { try RemovedApplicationBundle.removeHusk(bundle.path) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == fixture.root.path)
    }

    @Test func unreadableBundleIsNotTreatedAsMissing() throws {
        let fixture = try NativeInstallFixture()
        let bundle = try makeBundle(fixture)
        // A deterministic inspection error, even if the harness runs as root.
        let loop = fixture.root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "loop")
        #expect(throws: (any Error).self) { try RemovedApplicationBundle.isGone(loop.path + "/Example.app") }
        #expect(FileManager.default.fileExists(atPath: bundle.path))
    }

    @Test(arguments: [false, true])
    func nativeRemovalCleansNestedHuskAndRegistration(rootless: Bool) throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: rootless ? .rootless(prefix: fixture.root.path) : .roothide(jbroot: fixture.root.path))
        let prefix = rootless ? String(fixture.root.path.dropFirst()) + "/" : ""
        let directories = ["Applications", "Applications/Example.app", "Applications/Example.app/Frameworks", "Applications/Example.app/Frameworks/Example.framework"]
        let package = try fixture.package(
            files: [prefix + "Applications/Example.app/Info.plist": "identity", prefix + "Applications/Example.app/Frameworks/Example.framework/Example": "binary"],
            links: directories.map { PreparedEntry(path: prefix + $0, kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0) }
        )
        try fixture.run(install: [package], layout: layout)
        let bundle = try makeBundle(fixture, nested: true)
        let registrar = RegistrarStandIn(registered: [bundle.path])
        var events: [InstallerEvent] = []
        let runner = registrar.runner(installRoot: fixture.root.path, layout: layout) { events.append($0) }
        let digest = try PackageArchive.sha256(Data(contentsOf: fixture.database.appendingPathComponent("status")))
        #expect(runner.run(.transaction(.init(install: [], remove: [package.identity], statusDigest: digest))) == 0)
        // purged outright, as dpkg does without a postrm or conffiles
        #expect(try fixture.status() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.database.appendingPathComponent("info/example.package.list").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
        #expect(registrar.registry.isEmpty)
        #expect(events.last == .phase(.completed))
        #expect(!events.contains {
            if case .warning = $0 {
                true
            } else {
                false
            }
        })
        #expect(registrar.requests == [.unregister(bundle: bundle.path)])
    }

    /// An installed app is registered at its kernel path, whatever the
    /// bootstrap's own spelling of it.
    @Test(arguments: [false, true])
    func installedApplicationIsRegistered(rootless: Bool) throws {
        let fixture = try NativeInstallFixture()
        let layout = BootstrapLayout(kind: rootless ? .rootless(prefix: fixture.root.path) : .roothide(jbroot: fixture.root.path))
        let prefix = rootless ? String(fixture.root.path.dropFirst()) + "/" : ""
        let package = try fixture.package(
            files: [prefix + "Applications/Example.app/Info.plist": "identity"],
            links: ["Applications", "Applications/Example.app"].map { PreparedEntry(path: prefix + $0, kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0) }
        )
        let registrar = RegistrarStandIn()
        var events: [InstallerEvent] = []
        let runner = registrar.runner(installRoot: fixture.root.path, layout: layout) { events.append($0) }
        #expect(runner.run(.transaction(.init(install: [package], remove: []))) == 0)
        let bundle = fixture.root.appendingPathComponent("Applications/Example.app").path
        #expect(registrar.requests == [.register(bundle: bundle)])
        #expect(registrar.registry == [bundle])
        #expect(events.contains(.phase(.registeringApplications)))
        #expect(events.last == .phase(.completed))
    }

    /// One spelling for one bundle: the path a removed husk is unregistered
    /// at is the path it was registered at, even when the install root is
    /// reached through a symlink that Foundation would otherwise resolve.
    @Test func registerAndUnregisterSpellThePathTheSameWay() throws {
        let fixture = try NativeInstallFixture()
        let link = fixture.root.deletingLastPathComponent().appendingPathComponent("link " + fixture.root.lastPathComponent)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.root.path)
        defer { try? FileManager.default.removeItem(at: link) }
        let layout = BootstrapLayout(kind: .roothide(jbroot: link.path))
        let package = try fixture.package(
            files: ["Applications/Example.app/Info.plist": "identity"],
            links: ["Applications", "Applications/Example.app"].map { PreparedEntry(path: $0, kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0) }
        )
        let registrar = RegistrarStandIn()
        let runner = registrar.runner(installRoot: link.path, layout: layout) { _ in }
        #expect(runner.run(.transaction(.init(install: [package], remove: []))) == 0)
        let spelled = link.path + "/Applications/Example.app"
        #expect(registrar.registry == [spelled])
        _ = try makeBundle(fixture)
        let digest = try PackageArchive.sha256(Data(contentsOf: fixture.database.appendingPathComponent("status")))
        #expect(runner.run(.transaction(.init(install: [], remove: [package.identity], statusDigest: digest))) == 0)
        #expect(registrar.requests.contains(.unregister(bundle: spelled)))
        #expect(registrar.registry.isEmpty)
    }

    /// A registration icli refuses is a warning; the rest of the bundles
    /// are still handled and the transaction still succeeds.
    @Test func refusedRegistrationIsAWarningNotAStop() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(
            files: ["Applications/Example.app/Info.plist": "identity"],
            links: ["Applications", "Applications/Example.app"].map { PreparedEntry(path: $0, kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0) }
        )
        let registrar = RegistrarStandIn(behavior: .registerFail)
        var events: [InstallerEvent] = []
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { events.append($0) }
        #expect(runner.run(.transaction(.init(install: [package], remove: []))) == 0)
        let bundle = fixture.root.appendingPathComponent("Applications/Example.app").path
        #expect(events.contains(.warning(.registrationFailed(bundle: bundle, detail: "register failed"))))
        #expect(events.contains(.warning(.homeScreenNeedsAttention)))
        #expect(events.last == .phase(.completed))
    }

    /// An unregistration icli refuses keeps the husk, warns, and the rest
    /// still happens.
    @Test func failedIconCleanupKeepsHuskAndWarns() throws {
        let fixture = try NativeInstallFixture()
        let (package, bundle) = try installApplication(fixture)
        let registrar = RegistrarStandIn(behavior: .refuse, registered: [bundle.path])
        var events: [InstallerEvent] = []
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { events.append($0) }
        #expect(try runner.run(.transaction(removing: package, fixture)) == 0)
        #expect(try fixture.status() == nil)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(events.contains(.warning(.homeScreenNeedsAttention)))
        #expect(events.contains {
            if case .warning(.unregistrationFailed) = $0 {
                true
            } else {
                false
            }
        })
        #expect(registrar.requests == [.unregister(bundle: bundle.path)])
        #expect(events.contains(.phase(.completed)))
    }

    @Test(arguments: [false, true])
    func rebuildRepairsExistingGhosts(bundleStillExists: Bool) throws {
        let fixture = try NativeInstallFixture()
        let bundle = try makeBundle(fixture, nested: true)
        let registrar = RegistrarStandIn(registered: [bundle.path])
        if !bundleStillExists {
            try FileManager.default.removeItem(at: bundle)
        }
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { _ in }
        #expect(runner.run(.rebuildIconCache) == 0)
        #expect(registrar.registry.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
        #expect(registrar.requests.last == .refresh(directory: applications(fixture)))
    }

    @Test func rebuildReportsRefreshFailure() throws {
        let fixture = try NativeInstallFixture()
        let registrar = RegistrarStandIn(behavior: .refreshFail)
        var events: [InstallerEvent] = []
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { events.append($0) }
        #expect(runner.run(.rebuildIconCache) == 1)
        #expect(events.contains(.failure(.refreshFailed(detail: "1 failed, 0 unverified"))))
        #expect(!events.contains(.phase(.completed)))
    }

    @Test func fileAppearingDuringUnregisterIsPreservedAndReported() throws {
        let fixture = try NativeInstallFixture()
        let (package, bundle) = try installApplication(fixture)
        let registrar = RegistrarStandIn(behavior: .newFile, registered: [bundle.path])
        var events: [InstallerEvent] = []
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { events.append($0) }
        #expect(try runner.run(.transaction(removing: package, fixture)) == 0)
        #expect(try fixture.status() == nil)
        #expect(try String(contentsOf: bundle.appendingPathComponent("new-file"), encoding: .utf8) == "keep\n")
        #expect(events.contains {
            if case .warning(.leftoverBundle) = $0 {
                true
            } else {
                false
            }
        })
        #expect(events.contains(.warning(.homeScreenNeedsAttention)))
    }

    /// A husk that LaunchServices no longer lists is still cleaned: icli
    /// answers "not registered" and the directory goes.
    @Test func unregisteredHuskIsCleaned() throws {
        let fixture = try NativeInstallFixture()
        let bundle = try makeBundle(fixture)
        let unrelated = fixture.root.appendingPathComponent("Applications/keep")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let registrar = RegistrarStandIn(behavior: .refuse)
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { _ in }
        #expect(runner.run(.rebuildIconCache) == 0)
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// A transaction asks LaunchServices about what it changed and nothing
    /// else: a bundle it did not touch is not registered again, a husk an
    /// older run left stays for Rebuild Icon Cache, and the directory is
    /// never refreshed whole.
    @Test func untouchedBundlesAndOldHusksAreLeftAlone() throws {
        let fixture = try NativeInstallFixture()
        let husk = try makeBundle(fixture)
        let other = fixture.root.appendingPathComponent("Applications/Other.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: other.appendingPathComponent("Info.plist"))
        let registrar = RegistrarStandIn(registered: [husk.path, other.path])
        var events: [InstallerEvent] = []
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { events.append($0) }
        let package = try fixture.package(files: ["usr/share/example": "installed"])
        #expect(runner.run(.transaction(.init(install: [package], remove: []))) == 0)
        #expect(registrar.requests.isEmpty)
        #expect(FileManager.default.fileExists(atPath: husk.path))
        #expect(!events.contains(.phase(.registeringApplications)))
        #expect(events.last == .phase(.completed))
    }

    /// A bundle no package list names, made or rewritten while the run was
    /// on (a maintainer script's), is registered all the same, and one
    /// whose Info.plist went with it is unregistered.
    @Test func bundlesChangedOutsideTheListsAreRegistered() throws {
        let fixture = try NativeInstallFixture()
        let applications = fixture.root.appendingPathComponent("Applications")
        let rewritten = applications.appendingPathComponent("Rewritten.app")
        let emptied = applications.appendingPathComponent("Emptied.app")
        for bundle in [rewritten, emptied] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("before".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
        }
        let made = applications.appendingPathComponent("Made.app")
        let registrar = RegistrarStandIn(registered: [rewritten.path, emptied.path])
        // What a maintainer script would do, while the run is on: the
        // first notice comes after the helper has looked at the directory.
        var scripted = false
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { event in
            guard case .notice = event, !scripted else { return }
            scripted = true
            try? FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            try? Data("made".utf8).write(to: made.appendingPathComponent("Info.plist"))
            try? Data("after, longer".utf8).write(to: rewritten.appendingPathComponent("Info.plist"))
            try? FileManager.default.removeItem(at: emptied.appendingPathComponent("Info.plist"))
        }
        let package = try fixture.package(files: ["usr/share/example": "installed"])
        #expect(runner.run(.transaction(.init(install: [package], remove: []))) == 0)
        #expect(registrar.requests == [.register(bundle: made.path), .register(bundle: rewritten.path), .unregister(bundle: emptied.path)])
        #expect(!FileManager.default.fileExists(atPath: emptied.path))
    }

    @Test func dryRunDoesNotTouchIconsOrHusks() throws {
        let fixture = try NativeInstallFixture()
        let bundle = try makeBundle(fixture)
        let registrar = RegistrarStandIn(registered: [bundle.path])
        let runner = registrar.runner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { _ in }
        let package = try fixture.package(files: ["usr/share/example": "installed"])
        #expect(runner.run(.transaction(.init(install: [package], remove: [], dryRun: true))) == 0)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(registrar.requests.isEmpty)
    }

    /// A package that owns `Applications/Example.app`, installed, with the
    /// `.jbroot` links roothide leaves beside its executables.
    private func installApplication(_ fixture: NativeInstallFixture) throws -> (InstallerJob.Transaction.Item, URL) {
        let directories = ["Applications", "Applications/Example.app", "Applications/Example.app/Frameworks", "Applications/Example.app/Frameworks/Example.framework"]
        let package = try fixture.package(
            files: ["Applications/Example.app/Info.plist": "identity", "Applications/Example.app/Frameworks/Example.framework/Example": "binary"],
            links: directories.map { PreparedEntry(path: $0, kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0) }
        )
        try fixture.run(install: [package], layout: .init(kind: .roothide(jbroot: fixture.root.path)))
        return (package, try makeBundle(fixture, nested: true))
    }

    private func applications(_ fixture: NativeInstallFixture) -> String {
        fixture.root.path + "/Applications"
    }

    private func makeBundle(_ fixture: NativeInstallFixture, nested: Bool = false) throws -> URL {
        let bundle = fixture.root.appendingPathComponent("Applications/Example.app")
        for path in nested ? [bundle, bundle.appendingPathComponent("Frameworks/Example.framework")] : [bundle] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: path.appendingPathComponent(".jbroot").path, withDestinationPath: fixture.root.path)
        }
        return bundle
    }
}

private extension InstallerJob {
    /// The removal of one installed package, against the status it left.
    static func transaction(removing package: InstallerJob.Transaction.Item, _ fixture: NativeInstallFixture) throws -> InstallerJob {
        let digest = try PackageArchive.sha256(Data(contentsOf: fixture.database.appendingPathComponent("status")))
        return .transaction(.init(install: [], remove: [package.identity], statusDigest: digest))
    }
}
