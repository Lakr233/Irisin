import Darwin
import Foundation
@testable import IrisinProtocol
import XCTest

final class ExternalTransactionTests: XCTestCase {
    private let id = "0f8fad5b-d9cb-469f-a165-70867728950e"
    private let digest = String(repeating: "ab", count: 32)

    func testIdentifiersAreLowercaseCanonicalUUIDs() {
        XCTAssertTrue(ExternalTransaction.isIdentifier(id))
        XCTAssertTrue(ExternalTransaction.isIdentifier(UUID().uuidString.lowercased()))
        XCTAssertFalse(ExternalTransaction.isIdentifier(id.uppercased()))
        XCTAssertFalse(ExternalTransaction.isIdentifier("../" + id.dropFirst(3)))
        XCTAssertFalse(ExternalTransaction.isIdentifier(id.replacingOccurrences(of: "-", with: "")))
        XCTAssertFalse(ExternalTransaction.isIdentifier(id + "\u{0}"))
        XCTAssertFalse(ExternalTransaction.isIdentifier(""))
    }

    func testExternalJobsValidate() throws {
        try InstallerJob.external(.init(transaction: id, action: .install(sha256: digest))).validate()
        try InstallerJob.external(.init(transaction: id, action: .remove(identity: "com.example.tweak"))).validate()
        let refused: [InstallerJob.External] = [
            .init(transaction: "nope", action: .install(sha256: digest)),
            .init(transaction: id, action: .install(sha256: "AB" + digest.dropFirst(2))),
            .init(transaction: id, action: .install(sha256: "")),
            .init(transaction: id, action: .remove(identity: "Bad Name")),
            .init(transaction: id, action: .remove(identity: "wiki.qaq.irisin")),
        ]
        for job in refused {
            XCTAssertThrowsError(try InstallerJob.external(job).validate(), "\(job)")
        }
    }

    /// The JSON a job travels as round-trips, and decoding validates it.
    func testExternalJobsRoundTrip() throws {
        let job = InstallerJob.external(.init(transaction: id, action: .install(sha256: digest)))
        XCTAssertEqual(try InstallerJob.decode(job.encoded()), job)
        let bad = try JSONEncoder().encode(InstallerJob.external(.init(transaction: "x", action: .install(sha256: digest))))
        XCTAssertThrowsError(try InstallerJob.decode(bad))
    }

    func testTheSameRequestIsRecognised() {
        let first = ExternalTransaction.Request(kind: .install, sha256: digest, created: 1, client: "/a")
        let again = ExternalTransaction.Request(kind: .install, sha256: digest, created: 2, client: "/b")
        let other = ExternalTransaction.Request(kind: .install, sha256: String(repeating: "cd", count: 32), created: 1, client: "/a")
        XCTAssertTrue(first.isSameRequest(as: again))
        XCTAssertFalse(first.isSameRequest(as: other))
        XCTAssertFalse(first.isSameRequest(as: .init(kind: .remove, identity: "a.b", created: 1, client: "/a")))
    }

    // MARK: - Records

    private func record(lines: [InstallerEvent], partial: String? = nil, hold: Bool = false) throws -> ExternalTransaction.Record {
        let directory = NSTemporaryDirectory() + "external-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }
        let request = ExternalTransaction.Request(kind: .install, sha256: digest, created: 1, client: "/c")
        try JSONEncoder().encode(request).write(to: URL(fileURLWithPath: directory + "/request.json"))
        var text = lines.map { InstallerOutput.encode($0) + "\n" }.joined()
        if let partial {
            text += partial
        }
        let journal = directory + "/" + ExternalTransaction.File.journal
        try Data(text.utf8).write(to: URL(fileURLWithPath: journal))
        var holder: Int32 = -1
        if hold {
            holder = open(journal, O_WRONLY)
            XCTAssertEqual(flock(holder, LOCK_EX), 0)
        }
        defer { if holder >= 0 { close(holder) } }
        return try ExternalTransaction.Record.load(directory: directory, transaction: id)
    }

    func testAFinishedJournalSaysHowItEnded() throws {
        let succeeded = try record(lines: [.phase(.preparing), .phase(.completed), .exit(0)])
        XCTAssertEqual(succeeded.state, .succeeded)
        XCTAssertEqual(succeeded.exitStatus, 0)
        XCTAssertEqual(succeeded.nextSequence, 4)

        let failed = try record(lines: [
            .package(.verifying, identity: "a.b", version: ""),
            .failure(.packageFailed(identity: "a.b", step: .verifying, detail: "broken")),
            .exit(1),
        ])
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failure?.problem, "packageFailed")
        XCTAssertEqual(failed.failure?.sequence, 2)
    }

    /// No `exit`: running while the helper holds the lock it inherited,
    /// interrupted once nobody does.
    func testAnUnfinishedJournalIsRunningOnlyWhileHeld() throws {
        XCTAssertEqual(try record(lines: [.phase(.preparing)], hold: true).state, .running)
        XCTAssertEqual(try record(lines: [.phase(.preparing)], hold: false).state, .interrupted)
    }

    /// A line still being written is not an event yet.
    func testAPartialLastLineIsNotAnEvent() throws {
        let record = try record(lines: [.phase(.preparing)], partial: #"{"phase":{"_0":"veri"#, hold: true)
        XCTAssertEqual(record.lines.count, 1)
        XCTAssertEqual(record.nextSequence, 2)
    }

    func testEventsReplayFromASequence() throws {
        let record = try record(lines: [
            .phase(.preparing),
            .progress(completed: 0, total: 2),
            .package(.unpacking, identity: "a.b", version: "1.0"),
            .warning(.homeScreenNeedsAttention),
            .exit(0),
        ])
        XCTAssertEqual(record.events(after: 0, limit: 256).map(\.sequence), [1, 2, 3, 4, 5])
        XCTAssertEqual(record.events(after: 2, limit: 2).map(\.sequence), [3, 4])
        XCTAssertEqual(record.events(after: 5, limit: 256), [])
        XCTAssertEqual(record.events(after: 99, limit: 256), [])

        let events = record.events(after: 0, limit: 256)
        XCTAssertEqual(events[0].kind, "phase")
        XCTAssertEqual(events[0].phase, "preparing")
        XCTAssertEqual(events[1].total, 2)
        XCTAssertEqual(events[2].step, "unpacking")
        XCTAssertEqual(events[2].identity, "a.b")
        XCTAssertEqual(events[2].version, "1.0")
        XCTAssertEqual(events[3].problem, "homeScreenNeedsAttention")
        XCTAssertEqual(events[4].exitStatus, 0)
        XCTAssertEqual(events[2].text, "Unpacking a.b (1.0)")
    }

    func testAMissingRecordIsNotFound() {
        XCTAssertThrowsError(try ExternalTransaction.Record.load(directory: "/nonexistent/\(id)", transaction: id)) {
            XCTAssertEqual(($0 as? IrisinFailure)?.code, .notFound)
        }
    }
}
