import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

/// Irisin updating itself where the bootstrap shell is gone: its own
/// postinst, prerm and postrm may fail, and the helper loads the daemon the
/// package ships whatever the run did. Irisin is the package that places the
/// helper, not a name.
struct SelfUpdateTests {
    private static let failing = "#!/missing/interpreter\nexit 4\n"

    private func irisin(
        _ fixture: NativeInstallFixture,
        spelledAs: String? = nil,
        controls: [String: String]
    ) throws -> InstallerJob.Transaction.Item {
        try fixture.package(
            "wiki.qaq.irisin",
            spelledAs: spelledAs,
            files: [String(IrisinWire.helperPath.dropFirst()): "helper"],
            controls: controls
        )
    }

    private func ignored(_ events: [InstallerEvent]) -> [String] {
        events.compactMap {
            if case let .warning(.scriptFailureIgnored(identity, script, _)) = $0 {
                "\(identity).\(script)"
            } else {
                nil
            }
        }
    }

    @Test func irisinsOwnPostinstFailureIsForgiven() throws {
        let fixture = try NativeInstallFixture()
        let package = try irisin(fixture, controls: ["postinst": Self.failing, "prerm": Self.failing])
        var events: [InstallerEvent] = []

        try fixture.run(install: [package]) { events.append($0) }

        #expect(try fixture.status(package.identity) == "install ok installed")
        #expect(try fixture.text(String(IrisinWire.helperPath.dropFirst())) == "helper")
        #expect(ignored(events) == ["wiki.qaq.irisin.postinst"])
    }

    /// A control file that spells the name its own way is still the
    /// package the transaction and the database know.
    @Test func irisinIsKnownByItsTransactionIdentity() throws {
        let fixture = try NativeInstallFixture()
        let package = try irisin(fixture, spelledAs: "Wiki.QAQ.Irisin", controls: ["postinst": Self.failing])
        var events: [InstallerEvent] = []

        try fixture.run(install: [package]) { events.append($0) }

        #expect(try fixture.status(package.identity) == "install ok installed")
        #expect(ignored(events) == ["wiki.qaq.irisin.postinst"])
    }

    @Test func anotherPackagesFailureStillStops() throws {
        let fixture = try NativeInstallFixture()
        let own = try irisin(fixture, controls: ["postinst": Self.failing])
        let other = try fixture.package("other.package", controls: ["postinst": Self.failing])

        #expect(throws: (any Error).self) {
            try fixture.run(install: [own, other])
        }
        #expect(try fixture.status("other.package") != "install ok installed")
    }

    @Test func irisinsOwnPreinstStillStops() throws {
        let fixture = try NativeInstallFixture()
        let package = try irisin(fixture, controls: ["preinst": Self.failing])

        #expect(throws: (any Error).self) {
            try fixture.run(install: [package])
        }
        #expect(try fixture.status(package.identity) == nil)
    }

    @Test func theNameAloneIsNotIrisin() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package("wiki.qaq.irisin", controls: ["postinst": Self.failing])

        #expect(throws: (any Error).self) {
            try fixture.run(install: [package])
        }
    }

    // MARK: - The daemon, loaded at the end

    private struct Run {
        let status: Int32
        let events: [InstallerEvent]
        let requests: [LaunchDaemon.Request]
    }

    private func run(
        _ fixture: NativeInstallFixture,
        install: [InstallerJob.Transaction.Item],
        dryRun: Bool = false,
        daemonFails: Bool = false
    ) throws -> Run {
        let root = fixture.root.path
        let status = try Data(contentsOf: fixture.database.appendingPathComponent("status"))
        let transaction = InstallerJob.Transaction(
            install: install,
            remove: [],
            dryRun: dryRun,
            statusDigest: PackageArchive.sha256(status)
        )
        var events: [InstallerEvent] = []
        var requests: [LaunchDaemon.Request] = []
        let runner = InstallerRunner(
            installRoot: root,
            layout: .init(kind: .roothide(jbroot: root)),
            emit: { events.append($0) },
            registrar: { _ in [:] },
            daemonManager: { request in
                requests.append(request)
                if daemonFails {
                    throw CocoaError(.featureUnsupported)
                }
            },
            signalProcesses: { _, _ in 0 }
        )
        let exit = runner.run(.transaction(transaction))
        return Run(status: exit, events: events, requests: requests)
    }

    private func bootstrap(_ fixture: NativeInstallFixture) -> LaunchDaemon.Request {
        let root = fixture.root.path
        return .bootstrap(
            plist: root + "/Library/LaunchDaemons/wiki.qaq.irisind.plist",
            executable: root + IrisinWire.daemonPath
        )
    }

    private func failures(_ events: [InstallerEvent]) -> Int {
        events.count {
            if case .failure = $0 {
                true
            } else {
                false
            }
        }
    }

    @Test func daemonIsLoadedAfterIrisinIsPlaced() throws {
        let fixture = try NativeInstallFixture()
        let result = try run(fixture, install: [irisin(fixture, controls: ["postinst": Self.failing])])

        #expect(result.status == 0)
        #expect(result.requests == [bootstrap(fixture)])
        #expect(result.events.last == .phase(.completed))
        #expect(failures(result.events) == 0)
    }

    @Test func daemonIsLoadedWhenALaterPackageFails() throws {
        let fixture = try NativeInstallFixture()
        let own = try irisin(fixture, controls: [:])
        let other = try fixture.package("other.package", controls: ["postinst": Self.failing])
        let result = try run(fixture, install: [own, other])

        #expect(result.status == 1)
        #expect(result.requests == [bootstrap(fixture)])
        // the run's own failure stays the only one
        #expect(failures(result.events) == 1)
        #expect(!result.events.contains(.phase(.completed)))
    }

    @Test func daemonThatWillNotLoadIsAWarning() throws {
        let fixture = try NativeInstallFixture()
        let result = try run(fixture, install: [irisin(fixture, controls: [:])], daemonFails: true)

        #expect(result.status == 0)
        #expect(result.events.contains {
            if case .warning(.daemonNotLoaded) = $0 {
                true
            } else {
                false
            }
        })
        #expect(failures(result.events) == 0)
        #expect(result.events.last == .phase(.completed))
    }

    @Test func daemonIsLeftAloneOtherwise() throws {
        let fixture = try NativeInstallFixture()
        #expect(try run(fixture, install: [irisin(fixture, controls: [:])], dryRun: true).requests.isEmpty)
        #expect(try run(fixture, install: [fixture.package("other.package")]).requests.isEmpty)
    }
}
