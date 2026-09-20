@testable import IrisinClient
import IrisinProtocol
import XCTest

final class DaemonLinkTests: XCTestCase {
    /// On the Mac nothing registers the Mach service, so every lookup misses:
    /// exactly the shape of a build with no daemon.
    func testFallsBackToLocalAfterGrace() async throws {
        let link = DaemonLink(daemonIsInstalled: false, grace: 0.2)
        XCTAssertNil(link.backend)
        // The first miss starts the clock and still throws.
        do {
            _ = try await link.hello()
            XCTFail("the first miss must not bind anything")
        } catch {}
        XCTAssertNil(link.backend)
        try await Task.sleep(nanoseconds: 300_000_000)
        let backend = try await link.hello()
        XCTAssertEqual(backend, .local)
        XCTAssertFalse(backend.isPrivileged)
        XCTAssertEqual(backend.installRoot, "")
        // Bound for good: a job is refused rather than sent nowhere.
        do {
            _ = try await link.run(.respring)
            XCTFail("a local backend must refuse jobs")
        } catch let failure as IrisinFailure {
            XCTAssertEqual(failure.code, .notPermitted)
        }
    }

    func testInstalledDaemonNeverFallsBack() async throws {
        let link = DaemonLink(daemonIsInstalled: true, grace: 0)
        for _ in 0 ..< 3 {
            do {
                _ = try await link.hello()
                XCTFail("must keep waiting for a daemon that is installed")
            } catch {}
        }
        XCTAssertNil(link.backend)
    }

    func testDaemonInstallationLooksBesideApplications() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("irisin-link-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Applications/irisin.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertFalse(DaemonLink.daemonIsInstalled(besideBundleAt: bundle))
        let daemon = root.appendingPathComponent("usr/libexec/irisind")
        try FileManager.default.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: daemon)
        XCTAssertTrue(DaemonLink.daemonIsInstalled(besideBundleAt: bundle))
        XCTAssertFalse(DaemonLink.daemonIsInstalled(besideBundleAt: URL(fileURLWithPath: "/tmp/Bundle/Application/x/irisin.app")))
    }

    /// Events arrive framed; a bare line, which no helper of this protocol
    /// writes but a hand on the pipe might, is output rather than noise.
    func testTranscriptReadsToEOFAndFindsStatus() async {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        let transcript = JobTranscript(identifier: 7, descriptor: descriptors[0])
        let payload = [
            InstallerOutput.encode(.phase(.applying)),
            InstallerOutput.encode(.package(.unpacking, identity: "a.b", version: "1")),
            "bare line",
            InstallerOutput.encode(.progress(completed: 1, total: 1)),
            InstallerOutput.encode(.exit(3)),
        ].joined(separator: "\n") + "\n"
        payload.withCString { _ = write(descriptors[1], $0, strlen($0)) }
        close(descriptors[1])
        let collector = Collector()
        let status = await transcript.collect { event in collector.append(event) }
        XCTAssertEqual(status, 3)
        XCTAssertEqual(collector.events, [
            .phase(.applying),
            .package(.unpacking, identity: "a.b", version: "1"),
            .output("bare line"),
            .progress(completed: 1, total: 1),
        ])
    }

    /// A helper that died mid-job never announces a status.
    func testTranscriptWithoutExitReportsNone() async {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        let transcript = JobTranscript(identifier: 8, descriptor: descriptors[0])
        let payload = InstallerOutput.encode(.failure(.invalidJob)) + "\n"
        payload.withCString { _ = write(descriptors[1], $0, strlen($0)) }
        close(descriptors[1])
        let collector = Collector()
        let status = await transcript.collect { event in collector.append(event) }
        XCTAssertNil(status)
        XCTAssertEqual(collector.events, [.failure(.invalidJob)])
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InstallerEvent] = []
    var events: [InstallerEvent] {
        lock.lock(); defer { lock.unlock() }; return storage
    }

    func append(_ event: InstallerEvent) {
        lock.lock(); storage.append(event); lock.unlock()
    }
}
