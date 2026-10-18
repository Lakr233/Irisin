import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

/// Irisin's own app bundle through its own update: registering the running
/// app stops it, so the helper leaves the bundle for the app to register as
/// it exits (`registerOwnApplication`), and unregisters a removed one only
/// after the transcript has ended. Irisin is the package that places the
/// helper, and its bundle is whatever that package puts in Applications.
struct OwnApplicationTests {
    private static let bundleName = "irisin.app"

    private func irisin(
        _ fixture: NativeInstallFixture,
        version: String = "1",
        bundle: String = bundleName
    ) throws -> InstallerJob.Transaction.Item {
        try fixture.package(
            "wiki.qaq.irisin",
            version: version,
            files: [
                String(IrisinWire.helperPath.dropFirst()): "helper",
                "Applications/\(bundle)/Info.plist": "irisin \(version)",
            ],
            links: ["Applications", "Applications/\(bundle)"].map(directory)
        )
    }

    private func other(_ fixture: NativeInstallFixture, version: String = "1") throws -> InstallerJob.Transaction.Item {
        try fixture.package(
            "other.app.package",
            version: version,
            files: ["Applications/Other.app/Info.plist": "other \(version)"],
            links: ["Applications", "Applications/Other.app"].map(directory)
        )
    }

    private func directory(_ path: String) -> PreparedEntry {
        PreparedEntry(path: path, kind: .directory, mode: 0o755, uid: 0, gid: 0, modificationTime: 0)
    }

    private func transaction(
        _ fixture: NativeInstallFixture,
        install: [InstallerJob.Transaction.Item] = [],
        remove: [String] = []
    ) throws -> InstallerJob {
        let status = try Data(contentsOf: fixture.database.appendingPathComponent("status"))
        return .transaction(.init(install: install, remove: remove, statusDigest: PackageArchive.sha256(status)))
    }

    private func runner(
        _ fixture: NativeInstallFixture,
        _ registrar: RegistrarStandIn,
        events: @escaping (InstallerEvent) -> Void = { _ in }
    ) -> InstallerRunner {
        let layout = BootstrapLayout(kind: .roothide(jbroot: fixture.root.path))
        return registrar.runner(installRoot: fixture.root.path, layout: layout, emit: events)
    }

    private func bundle(_ fixture: NativeInstallFixture, _ name: String = bundleName) -> String {
        fixture.root.appendingPathComponent("Applications/" + name).path
    }

    @Test func updatedIrisinIsLeftForTheApp() throws {
        let fixture = try NativeInstallFixture()
        let installing = RegistrarStandIn()
        #expect(runner(fixture, installing).run(try transaction(fixture, install: [irisin(fixture), other(fixture)])) == 0)
        // a first install is no different: the helper never registers the app it serves
        #expect(installing.requests == [.register(bundle: bundle(fixture, "Other.app"))])

        let updating = RegistrarStandIn(registered: [bundle(fixture)])
        var events: [InstallerEvent] = []
        let job = try transaction(fixture, install: [irisin(fixture, version: "2"), other(fixture, version: "2")])
        #expect(runner(fixture, updating) { events.append($0) }.run(job) == 0)
        #expect(updating.requests == [.register(bundle: bundle(fixture, "Other.app"))])
        #expect(events.contains(.notice("Left \(bundle(fixture)) for Irisin to register as it exits")))
        #expect(events.last == .phase(.completed))
    }

    /// The bundle the old list had is Irisin's too: it goes after the end,
    /// and the new one is the app's to register.
    @Test func renamedBundleIsIrisinsOnBothSides() throws {
        let fixture = try NativeInstallFixture()
        #expect(runner(fixture, RegistrarStandIn()).run(try transaction(fixture, install: [irisin(fixture)])) == 0)

        let registrar = RegistrarStandIn(registered: [bundle(fixture)])
        let runner = runner(fixture, registrar)
        #expect(runner.run(try transaction(fixture, install: [irisin(fixture, version: "2", bundle: "Renamed.app")])) == 0)
        #expect(registrar.requests.isEmpty)
        runner.finishAfterExit { _ in }
        #expect(registrar.requests == [.unregister(bundle: bundle(fixture))])
    }

    @Test func registerOwnApplicationRegistersTheListedBundle() throws {
        let fixture = try NativeInstallFixture()
        #expect(runner(fixture, RegistrarStandIn()).run(try transaction(fixture, install: [irisin(fixture), other(fixture)])) == 0)

        let registrar = RegistrarStandIn()
        var events: [InstallerEvent] = []
        #expect(runner(fixture, registrar) { events.append($0) }.run(.registerOwnApplication) == 0)
        #expect(registrar.requests == [.register(bundle: bundle(fixture))])
        #expect(events.last == .phase(.completed))
    }

    @Test func registerOwnApplicationFailsWithoutIrisin() throws {
        let fixture = try NativeInstallFixture()
        #expect(runner(fixture, RegistrarStandIn()).run(try transaction(fixture, install: [other(fixture)])) == 0)

        let registrar = RegistrarStandIn()
        #expect(runner(fixture, registrar).run(.registerOwnApplication) == 1)
        #expect(registrar.requests.isEmpty)
    }

    @Test func registerOwnApplicationReportsARefusal() throws {
        let fixture = try NativeInstallFixture()
        #expect(runner(fixture, RegistrarStandIn()).run(try transaction(fixture, install: [irisin(fixture)])) == 0)

        var events: [InstallerEvent] = []
        #expect(runner(fixture, RegistrarStandIn(behavior: .registerFail)) { events.append($0) }.run(.registerOwnApplication) == 1)
        #expect(events.contains(.failure(.registrationFailed(bundle: bundle(fixture), detail: "register failed"))))
    }

    @Test func removedIrisinIsUnregisteredOnlyAfterTheEnd() throws {
        let fixture = try NativeInstallFixture()
        #expect(runner(fixture, RegistrarStandIn()).run(try transaction(fixture, install: [irisin(fixture), other(fixture)])) == 0)

        let registrar = RegistrarStandIn(registered: [bundle(fixture), bundle(fixture, "Other.app")])
        let runner = runner(fixture, registrar)
        #expect(runner.run(try transaction(fixture, remove: ["wiki.qaq.irisin", "other.app.package"])) == 0)
        #expect(registrar.requests == [.unregister(bundle: bundle(fixture, "Other.app"))])

        var logged: [InstallerEvent] = []
        runner.finishAfterExit { logged.append($0) }
        #expect(registrar.requests.last == .unregister(bundle: bundle(fixture)))
        #expect(registrar.registry.isEmpty)
        #expect(logged == [.notice("Unregistered \(bundle(fixture))")])
        #expect(!FileManager.default.fileExists(atPath: bundle(fixture)))
        // once only
        runner.finishAfterExit { _ in Issue.record("nothing is left to do") }
    }

    /// uikittools' `interest /Applications`, whose `uicache -a` would
    /// register the running app halfway through its own update.
    @Test func irisinsBundleActivatesNoFileTrigger() throws {
        let fixture = try NativeInstallFixture()
        let log = "#!/bin/sh\necho \"$1 $2\" >> \"$DPKG_ROOT/trigger log\"\n"
        try fixture.run(install: [fixture.package("watcher.package", controls: ["postinst": log, "triggers": "interest /Applications\n"])])
        try fixture.run(install: [irisin(fixture)])
        #expect(try fixture.text("trigger log") == "configure \n")
        try fixture.run(install: [irisin(fixture, version: "2")])
        #expect(try fixture.text("trigger log") == "configure \n")
        try fixture.run(install: [other(fixture)])
        #expect(try fixture.text("trigger log") == "configure \ntriggered /Applications\n")
    }

    /// The rest of Irisin's files still activate what watches them.
    @Test func irisinsOtherFilesStillActivateTriggers() throws {
        let fixture = try NativeInstallFixture()
        let log = "#!/bin/sh\necho \"$1 $2\" >> \"$DPKG_ROOT/trigger log\"\n"
        try fixture.run(install: [fixture.package("watcher.package", controls: ["postinst": log, "triggers": "interest /usr/libexec\n"])])
        try fixture.run(install: [irisin(fixture)])
        #expect(try fixture.text("trigger log") == "configure \ntriggered /usr/libexec\n")
    }

    @Test func scriptsReadTheInstaller() throws {
        let fixture = try NativeInstallFixture()
        let postinst = "#!/bin/sh\nenv | grep '^IRISIN_INSTALLER_' | sort > \"$DPKG_ROOT/environment\"\n"
        let environment = InstallerIdentity(version: "4.7.1", build: "900").environment(client: .external, transaction: "abc")
        try fixture.run(install: [fixture.package(controls: ["postinst": postinst])], installerEnvironment: environment)
        #expect(try fixture.text("environment") == """
        IRISIN_INSTALLER_BUILD=900
        IRISIN_INSTALLER_CLIENT=external
        IRISIN_INSTALLER_PROTOCOL=\(IrisinWire.version)
        IRISIN_INSTALLER_TRANSACTION=abc
        IRISIN_INSTALLER_VERSION=4.7.1

        """)
    }

    @Test func theAppsTransactionHasNoTransactionID() {
        let environment = InstallerIdentity(version: "4.7.1", build: "900").environment(client: .app)
        #expect(environment["IRISIN_INSTALLER_CLIENT"] == "app")
        #expect(environment["IRISIN_INSTALLER_TRANSACTION"] == nil)
    }

    @Test func coversTheBundleAndWhatHoldsItOnly() throws {
        let fixture = try NativeInstallFixture()
        let selfPackage = SelfPackage()
        let item = try irisin(fixture)
        let archive = try PackageArchive(
            directory: URL(fileURLWithPath: item.preparedPath!),
            digest: item.preparedSHA256!,
            identity: item.identity
        )
        selfPackage.find(
            in: ["wiki.qaq.irisin": archive],
            removing: [],
            database: try PackageDatabase(directory: fixture.database),
            helperPath: IrisinWire.helperPath,
            applicationsPath: "/Applications"
        )
        #expect(selfPackage.applications == ["Applications/irisin.app"])
        for covered in ["/", "/Applications", "/Applications/irisin.app", "/Applications/irisin.app/Info.plist"] {
            #expect(selfPackage.coversApplication(covered), "\(covered)")
        }
        for uncovered in ["/Applications/irisin.application", "/Applications/Other.app", "/usr/libexec/irisin-install"] {
            #expect(!selfPackage.coversApplication(uncovered), "\(uncovered)")
        }
    }
}
