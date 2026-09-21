@testable import IrisinInstaller
import IrisinProtocol
import XCTest

final class BootstrapLayoutTests: XCTestCase {
    func testRootless() {
        let layout = BootstrapLayout(kind: .rootless(prefix: "/var/jb"))
        XCTAssertEqual(layout.tool("/usr/bin/dpkg"), "/var/jb/usr/bin/dpkg")
        XCTAssertEqual(layout.systemPath("/var/mobile/x.deb"), "/var/mobile/x.deb")
        XCTAssertEqual(layout.bootstrapPath("/Applications"), "/var/jb/Applications")
        XCTAssertTrue(layout.searchPath.hasPrefix("/var/jb/usr/local/sbin:"))
    }

    func testRoothide() {
        let layout = BootstrapLayout(kind: .roothide(jbroot: "/private/var/containers/Bundle/Application/.jbroot-0123"))
        XCTAssertEqual(layout.tool("/usr/bin/dpkg"), "/private/var/containers/Bundle/Application/.jbroot-0123/usr/bin/dpkg")
        XCTAssertEqual(layout.systemPath("/var/mobile/x.deb"), "/rootfs/var/mobile/x.deb")
        XCTAssertEqual(layout.bootstrapPath("/Applications"), "/Applications")
        XCTAssertTrue(layout.searchPath.hasPrefix("/usr/local/sbin:"))
        XCTAssertTrue(layout.searchPath.contains(":/rootfs/usr/bin:"))
    }

    func testDerivedFromInstallRoot() throws {
        let root = try Scratch.installRoot()
        XCTAssertEqual(BootstrapLayout(installRoot: root).kind, .roothide(jbroot: root))
        XCTAssertEqual(BootstrapLayout(installRoot: "").kind, .none)
    }
}

final class InstallerRunnerTests: XCTestCase {
    /// When icli refuses (as it does on a Mac, where it is not built) the
    /// respring falls back to a signal from this process.
    /// The signal itself is stubbed: the names are real daemons, and the
    /// Mac running the harness has a backboardd of its own once a simulator
    /// is up.
    func testRespringFallsBackToSignal() throws {
        let root = try Scratch.installRoot()
        var events: [InstallerEvent] = []
        var signalled: [(String, Int32)] = []
        let runner = InstallerRunner(installRoot: root, layout: nil, emit: { events.append($0) }) { name, number in
            signalled.append((name, number))
            return 0
        }
        XCTAssertEqual(runner.run(.respring), 1)
        XCTAssertTrue(events.contains {
            if case let .notice(text) = $0 {
                text.contains("restarting backboardd")
            } else {
                false
            }
        })
        XCTAssertTrue(events.contains(.warning(.noProcess(name: "backboardd"))))
        XCTAssertFalse(events.contains(.phase(.completed)))
        XCTAssertEqual(signalled.map(\.0), ["backboardd"])
        XCTAssertEqual(signalled.map(\.1), [SIGTERM])
    }

    func testSignalJobsNameTheirProcess() throws {
        let root = try Scratch.installRoot()
        var signalled: [(String, Int32)] = []
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(installRoot: root, layout: nil, emit: { events.append($0) }) { name, number in
            signalled.append((name, number))
            return 1
        }
        XCTAssertEqual(runner.run(.reloadAirDrop), 0)
        XCTAssertEqual(runner.run(.enterSafeMode), 0)
        XCTAssertEqual(signalled.map(\.0), ["sharingd", "SpringBoard"])
        XCTAssertEqual(signalled.map(\.1), [SIGKILL, SIGSEGV])
        XCTAssertEqual(events.filter { $0 == .phase(.completed) }.count, 2)
    }

    func testRespringUsesRegistrar() throws {
        let root = try Scratch.installRoot()
        let registrar = RegistrarStandIn()
        var events: [InstallerEvent] = []
        let runner = registrar.runner(installRoot: root) { events.append($0) }
        XCTAssertEqual(runner.run(.respring), 0)
        XCTAssertEqual(registrar.requests, [.respring])
        XCTAssertEqual(events.last, .phase(.completed))
    }

    func testDaemonJobsUseOnlyTheInstalledIrisinPlist() throws {
        let root = try Scratch.installRoot()
        let expected = root + "/Library/LaunchDaemons/wiki.qaq.irisind.plist"
        var requests: [LaunchDaemon.Request] = []
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(
            installRoot: root,
            layout: .init(kind: .roothide(jbroot: root)),
            emit: { events.append($0) },
            daemonManager: { request in
                requests.append(request)
            },
            signalProcesses: { _, _ in 0 }
        )

        XCTAssertEqual(runner.run(.bootstrapIrisinDaemon), 0)
        XCTAssertEqual(runner.run(.bootoutIrisinDaemon), 0)
        XCTAssertEqual(requests, [.bootstrap(plist: expected, executable: root + IrisinWire.daemonPath), .bootout(plist: expected)])
        XCTAssertEqual(events.filter { $0 == .phase(.completed) }.count, 2)
    }

    func testDaemonFailureStopsTheJob() throws {
        let root = try Scratch.installRoot()
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(
            installRoot: root,
            layout: .init(kind: .roothide(jbroot: root)),
            emit: { events.append($0) },
            daemonManager: { _ in throw CocoaError(.featureUnsupported) },
            signalProcesses: { _, _ in 0 }
        )

        XCTAssertEqual(runner.run(.bootstrapIrisinDaemon), 1)
        XCTAssertTrue(events.contains {
            if case let .failure(.installationStopped(detail)) = $0 {
                return !detail.isEmpty
            }
            return false
        })
        XCTAssertFalse(events.contains(.phase(.completed)))
    }

    func testDaemonPlistUsesKernelExecutablePathAndPreservesMachService() throws {
        let root = try Scratch.installRoot()
        let path = root + "/daemon.plist"
        let original: [String: Any] = [
            "ProgramArguments": ["/usr/libexec/irisind"],
            "MachServices": ["wiki.qaq.irisin.service": true],
            "AbandonProcessGroup": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        let executable = root + IrisinWire.daemonPath
        try LaunchDaemon.preparePlist(at: path, executable: executable)
        let result = try XCTUnwrap(NSDictionary(contentsOfFile: path))
        XCTAssertEqual(result["ProgramArguments"] as? [String], [executable])
        XCTAssertEqual(result["MachServices"] as? [String: Bool], ["wiki.qaq.irisin.service": true])
        XCTAssertEqual(result["AbandonProcessGroup"] as? Bool, true)
        // RootHide's launchctl doubles the root of a kernel path without it.
        XCTAssertEqual(result["__Patched"] as? Bool, true)
    }

    func testMalformedJobIsRefused() throws {
        let root = try Scratch.installRoot()
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(installRoot: root) { events.append($0) }
        XCTAssertEqual(runner.run(.transaction(.init(install: [], remove: ["rm -rf /"]))), 64)
        XCTAssertEqual(events.count, 1)
        guard case .failure = events[0] else { return XCTFail("expected a failure event, got \(events)") }
    }
}

/// The signal jobs (`reloadAirDrop`, `enterSafeMode`) name real daemons, so
/// they are not run here: the Mac has a sharingd too. The table itself is
/// exercised on a copy of `sleep` under a name nothing else on the machine
/// has.
final class ProcessTableTests: XCTestCase {
    func testFindsAndSignalsProcessByName() throws {
        let name = "irisin-sleep-\(getpid())"
        let executable = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        defer { try? FileManager.default.removeItem(at: executable) }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
            }
        }
        // The table is read after the exec has happened; give it a moment.
        var found = false
        for _ in 0 ..< 100 where !found {
            found = ProcessTable.processIdentifiers(named: name).contains(child.processIdentifier)
            if !found {
                usleep(20000)
            }
        }
        XCTAssertTrue(found)
        XCTAssertTrue(ProcessTable.processIdentifiers(named: "no-such-process-name").isEmpty)
        XCTAssertEqual(ProcessTable.signal(processesNamed: name, with: SIGTERM), 1)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(ProcessTable.signal(processesNamed: name, with: SIGTERM), 0)
    }
}

enum Scratch {
    static func installRoot() throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("irisin-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("usr/libexec"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Library/dpkg"), withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("Library/dpkg/status"))
        try Data().write(to: directory.appendingPathComponent("new.deb"))
        return directory.resolvingSymlinksInPath().path
    }
}

/// A stand-in for icli: the same requests, the same replies, a registration
/// list and every request it was handed. `behavior` steers the failure cases.
final class RegistrarStandIn {
    enum Behavior { case success, registerFail, refuse, newFile, refreshFail }

    var registry: [String]
    private(set) var requests: [ApplicationRegistrar.Request] = []
    private let behavior: Behavior

    init(behavior: Behavior = .success, registered: [String] = []) {
        self.behavior = behavior
        registry = registered
    }

    func runner(installRoot: String, layout: BootstrapLayout? = nil, emit: @escaping (InstallerEvent) -> Void) -> InstallerRunner {
        InstallerRunner(installRoot: installRoot, layout: layout, emit: emit, registrar: perform) { _, _ in 0 }
    }

    private func perform(_ request: ApplicationRegistrar.Request) throws -> [String: Any] {
        requests.append(request)
        switch request {
        case let .register(bundle):
            if behavior == .registerFail {
                throw ApplicationRegistrar.Refusal(message: "register failed")
            }
            if !registry.contains(bundle) {
                registry.append(bundle)
            }
            return ["path": bundle, "registered": true]
        case let .unregister(bundle):
            guard registry.contains(bundle) else {
                return ["unregistered": false, "path": bundle, "message": "app is not registered"]
            }
            if behavior == .refuse {
                throw ApplicationRegistrar.Refusal(message: "LaunchServices still lists the app")
            }
            if behavior == .newFile {
                try "keep\n".write(toFile: bundle + "/new-file", atomically: true, encoding: .utf8)
            }
            registry.removeAll { $0 == bundle }
            return ["unregistered": true, "path": bundle]
        case let .refresh(directory):
            if behavior == .refreshFail {
                return ["failed": ["x"], "unverified": [String]()]
            }
            let dropped = registry.filter { $0.hasPrefix(directory + "/") && !FileManager.default.fileExists(atPath: $0) }
            registry.removeAll(where: dropped.contains)
            return ["registered": [String](), "unchanged": [String](), "unregistered": dropped, "failed": [String](), "unverified": [String]()]
        case .respring:
            return ["restarted": true, "method": "frontboard_relaunch", "pid": 2]
        }
    }
}
