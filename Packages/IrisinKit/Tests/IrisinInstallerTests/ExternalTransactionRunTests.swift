import CryptoKit
import Darwin
import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import XCTest

/// An external client's transaction as the helper carries it out: the
/// package from a descriptor, copied, checked against the client's digest,
/// prepared and installed; a removal by id.
final class ExternalTransactionRunTests: XCTestCase {
    private var root = ""
    private let id = "6f9619ff-8b86-d011-b42d-00c04fc964ff"

    override func setUpWithError() throws {
        root = try Scratch.installRoot()
        let directory = ExternalTransaction.directory(installRoot: root, transaction: id)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(directory, 0o700), 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private var directory: String {
        ExternalTransaction.directory(installRoot: root, transaction: id)
    }

    private func runner(_ events: @escaping (InstallerEvent) -> Void, descriptor: Int32 = -1) -> InstallerRunner {
        let runner = InstallerRunner(
            installRoot: root,
            layout: .init(kind: .roothide(jbroot: root)),
            emit: events,
            registrar: { _ in [:] },
            daemonManager: { _ in },
            signalProcesses: { _, _ in 0 }
        )
        runner.externalPackageDescriptor = descriptor
        return runner
    }

    /// A real `.deb`, made with the Mac's tar and ar.
    private func package(identity: String = "com.example.external", architecture: String = "all") throws -> URL {
        let work = URL(fileURLWithPath: root).appendingPathComponent("build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("usr/share/example"), withIntermediateDirectories: true)
        try "Package: \(identity)\nVersion: 1.2\nArchitecture: \(architecture)\nDescription: external\n"
            .write(to: work.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try "2.0\n".write(to: work.appendingPathComponent("debian-binary"), atomically: true, encoding: .utf8)
        try "hello\n".write(to: work.appendingPathComponent("usr/share/example/greeting"), atomically: true, encoding: .utf8)
        try run("/usr/bin/tar", ["-czf", "control.tar.gz", "./control"], in: work)
        try run("/usr/bin/tar", ["-czf", "data.tar.gz", "--uid", "0", "--gid", "0", "./usr"], in: work)
        try run("/usr/bin/ar", ["rcS", "p.deb", "debian-binary", "control.tar.gz", "data.tar.gz"], in: work)
        return work.appendingPathComponent("p.deb")
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testInstallsTheCopyAndRecordsThePackage() throws {
        let deb = try package()
        let descriptor = open(deb.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var events: [InstallerEvent] = []
        let status = runner({ events.append($0) }, descriptor: descriptor)
            .run(.external(.init(transaction: id, action: .install(sha256: try sha256(deb)))))
        XCTAssertEqual(status, 0, "\(events)")
        XCTAssertEqual(events.last, .phase(.completed))
        XCTAssertEqual(try String(contentsOfFile: root + "/usr/share/example/greeting", encoding: .utf8), "hello\n")
        let record = try JSONDecoder().decode(
            ExternalTransaction.Package.self,
            from: Data(contentsOf: URL(fileURLWithPath: directory + "/package.json"))
        )
        XCTAssertEqual(record, .init(identity: "com.example.external", version: "1.2"))
        // the copy and the prepared tree go once the run ends
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/package.deb"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/prepared"))
        // the descriptor is the helper's and is closed
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)

        // and a removal by id takes it away again
        var removal: [InstallerEvent] = []
        XCTAssertEqual(
            runner { removal.append($0) }.run(.external(.init(transaction: id, action: .remove(identity: "com.example.external")))),
            0,
            "\(removal)"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/usr/share/example/greeting"))
    }

    /// The digest the client named is the digest of what is installed, or
    /// nothing is.
    func testADigestMismatchInstallsNothing() throws {
        let deb = try package()
        let descriptor = open(deb.path, O_RDONLY)
        var events: [InstallerEvent] = []
        let status = runner({ events.append($0) }, descriptor: descriptor)
            .run(.external(.init(transaction: id, action: .install(sha256: String(repeating: "0", count: 64)))))
        XCTAssertEqual(status, 1)
        XCTAssertTrue(events.contains { if case .failure(.installationStopped) = $0 { true } else { false } })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/usr/share/example/greeting"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/package.deb"))
    }

    func testIrisinsOwnPackageIsRefused() throws {
        let deb = try package(identity: "wiki.qaq.irisin")
        let descriptor = open(deb.path, O_RDONLY)
        let status = runner({ _ in }, descriptor: descriptor)
            .run(.external(.init(transaction: id, action: .install(sha256: try sha256(deb)))))
        XCTAssertEqual(status, 1)
    }

    func testAnotherBootstrapsArchitectureIsRefused() throws {
        let deb = try package(architecture: "iphoneos-arm64")
        let descriptor = open(deb.path, O_RDONLY)
        let status = runner({ _ in }, descriptor: descriptor)
            .run(.external(.init(transaction: id, action: .install(sha256: try sha256(deb)))))
        XCTAssertEqual(status, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/usr/share/example/greeting"))
    }

    /// A descriptor that is not a regular file (a pipe a client could keep
    /// writing to) is refused before anything is read.
    func testAPipeIsNotAPackage() throws {
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&ends), 0)
        defer { close(ends[1]) }
        let status = runner({ _ in }, descriptor: ends[0])
            .run(.external(.init(transaction: id, action: .install(sha256: String(repeating: "0", count: 64)))))
        XCTAssertEqual(status, 1)
    }

    /// The directory must be the one the daemon made: private to its owner.
    func testAnOpenTransactionDirectoryIsRefused() throws {
        chmod(directory, 0o755)
        let status = runner { _ in }.run(.external(.init(transaction: id, action: .remove(identity: "a.b"))))
        XCTAssertEqual(status, 64)
    }

    func testAMissingTransactionDirectoryIsRefused() {
        let other = "11111111-2222-3333-4444-555555555555"
        XCTAssertEqual(runner { _ in }.run(.external(.init(transaction: other, action: .remove(identity: "a.b")))), 64)
    }

    /// Removing what is not installed fails, and says so.
    func testRemovingAnAbsentPackageFails() {
        var events: [InstallerEvent] = []
        let status = runner { events.append($0) }.run(.external(.init(transaction: id, action: .remove(identity: "com.example.absent"))))
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(events.contains { if case .failure = $0 { true } else { false } })
    }

    private func run(_ tool: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }
}
